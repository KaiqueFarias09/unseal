import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../../../foundation/archive/async_byte_reader.dart';
import '../../../foundation/entities/entities.dart';
import '../../../foundation/exceptions/unseal_exception.dart';
import '../../../platform/io/zip_byte_source_io.dart';
import '../../cfi/epub_cfi_resolver.dart';
import '../../comic/exceptions/comic_exception.dart';
import '../../epub/exceptions/exceptions.dart';
import '../../mobi/exceptions/mobi_exception.dart';
import '../../pdf/entities/pdf_page_text.dart';
import '../../pdf/exceptions/pdf_exception.dart';
import '../../pdf/layout/pdf_page_structure.dart';
import '../../reading/book_progression.dart';
import '../../search/entities/search_mode.dart';
import '../../search/entities/search_results.dart';
import '../../search/index/indexed_query_mode.dart';
import '../../search/index/indexed_search_results.dart';
import '../../search/index/search_index_exceptions.dart';
import '../../search/index/search_index_identity.dart';
import '../../search/index/search_index_wire.dart';
import '../byte_source.dart';
import '../byte_source_gate.dart';
import '../session_engine.dart';
import '../session_policy.dart';
import 'session_transport.dart';

/// Versioned wire tag of the byte-range bridge (`byteSource.v1`). Both
/// directions of every bridge message carry it as their first field,
/// so an old engine and a new host fail loudly instead of misreading
/// each other's frames.
const String byteSourceProtocolVersion = 'byteSource.v1';

/// Opens a session backed by a long-lived isolate.
///
/// File opens pass the PATH and the isolate reads the container itself
/// with seek-and-slice reads, so neither side materializes the
/// compressed source. Byte opens send the bytes once at spawn. Only
/// small messages — structure, one resource at a time, search results,
/// one page's text lines — cross the boundary afterwards. When the
/// runtime refuses to spawn isolates, the engine runs inline in the
/// caller instead.
Future<(SessionTransport, Book)> openSessionTransport({
  required final Uint8List? bytes,
  required final String? path,
  required final String password,
  required final SessionPolicy policy,
}) async {
  try {
    final transport = await _IsolateSessionTransport.open(
      bytes: bytes,
      path: path,
      password: password,
      policy: policy,
    );

    return (transport, transport.header);
  } on UnsupportedError {
    final engine = await _openInlineEngine(
      bytes: bytes,
      path: path,
      password: password,
      policy: policy,
    );

    return (InlineSessionTransport(engine), engine.book);
  } on ArgumentError {
    final engine = await _openInlineEngine(
      bytes: bytes,
      path: path,
      password: password,
      policy: policy,
    );

    return (InlineSessionTransport(engine), engine.book);
  }
}

/// Opens a session over a host-owned [UnsealByteSource]: the
/// [ByteSourceGate] stays on the calling thread and answers the
/// isolate's `byteSource.v1` range requests, so budgets, contract
/// checks, and the source lifecycle stay with the host. [password]
/// opens encrypted PDF documents. When the runtime refuses to spawn
/// isolates, the engine runs inline against the same gate. The gate
/// closes the source when the returned session is disposed or the open
/// fails.
Future<(SessionTransport, Book)> openSessionSourceTransport({
  required final UnsealByteSource source,
  required final String password,
  required final SessionPolicy policy,
}) async {
  final gate = ByteSourceGate(source, policy: policy);
  final _IsolateSessionTransport transport;
  try {
    transport = await _IsolateSessionTransport.openRemote(
      gate: gate,
      password: password,
      policy: policy,
    );
  } on UnsupportedError {
    final engine = await _openInlineRemoteEngine(gate, password, policy);

    return (InlineSourceSessionTransport(engine, gate), engine.book);
  } on ArgumentError {
    final engine = await _openInlineRemoteEngine(gate, password, policy);

    return (InlineSourceSessionTransport(engine, gate), engine.book);
  } on Object {
    unawaited(gate.close());
    rethrow;
  }

  return (transport, transport.header);
}

Future<SessionEngine> _openInlineEngine({
  required final Uint8List? bytes,
  required final String? path,
  required final String password,
  required final SessionPolicy policy,
}) async {
  if (path != null) {
    final source = FileZipByteSource.open(path);
    try {
      return await SessionEngine.openSource(source, password: password, policy: policy);
    } on Object {
      source.close();
      rethrow;
    }
  }

  return SessionEngine.openBytes(bytes!, password: password, policy: policy);
}

