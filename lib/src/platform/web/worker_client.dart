import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../features/cfi/epub_cfi_resolver.dart';
import '../../features/pdf/entities/pdf_page_text.dart';
import '../../features/progressive/session_policy.dart';
import '../../features/reading/book_progression.dart';
import '../../features/search/entities/search_mode.dart';
import '../../features/search/entities/search_results.dart';
import '../../foundation/entities/book/book.dart';
import '../../foundation/entities/book_metadata.dart';
import '../../foundation/entities/book_statistics.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import 'book_wire.dart';

/// Owns the configured web worker and the request/reply protocol.
///
/// Failures that mean "no worker" (nothing configured, the script
/// failed to load, the worker died) surface as `null` results so
/// callers fall back to inline parsing; genuine parse failures surface
/// as the original [UnsealException] hierarchy, rebuilt through
/// [decodeErrorWire].
///
/// The worker keeps a parsed book for [searchInWorker],
/// [resolveCfiInWorker] and [buildCfiInWorker], plus independently
/// identified progressive sessions for the `session*` methods. Session
/// ops cannot fall back inline (the engine holds the content), so a
/// lost session fails them with the typed [SessionClosedException]
/// instead of a null result.
final class WorkerClient {
  WorkerClient._();

  /// Process-wide client.
  static final WorkerClient instance = WorkerClient._();