/// Inline remote engine: the gate's budget-checked read is the
/// engine's byte reader directly — no bridge, same limits.
Future<SessionEngine> _openInlineRemoteEngine(
  final ByteSourceGate gate,
  final String password,
  final SessionPolicy policy,
) {
  return SessionEngine.openRemote(
    CallbackAsyncByteReader(
      length: gate.length,
      revision: gate.revisionAtOpen,
      read: (final offset, final count) =>
          gate.read(offset, count, expectedRevision: gate.revisionAtOpen),
    ),
    password: password,
    policy: policy,
  );
}

/// Handshake message: caller's reply port plus the open recipe.
final class _SessionBootstrap {
  _SessionBootstrap(this.replyPort, this.bytes, this.path, this.password, this.policy)
    : remote = false;

  /// Bootstrap for the byteSource.v1 path: bytes and path stay null.
  _SessionBootstrap.remote(this.replyPort, this.password, this.policy)
    : bytes = null,
      path = null,
      remote = true;

  final SendPort replyPort;
  final Uint8List? bytes;
  final String? path;
  final String password;
  final SessionPolicy policy;

  /// True when the engine opens over the byteSource.v1 bridge instead
  /// of bytes or a path.
  final bool remote;
}

/// The isolate entry: announce the byte bridge (remote opens), open
/// the engine, report ready (or the typed open failure), then serve
/// small request/reply messages until killed.
Future<void> _isolateMain(final _SessionBootstrap bootstrap) async {
  final port = ReceivePort();
  ReceivePort? byteReplies;
  final SessionEngine engine;
  try {
    if (bootstrap.remote) {
      byteReplies = ReceivePort();
      bootstrap.replyPort.send(<Object?>[
        byteSourceProtocolVersion,
        'bridge',
        byteReplies.sendPort,
      ]);
      final reader = _BridgedByteReader(replies: byteReplies, hostPort: bootstrap.replyPort);
      await reader.handshake.future;
      engine = await SessionEngine.openRemote(
        reader,
        password: bootstrap.password,
        policy: bootstrap.policy,
      );
    } else if (bootstrap.path != null) {
      final byteSource = FileZipByteSource.open(bootstrap.path!);
      try {
        engine = await SessionEngine.openSource(
          byteSource,
          password: bootstrap.password,
          policy: bootstrap.policy,
        );
      } on Object {
        byteSource.close();
        rethrow;
      }
    } else {
      engine = await SessionEngine.openBytes(
        bootstrap.bytes!,
        password: bootstrap.password,
        policy: bootstrap.policy,
      );
    }

    bootstrap.replyPort.send(<Object?>['ready', port.sendPort, engine.book, engine.byteLength]);
  } on Object catch (error) {
    byteReplies?.close();
    port.close();
    bootstrap.replyPort.send(<Object?>['error', _errorType(error), _errorMessage(error)]);

    return;
  }

  port.listen((final message) {
    unawaited(_dispatch(engine, bootstrap.replyPort, message as List<Object?>));
  });
}

/// The engine-side half of the byteSource.v1 bridge: sends range
/// requests to the host thread and completes them from the bridge
/// reply port. Lives inside the session isolate. Late replies to dead
/// requests serve nobody.
final class _BridgedByteReader implements AsyncByteReader {
  /// Listens on the bridge reply port; requests travel over
  /// [hostPort] (the handshake reply port).
  _BridgedByteReader({required this.replies, required this.hostPort}) {
    replies.listen(_onMessage);
  }

  final SendPort hostPort;
  final ReceivePort replies;

  /// Completes when the host's handshake delivers the container
  /// length and the revision captured at open.
  final Completer<void> handshake = Completer<void>();

  @override
  int get length => _length!;

  @override
  String? get revision => _revision;

  int? _length;
  String? _revision;

  var _nextRequestId = 0;
  final Map<int, Completer<Uint8List>> _pending = <int, Completer<Uint8List>>{};

  @override
  Future<Uint8List> read(final int offset, final int count) {
    final id = _nextRequestId++;
    final completer = Completer<Uint8List>();
    _pending[id] = completer;
    hostPort.send(<Object?>[byteSourceProtocolVersion, 'request', id, offset, count, _revision]);

    return completer.future;
  }

  void _onMessage(final Object? message) {
    final reply = message! as List<Object?>;
    if (reply[0] != byteSourceProtocolVersion) return;

    switch (reply[1]) {
      case 'handshake':
        _length = reply[2]! as int;
        _revision = reply[3] as String?;
        if (!handshake.isCompleted) handshake.complete();
      case 'reply':
        final completer = _pending.remove(reply[2]! as int);
        if (completer != null) completer.complete(reply[3]! as Uint8List);
      case 'error':
        final completer = _pending.remove(reply[2]! as int);
        if (completer != null) {
          completer.completeError(rebuildSessionError(reply[3]! as String, reply[4]! as String));
        }
    }
  }

  @override
  void close() => replies.close();
}

Future<void> _dispatch(
  final SessionEngine engine,
  final SendPort replyPort,
  final List<Object?> message,
) async {
  if (message[0] == _opCancel) {
    engine.cancelPending();
    return;
  }
  final id = message[1]! as int;
  try {
    final result = await switch (message[0]! as String) {
      _opResource => engine.resource(message[2]! as String),
      _opRange => engine.bytesRange(message[2]! as int, message[3]! as int),
      _opResources => _resources(engine, (message[2]! as List).cast<String>()),
      _opText => engine.documentText(message[2]! as String),
      _opSource => engine.documentSource(message[2]! as String),
      _opPdfLines => engine.loadPdfPageLines(message[2]! as int),
      _opPdfStructure => engine.loadPdfPageStructure(message[2]! as int),
      _opSearch => engine.search(
        message[2]! as String,
        mode: SearchMode.values.byName(message[3]! as String),
        isCaseSensitive: message[4]! as bool,
        isTolerant: message[5]! as bool,
        nearChars: message[6]! as int,
        contextChars: message[7]! as int,
        maxMatches: message[8]! as int,
      ),
      _opSearchIndexEnsure => engine.searchIndexEnsure(
        message[2]! as int,
        SearchIndexIdentity.fromWire(message[3]),
      ),
      _opSearchIndexQuery => Future<Map<String, Object?>>.value(
        engine.searchIndexQuery(
          message[2]! as String,
          mode: IndexedQueryMode.values.byName(message[3]! as String),
          maxMatches: message[4] as int?,
          maxExpansions: message[5] as int?,
          contextChars: message[6]! as int,
        ),
      ),
      _opSearchIndexExport => Future<Map<String, Object?>>.value(engine.searchIndexExport()),
      _opSearchIndexImport => engine.searchIndexImport(
        (message[2]! as Map).cast<String, Object?>(),
        SearchIndexIdentity.fromWire(message[3]),
      ),
      _opSearchIndexDrop => Future<Object?>.value(_dropSearchIndex(engine)),
      _opProgression => engine.computeProgression(),
      _opStatistics => engine.computeStatistics(),
      _opMetrics => Future<Map<String, Object?>>.value(engine.metrics()),
      _opCfiResolve => engine.resolveCfi(message[2]! as String),
      _opCfiBuild => engine.buildCfi(
        contentIndex: message[2]! as int,
        offsetInText: message[3]! as int,
      ),
      _ => throw UnsealException('Session isolate received an unknown op: ${message[0]}'),
    };
    replyPort.send(<Object?>['ok', id, result]);
  } on Object catch (error) {
    replyPort.send(<Object?>['err', id, _errorType(error), _errorMessage(error)]);
  }
}

Future<Map<String, Uint8List>> _resources(
  final SessionEngine engine,
  final List<String> paths,
) async {
  final result = <String, Uint8List>{};
  for (final path in paths) {
    final bytes = await engine.resource(path);
    if (bytes != null) result[path] = bytes;
  }

  return result;
}

const _opCancel = 'cancelPending';
const _opResource = 'resource';
const _opResources = 'resources';
const _opRange = 'range';
const _opText = 'text';
const _opSource = 'source';
const _opPdfLines = 'pdfLines';
const _opPdfStructure = 'pdfStructure';
const _opSearch = 'search';
const _opSearchIndexEnsure = 'searchIndexEnsure';
const _opSearchIndexQuery = 'searchIndexQuery';
const _opSearchIndexExport = 'searchIndexExport';
const _opSearchIndexImport = 'searchIndexImport';
const _opSearchIndexDrop = 'searchIndexDrop';