  web.Worker? _worker;
  Uri? _script;
  bool _broken = false;
  bool _residentBook = false;
  int _nextId = 0;
  int _nextSessionId = 0;
  final Set<int> _residentSessions = <int>{};
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};

  /// Whether a worker script has been configured and not broken.
  bool get isConfigured => _script != null && !_broken;

  /// Points the client at a compiled [workerScript] (see
  /// `web/unseal_worker.dart` for the build command). The worker is
  /// spawned lazily on the first parse.
  void configure(final Uri workerScript) {
    dispose();
    _script = workerScript;
    _broken = false;
  }

  /// Terminates the worker and forgets the configuration; the
  /// resident book and the resident session die with it.
  void dispose() {
    _worker?.terminate();
    _worker = null;
    _script = null;
    _broken = false;
    _residentBook = false;
    _residentSessions.clear();
    _drainPending();
  }

  /// Parses [bytes] inside the worker; `null` means the worker was
  /// unavailable and the caller should parse inline. On success the
  /// parsed book stays resident inside the worker and serves the
  /// stateful ops until the next parse, [dispose] or a breakage.
  Future<Book?> parseInWorker(final Uint8List bytes) async {
    try {
      final book = await _request(workerOpParse, bytes: bytes) as Book?;
      _residentBook = book != null;

      return book;
    } on Object {
      _residentBook = false;
      rethrow;
    }
  }

  /// Reads metadata inside the worker; `null` means inline fallback.
  Future<BookMetadata?> metadataInWorker(final Uint8List bytes) async {
    return await _request(workerOpMetadata, bytes: bytes) as BookMetadata?;
  }

  /// Searches the resident book inside the worker; `null` means no
  /// resident book or no worker — callers run `book.search` inline as
  /// the fallback. Defaults mirror `BookSearch.search`. An invalid
  /// [SearchMode.regex] pattern completes with the worker's
  /// [FormatException].
  Future<SearchResults?> searchInWorker(
    final String query, {
    final SearchMode mode = SearchMode.contains,
    final bool isCaseSensitive = false,
    final bool isTolerant = true,
    final int nearChars = 60,
    final int contextChars = 48,
    final int maxMatches = 200,
  }) async {
    if (!_residentBook) return null;

    return await _request(
          workerOpSearch,
          payload: <String, Object?>{
            wireKeyQuery: query,
            wireKeyMode: mode.name,
            wireKeyCaseSensitive: isCaseSensitive,
            wireKeyTolerant: isTolerant,
            wireKeyNearChars: nearChars,
            wireKeyContextChars: contextChars,
            wireKeyMaxMatches: maxMatches,
          },
        )
        as SearchResults?;
  }

  /// Resolves [cfi] against the resident book inside the worker;
  /// `null` means no resident book or no worker (callers resolve
  /// inline), or the CFI is malformed or points outside the book.
  Future<EpubCfiLocation?> resolveCfiInWorker(final String cfi) async {
    if (!_residentBook) return null;

    return await _request(workerOpCfiResolve, payload: <String, Object?>{wireKeyCfi: cfi})
        as EpubCfiLocation?;
  }

  /// Builds a book-level CFI for a reading position in the resident
  /// book inside the worker; `null` means no resident book or no
  /// worker — callers build inline.
  Future<String?> buildCfiInWorker({
    required final int contentIndex,
    required final int offsetInText,
  }) async {
    if (!_residentBook) return null;

    return await _request(
          workerOpCfiBuild,
          payload: <String, Object?>{
            wireKeyContentIndex: contentIndex,
            wireKeyOffsetInText: offsetInText,
          },
        )
        as String?;
  }

  /// Opens an independently identified progressive session over
  /// [bytes] inside the worker. `null` means the worker was unavailable
  /// and the caller should run the engine inline. A failed open (a
  /// broken container) surfaces as the original typed error; other
  /// resident sessions stay alive.
  Future<({Book book, int sessionId, int byteLength})?> sessionOpenInWorker(
    final Uint8List bytes, {
    final String password = '',
    final SessionPolicy policy = const SessionPolicy(),
  }) async {
    final sessionId = _nextSessionId++;
    final opened =
        await _request(
              workerOpSessionOpen,
              bytes: bytes,
              payload: <String, Object?>{
                wireKeySessionId: sessionId,
                wireKeyPassword: password,
                wireKeyCacheBytes: policy.cacheBytes,
                wireKeyCoverMaxBytes: policy.coverMaxBytes,
                wireKeyRangeMaxBytes: policy.rangeMaxBytes,
              },
            )
            as (Book, int?)?;
    if (opened == null) return null;
    _residentSessions.add(sessionId);

    return (book: opened.$1, sessionId: sessionId, byteLength: opened.$2 ?? 0);
  }

  /// A raw slice of the resident session's container source, clamped to
  /// the end and to the session's range cap. Throws
  /// [SessionClosedException] when no live session is resident and
  /// [RangeError] for invalid offsets or counts.
  Future<Uint8List?> sessionRangeInWorker(
    final int sessionId,
    final int offset,
    final int count,
  ) async {
    _ensureResidentSession(sessionId);

    return _nullOrClosed(
      sessionId,
      await _request(
            workerOpSessionRange,
            payload: _sessionPayload(sessionId, <String, Object?>{
              wireKeyOffset: offset,
              wireKeyCount: count,
            }),
          )
          as Uint8List?,
    );
  }

  /// Inflated bytes of one container entry of the resident session;
  /// `null` when the entry does not exist. Throws
  /// [SessionClosedException] when no live session is resident — the
  /// session never opened, ended through
  /// [sessionDisposeInWorker], or the worker broke while the request
  /// was in flight.
  Future<Uint8List?> sessionResourceInWorker(final int sessionId, final String path) async {
    _ensureResidentSession(sessionId);

    return _nullOrClosed(
      sessionId,
      await _request(
            workerOpSessionResource,
            payload: _sessionPayload(sessionId, <String, Object?>{wireKeyPath: path}),
          )
          as Uint8List?,
    );
  }

  /// Inflated bytes of several container entries of the resident
  /// session in one round trip; missing paths are omitted. Throws
  /// [SessionClosedException] when no live session is resident.
  Future<Map<String, Uint8List>> sessionResourcesInWorker(
    final int sessionId,
    final Set<String> paths,
  ) async {
    _ensureResidentSession(sessionId);

    return _requireLive(
      sessionId,
      await _request(
            workerOpSessionResources,
            payload: _sessionPayload(sessionId, <String, Object?>{wireKeyPaths: paths.toList()}),
          )
          as Map<String, Uint8List>?,
    );
  }

  /// Raw decoded source (markup included) of one content document of
  /// the resident session; `null` when the document does not exist.
  /// Throws [SessionClosedException] when no live session is resident.
  Future<String?> sessionSourceInWorker(final int sessionId, final String path) async {
    _ensureResidentSession(sessionId);

    return _nullOrClosed(
      sessionId,
      await _request(
            workerOpSessionSource,
            payload: _sessionPayload(sessionId, <String, Object?>{wireKeyPath: path}),
          )
          as String?,
    );
  }

  /// One PDF page's text with line geometry from the resident
  /// session. Throws [SessionClosedException] when no live session is
  /// resident and [RangeError] for indexes outside the page count.
  Future<PdfPageText?> sessionPdfLinesInWorker(final int sessionId, final int pageIndex) async {
    _ensureResidentSession(sessionId);

    return _nullOrClosed(
      sessionId,
      await _request(
            workerOpSessionPdfLines,
            payload: _sessionPayload(sessionId, <String, Object?>{wireKeyPageIndex: pageIndex}),
          )
          as PdfPageText?,
    );
  }

  /// Canonical document text of one content document of the resident
  /// session; `null` when the document does not exist. Throws
  /// [SessionClosedException] when no live session is resident.
  Future<String?> sessionTextInWorker(final int sessionId, final String path) async {
    _ensureResidentSession(sessionId);

    return _nullOrClosed(
      sessionId,
      await _request(
            workerOpSessionText,
            payload: _sessionPayload(sessionId, <String, Object?>{wireKeyPath: path}),
          )
          as String?,
    );
  }

  /// Whole-book search inside the resident session, with the
  /// `BookSearch.search` contract and defaults. Throws
  /// [SessionClosedException] when no live session is resident.
  Future<SearchResults> sessionSearchInWorker(
    final int sessionId,
    final String query, {
    final SearchMode mode = SearchMode.contains,
    final bool isCaseSensitive = false,
    final bool isTolerant = true,
    final int nearChars = 60,
    final int contextChars = 48,
    final int maxMatches = 200,
  }) async {
    _ensureResidentSession(sessionId);

    return _requireLive(
      sessionId,
      await _request(
            workerOpSessionSearch,
            payload: _sessionPayload(sessionId, <String, Object?>{
              wireKeyQuery: query,
              wireKeyMode: mode.name,
              wireKeyCaseSensitive: isCaseSensitive,
              wireKeyTolerant: isTolerant,
              wireKeyNearChars: nearChars,
              wireKeyContextChars: contextChars,
              wireKeyMaxMatches: maxMatches,
            }),
          )
          as SearchResults?,
    );
  }

  /// Whole-book reading progression inside the resident session.
  /// Throws [SessionClosedException] when no live session is resident.
  Future<BookProgression> sessionProgressionInWorker(final int sessionId) async {
    _ensureResidentSession(sessionId);

    return _requireLive(
      sessionId,
      await _request(workerOpSessionProgression, payload: _sessionPayload(sessionId))
          as BookProgression?,
    );
  }

  /// Whole-book statistics inside the resident session. Throws
  /// [SessionClosedException] when no live session is resident.
  Future<BookStatistics> sessionStatisticsInWorker(final int sessionId) async {
    _ensureResidentSession(sessionId);

    return _requireLive(
      sessionId,
      await _request(workerOpSessionStatistics, payload: _sessionPayload(sessionId))
          as BookStatistics?,
    );
  }

  /// Resolves [cfi] against the resident session; `null` when the CFI
  /// is malformed or resolves nowhere. Throws
  /// [SessionClosedException] when no live session is resident.
  Future<EpubCfiLocation?> sessionResolveCfiInWorker(final int sessionId, final String cfi) async {
    _ensureResidentSession(sessionId);

    return _nullOrClosed(
      sessionId,
      await _request(
            workerOpSessionCfiResolve,
            payload: _sessionPayload(sessionId, <String, Object?>{wireKeyCfi: cfi}),
          )
          as EpubCfiLocation?,
    );
  }

  /// Builds a book-level CFI for a reading position in the resident
  /// session. Throws [SessionClosedException] when no live session is
  /// resident; a reading position outside the book keeps the inline
  /// contract as [RangeError].
  Future<String> sessionBuildCfiInWorker({
    required final int sessionId,
    required final int contentIndex,
    required final int offsetInText,
  }) async {
    _ensureResidentSession(sessionId);

    return _requireLive(
      sessionId,
      await _request(
            workerOpSessionCfiBuild,
            payload: _sessionPayload(sessionId, <String, Object?>{
              wireKeyContentIndex: contentIndex,
              wireKeyOffsetInText: offsetInText,
            }),
          )
          as String?,
    );
  }

  /// Ends the resident session inside the worker (the message is
  /// fire-and-forget, like the isolate transport killing its
  /// isolate). Later ops for this ID throw [SessionClosedException];
  /// other resident sessions stay usable.
  void sessionDisposeInWorker(final int sessionId) {
    if (!_residentSessions.remove(sessionId)) return;
    unawaited(_request(workerOpSessionDispose, payload: _sessionPayload(sessionId)));
  }

  Map<String, Object?> _sessionPayload(
    final int sessionId, [
    final Map<String, Object?> fields = const <String, Object?>{},
  ]) => <String, Object?>{wireKeySessionId: sessionId, ...fields};

  /// Rejects session requests before they reach the worker when that
  /// specific session is no longer live.
  void _ensureResidentSession(final int sessionId) {
    if (!_residentSessions.contains(sessionId)) throw const SessionClosedException();
  }

  /// A nullable session result (a missing entry, an unresolved CFI) is
  /// legitimate only while the session is still live; a null from a
  /// broken worker means the request was drained, not that the entry
  /// is missing.
  T? _nullOrClosed<T extends Object?>(final int sessionId, final T? result) {
    if (!_residentSessions.contains(sessionId) && result == null) {
      throw const SessionClosedException();
    }

    return result;
  }

  /// A non-nullable session result arriving as null means the request
  /// was drained by a broken worker.
  T _requireLive<T extends Object?>(final int sessionId, final T? result) {
    if (!_residentSessions.contains(sessionId) || result == null) {
      throw const SessionClosedException();
    }

    return result;
  }

  Future<Object?> _request(
    final String op, {
    final Uint8List? bytes,
    final Map<String, Object?>? payload,
  }) {
    final worker = _acquire();
    if (worker == null) return Future<Object?>.value();

    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;

    final message = JSObject();
    message.setProperty(wireKeyId.toJS, id.toJS);
    message.setProperty(wireKeyOp.toJS, op.toJS);
    if (bytes != null) message.setProperty(wireKeyBytes.toJS, bytes.toJS);
    if (payload != null) {
      message.setProperty(wireKeyPayload.toJS, encodeJson(payload).toJS);
    }
    worker.postMessage(message);

    return completer.future;
  }

  /// Returns the live worker, spawning one when needed. `null` means
  /// workers are unavailable and parsing must stay on the main thread.
  web.Worker? _acquire() {
    if (!isConfigured) return null;

    final existing = _worker;
    if (existing != null) return existing;

    try {
      final worker = web.Worker(_script!.toString().toJS);
      worker.onmessage = ((web.Event event) => _onReply(event as web.MessageEvent)).toJS;
      worker.onerror = ((web.Event event) => _onWorkerError()).toJS;
      _worker = worker;

      return worker;
    } on UnsupportedError {
      // The runtime exposes no worker support (native VM, or a host
      // blocking workers); parsing stays on the main thread.
      _broken = true;

      return null;
    }
  }

  void _onReply(final web.MessageEvent event) {
    final data = event.data as JSObject?;
    if (data == null) return;

    final id = (data.getProperty(wireKeyId.toJS) as JSNumber).toDartInt;
    final completer = _pending.remove(id);
    if (completer == null) return;

    final kind = (data.getProperty(wireKeyKind.toJS) as JSString).toDart;
    try {
      switch (kind) {
        case wireReplyBook:
        case wireReplyMetadata:
          final json = decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart);
          final blobs = _blobsOf(data);
          completer.complete(
            kind == wireReplyBook ? decodeBookWire(json, blobs) : decodeMetadataWire(json, blobs),
          );
        case wireReplySearch:
          completer.complete(
            decodeSearchResultsWire(
              decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart),
            ),
          );
        case wireReplyCfiLocation:
          final locationJson = decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart);
          completer.complete(
            decodeCfiLocationWire(locationJson[wireKeyLocation] as Map<String, Object?>?),
          );
        case wireReplyCfi:
          final cfiJson = decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart);
          completer.complete(cfiJson[wireKeyCfi] as String?);
        case wireReplySessionOpen:
          final headerJson = decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart);
          final header = decodeSessionHeaderWire(headerJson, _blobsOf(data));
          // The op tags its reply with the container byte length the
          // session reports; the client hands both to the transport.
          completer.complete((header, headerJson[wireKeyByteLength] as int?));
        case wireReplySessionResource:
          completer.complete(
            _referencedBlob(
                  decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart),
                  _blobsOf(data),
                )
                as Uint8List?,
          );
        case wireReplySessionResources:
          final reply = decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart);
          final blobs = _blobsOf(data);
          final paths = (reply[wireKeyPaths] as List<Object?>).cast<String>();
          completer.complete(<String, Uint8List>{
            for (var index = 0; index < paths.length; index++)
              paths[index]: blobs[index] as Uint8List,
          });
        case wireReplySessionRange:
          completer.complete(
            _referencedBlob(
                  decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart),
                  _blobsOf(data),
                )
                as Uint8List?,
          );
        case wireReplySessionSource:
        case wireReplySessionText:
          completer.complete(
            _referencedBlob(
                  decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart),
                  _blobsOf(data),
                )
                as String?,
          );
        case wireReplySessionPdfLines:
          final reply = decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart);
          final page = reply[wireKeyPage] as Map<String, Object?>?;
          completer.complete(page == null ? null : decodePdfPageLinesWire(page));
        case wireReplySessionSearch:
          completer.complete(
            decodeSearchResultsWire(
              decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart),
            ),
          );
        case wireReplySessionProgression:
          final reply = decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart);
          completer.complete(
            BookProgression.fromSectionLengths(
              (reply[wireKeySectionLengths] as List<Object?>).cast<int>(),
            ),
          );
        case wireReplySessionStatistics:
          final reply = decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart);
          completer.complete(
            BookStatistics(
              wordCount: reply[wireKeyWordCount] as int,
              characterCount: reply[wireKeyCharacterCount] as int,
            ),
          );
        case wireReplySessionCfiLocation:
          final reply = decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart);
          completer.complete(
            decodeCfiLocationWire(reply[wireKeyLocation] as Map<String, Object?>?),
          );
        case wireReplySessionCfi:
          final reply = decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart);
          completer.complete(reply[wireKeyCfi] as String?);
        case wireReplySessionDispose:
          completer.complete(null);
        case wireReplyError:
          completer.completeError(
            decodeErrorWire(
              (data.getProperty(wireKeyType.toJS) as JSString).toDart,
              (data.getProperty(wireKeyMessage.toJS) as JSString).toDart,
            ),
          );
        default:
          completer.completeError(UnsealException('Worker reply holds an unknown kind: $kind'));
      }
    } on Object catch (error) {
      completer.completeError(error);
    }
  }

  void _onWorkerError() {
    // Script failed to load or the worker died: never retry it, every
    // pending and future request falls back to inline parsing.
    _broken = true;
    _worker = null;
    _residentBook = false;
    _residentSessions.clear();
    _drainPending();
  }

  void _drainPending() {
    for (final completer in _pending.values) {
      completer.complete();
    }
    _pending.clear();
  }

  /// The reply's blob list. Blobs hold Uint8List entries and String
  /// entries side by side; each element is converted on its own (a
  /// wholesale downcast breaks under dart2js).
  List<Object> _blobsOf(final JSObject data) {
    return <Object>[
      for (final blob in (data.getProperty(wireKeyBlobs.toJS) as JSArray<JSAny?>).toDart)
        blob.isA<JSUint8Array>() ? (blob as JSUint8Array).toDart : (blob as JSString).toDart,
    ];
  }

  /// The blob a session reply references by index, null when the
  /// requested entry does not exist.
  Object? _referencedBlob(final Map<String, Object?> reply, final List<Object> blobs) {
    final index = reply[wireKeyBlobIndex] as int?;

    return index == null ? null : blobs[index];
  }
}