/// The dispatch switch is an expression, so the void drop needs a
/// value; null replies like the other side-effect ops.
Object? _dropSearchIndex(final SessionEngine engine) {
  engine.searchIndexDrop();

  return null;
}

const _opMetrics = 'metrics';
const _opProgression = 'progression';
const _opStatistics = 'statistics';
const _opCfiResolve = 'cfiResolve';
const _opCfiBuild = 'cfiBuild';

/// Rebuilds a typed failure from the error wire the isolate carries
/// (type name + message). The known names map to their classes; unknown
/// names degrade to [UnsealException] with the original text preserved.
Object rebuildSessionError(final String type, final String message) {
  return switch (type) {
    'SessionClosedException' => const SessionClosedException(),
    'SessionCancelledException' => const SessionCancelledException(),
    'SessionUnsupportedFormatException' => SessionUnsupportedFormatException(message),
    'EmptyBytesException' => EmptyBytesException(),
    'MobiException' => MobiException(message),
    'DrmProtectedException' => DrmProtectedException(message),
    'InvalidBookException' => InvalidBookException(message),
    'EpubException' => EpubException(message),
    'ComicException' => ComicException(message),
    'PdfException' => PdfException(message),
    'PdfEncryptedException' => const PdfEncryptedException(),
    'RangeError' => RangeError(message),
    'FormatException' => FormatException(message),
    'ArgumentError' => ArgumentError(message),
    'FileSystemException' => FileSystemException(message),
    'SearchIndexException' => SearchIndexException(message),
    'SearchIndexInvalidArgumentException' => SearchIndexInvalidArgumentException(message),
    'SearchIndexIncompatibleException' => SearchIndexIncompatibleException(message),
    'SearchIndexLimitExceededException' => SearchIndexLimitExceededException(message),
    'SearchIndexCancelledException' => SearchIndexCancelledException(message),
    'SearchIndexDisposedException' => SearchIndexDisposedException(message),
    'SearchIndexUnsupportedException' => SearchIndexUnsupportedException(message),
    'ByteSourceClosedException' => const ByteSourceClosedException(),
    'ByteSourceShortReadException' => ByteSourceShortReadException(
      offset: 0,
      count: 0,
      received: 0,
    ),
    'ByteSourceLongReadException' => ByteSourceLongReadException(offset: 0, count: 0, received: 0),
    'ByteSourceReadException' => ByteSourceReadException(message),
    'ByteSourceRevisionChangedException' => ByteSourceRevisionChangedException(
      expected: null,
      actual: null,
    ),
    'ByteSourceLimitExceededException' => ByteSourceLimitExceededException(message),
    _ => UnsealException(type.isEmpty ? message : '$type: $message'),
  };
}

String _errorType(final Object error) => error.runtimeType.toString();

String _errorMessage(final Object error) {
  if (error is UnsealException) return error.message;
  if (error is FileSystemException) return error.message;
  if (error is FormatException) return error.message;

  // ArgumentError covers RangeError too; its message is dynamic.
  if (error is ArgumentError) {
    final message = error.message;

    return message == null ? error.toString() : '$message';
  }

  return error.toString();
}

final class _IsolateSessionTransport implements SessionTransport {
  _IsolateSessionTransport._(this._isolate, this._replies);

  /// Spawns the session isolate and completes the handshake.
  static Future<_IsolateSessionTransport> open({
    required final Uint8List? bytes,
    required final String? path,
    required final String password,
    required final SessionPolicy policy,
  }) async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(
      _isolateMain,
      _SessionBootstrap(replies.sendPort, bytes, path, password, policy),
      errorsAreFatal: true,
    );

    final transport = _IsolateSessionTransport._(isolate, replies);
    await transport._awaitReady();

    return transport;
  }

  /// Spawns the session isolate over a host-side gate: the isolate
  /// announces its bridge port, the handshake carries the gate's
  /// length and revision, and every `byteSource.v1` request is served
  /// through the gate on this thread. [password] rides the bootstrap
  /// for encrypted PDF documents.
  static Future<_IsolateSessionTransport> openRemote({
    required final ByteSourceGate gate,
    required final String password,
    required final SessionPolicy policy,
  }) async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(
      _isolateMain,
      _SessionBootstrap.remote(replies.sendPort, password, policy),
      errorsAreFatal: true,
    );

    final transport = _IsolateSessionTransport._(isolate, replies);
    transport._gate = gate;
    await transport._awaitReady();

    return transport;
  }

  final Isolate _isolate;
  final ReceivePort _replies;
  SendPort? _port;
  SendPort? _byteReplies;
  Book? _header;
  int? _byteLength;
  ByteSourceGate? _gate;
  var _nextId = 0;
  var _disposed = false;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};

  /// The header book handed over during the handshake.
  Book get header => _header!;

  /// The container byte length handed over during the handshake.
  @override
  int get byteLength => _byteLength!;

  /// The byte-source revision the gate captured at open; null for
  /// bytes/file sessions and unverified sources.
  @override
  String? get sourceRevision => _gate?.revisionAtOpen;

  Future<void> _awaitReady() async {
    // One listener for the transport's whole life: ReceivePort streams
    // cannot be re-subscribed, and every frame kind — bridge, ready,
    // error, op replies, byte requests — shares it.
    final ready = Completer<void>();
    _replies.listen(
      (final message) {
        final reply = message as List<Object?>;
        if (reply[0] == byteSourceProtocolVersion) {
          if (reply[1] == 'bridge') {
            _byteReplies = reply[2]! as SendPort;
            _byteReplies!.send(<Object?>[
              byteSourceProtocolVersion,
              'handshake',
              _gate!.length,
              _gate!.revisionAtOpen,
            ]);
          } else if (reply[1] == 'request') {
            _serveByteRequest(reply);
          }
          return;
        }
        switch (reply[0] as String) {
          case 'ready':
            _bind(reply[1]! as SendPort, reply[2]! as Book, reply[3]! as int);
            if (!ready.isCompleted) ready.complete();
          case 'error':
            if (!ready.isCompleted) {
              ready.completeError(rebuildSessionError(reply[1]! as String, reply[2]! as String));
            }
          default:
            _onReply(reply);
        }
      },
      onDone: () {
        if (!ready.isCompleted) {
          ready.completeError(const SessionClosedException());
        }
        _drain(const SessionClosedException());
      },
    );

    try {
      await ready.future;
    } on Object {
      await _isolateExit();
      rethrow;
    }
  }

  Future<void> _isolateExit() async {
    await _gate?.close();
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
  }

  void _serveByteRequest(final List<Object?> reply) {
    final gate = _gate;
    if (gate == null || _disposed) return;

    final requestId = reply[2]! as int;
    final offset = reply[3]! as int;
    final count = reply[4]! as int;
    final revision = reply[5] as String?;
    final Future<Uint8List> read;
    try {
      // Bounds and per-request cap checks throw synchronously; they
      // must still produce a typed reply, never an escaping error.
      read = gate.read(offset, count, expectedRevision: revision);
    } on Object catch (error) {
      _replyByteError(requestId, error);

      return;
    }
    unawaited(
      read.then(
        (final bytes) {
          _byteReplies?.send(<Object?>[byteSourceProtocolVersion, 'reply', requestId, bytes]);
        },
        onError: (final Object error) {
          _replyByteError(requestId, error);
        },
      ),
    );
  }

  void _replyByteError(final int requestId, final Object error) {
    _byteReplies?.send(<Object?>[
      byteSourceProtocolVersion,
      'error',
      requestId,
      _errorType(error),
      _errorMessage(error),
    ]);
  }

  void _bind(final SendPort port, final Book header, final int byteLength) {
    _port = port;
    _header = header;
    _byteLength = byteLength;
  }

  Future<Object?> _request(final List<Object?> message) {
    if (_disposed) throw const SessionClosedException();

    final port = _port;
    if (port == null) throw const SessionClosedException();

    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send(<Object?>[message[0], id, ...message.sublist(1)]);

    return completer.future;
  }

  void _onReply(final List<Object?> reply) {
    final id = reply[1]! as int;
    final completer = _pending.remove(id);
    if (completer == null) return;

    if (reply[0] == 'ok') {
      completer.complete(reply[2]);
    } else {
      completer.completeError(rebuildSessionError(reply[2]! as String, reply[3]! as String));
    }
  }

  void _drain(final UnsealException error) {
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
  }

  @override
  Future<Uint8List?> resource(final String path) async {
    return await _request([_opResource, path]) as Uint8List?;
  }

  @override
  Future<Uint8List?> bytesRange(final int offset, final int count) async {
    return await _request([_opRange, offset, count]) as Uint8List?;
  }

  @override
  Future<Map<String, Uint8List>> resources(final Set<String> paths) async {
    return await _request([_opResources, paths.toList()]) as Map<String, Uint8List>;
  }

  @override
  Future<String?> documentText(final String path) async {
    return await _request([_opText, path]) as String?;
  }

  @override
  Future<String?> documentSource(final String path) async {
    return await _request([_opSource, path]) as String?;
  }

  @override
  Future<PdfPageText?> pdfLines(final int pageIndex) async {
    return await _request([_opPdfLines, pageIndex]) as PdfPageText?;
  }

  @override
  Future<PdfPageStructure?> pdfStructure(final int pageIndex) async {
    return await _request([_opPdfStructure, pageIndex]) as PdfPageStructure?;
  }

  @override
  Future<SearchResults> search(
    final String query, {
    required final SearchMode mode,
    required final bool isCaseSensitive,
    required final bool isTolerant,
    required final int nearChars,
    required final int contextChars,
    required final int maxMatches,
  }) async {
    return await _request([
          _opSearch,
          query,
          mode.name,
          isCaseSensitive,
          isTolerant,
          nearChars,
          contextChars,
          maxMatches,
        ])
        as SearchResults;
  }

  @override
  Future<BookProgression> computeProgression() async {
    return await _request([_opProgression]) as BookProgression;
  }

  @override
  Future<Map<String, Object?>> searchIndexEnsure(
    final int maxSections,
    final SearchIndexIdentity? identity,
  ) async {
    return await _request([_opSearchIndexEnsure, maxSections, identity?.toWire()])
        as Map<String, Object?>;
  }

  @override
  Future<IndexedSearchResults> searchIndexQuery(
    final String query, {
    required final IndexedQueryMode mode,
    required final int? maxMatches,
    required final int? maxExpansions,
    required final int contextChars,
  }) async {
    return decodeIndexedSearchResultsWire(
      await _request([
            _opSearchIndexQuery,
            query,
            mode.name,
            maxMatches,
            maxExpansions,
            contextChars,
          ])
          as Map<String, Object?>,
    );
  }

  @override
  Future<Map<String, Object?>> searchIndexExport() async {
    return await _request([_opSearchIndexExport]) as Map<String, Object?>;
  }

  @override
  Future<Map<String, Object?>> searchIndexImport(
    final Map<String, Object?> payload,
    final SearchIndexIdentity? identity,
  ) async {
    return await _request([_opSearchIndexImport, payload, identity?.toWire()])
        as Map<String, Object?>;
  }

  @override
  Future<void> searchIndexDrop() async {
    await _request([_opSearchIndexDrop]);
  }

  @override
  Future<BookStatistics> computeStatistics() async {
    return await _request([_opStatistics]) as BookStatistics;
  }

  @override
  Future<Map<String, Object?>> metrics() async {
    return await _request([_opMetrics]) as Map<String, Object?>;
  }

  @override
  Future<EpubCfiLocation?> resolveCfi(final String cfi) async {
    return await _request([_opCfiResolve, cfi]) as EpubCfiLocation?;
  }

  @override
  Future<String> buildCfi({
    required final int contentIndex,
    required final int offsetInText,
  }) async => await _request([_opCfiBuild, contentIndex, offsetInText]) as String;

  @override
  void cancelPending() {
    if (_disposed) return;
    _port?.send(<Object?>[_opCancel]);
    _gate?.cancelPending();
    _drain(const SessionCancelledException());
  }

  @override
  void dispose() {
    if (_disposed) return;

    _disposed = true;
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
    // The gate closes the host source; its queued and in-flight reads
    // fail typed, so a late reply can never serve a dead session.
    unawaited(_gate?.close());
    _drain(const SessionClosedException());
  }
}
