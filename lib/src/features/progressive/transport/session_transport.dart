import 'dart:async';
import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../../cfi/epub_cfi_resolver.dart';
import '../../pdf/entities/pdf_page_text.dart';
import '../../pdf/layout/pdf_page_structure.dart';
import '../../reading/book_progression.dart';
import '../../search/entities/search_mode.dart';
import '../../search/entities/search_results.dart';
import '../../search/index/indexed_query_mode.dart';
import '../../search/index/indexed_search_results.dart';
import '../../search/index/search_index_identity.dart';
import '../../search/index/search_index_wire.dart';
import '../byte_source_gate.dart';
import '../session_engine.dart';
import '../session_policy.dart';

/// The delivery layer behind the public `BookSession`: one session's ops
/// its resident engine.
abstract interface class SessionTransport {
  /// Total length of the session's raw container source in bytes.
  int get byteLength;

  /// The byte-source revision token the session was opened against,
  /// or null for bytes/file sessions.
  String? get sourceRevision;

  /// Inflated bytes of one container entry, or null when missing.
  Future<Uint8List?> resource(final String path);

  /// Inflated bytes of several entries; missing paths are omitted.
  Future<Map<String, Uint8List>> resources(final Set<String> paths);

  /// A raw slice of the container source, clamped to the end of the
  /// source and to the policy's range cap; [RangeError] for invalid
  /// offsets or counts.
  Future<Uint8List?> bytesRange(final int offset, final int count);

  /// Canonical document text of a content document, or null when
  /// missing.
  Future<String?> documentText(final String path);

  /// Raw decoded source of a content document (markup included), or
  /// null when missing.
  Future<String?> documentSource(final String path);

  /// Geometry lines of one PDF page (0-based); [RangeError] for
  /// indexes outside the page count and typed failures for
  /// materialization problems. PDF sessions only.
  Future<PdfPageText?> pdfLines(final int pageIndex);

  /// Stable structure of one PDF page (0-based); same error contract
  /// as [pdfLines]. PDF sessions only.
  Future<PdfPageStructure?> pdfStructure(final int pageIndex);

  /// Whole-book search with the `BookSearch.search` contract.
  Future<SearchResults> search(
    final String query, {
    required final SearchMode mode,
    required final bool isCaseSensitive,
    required final bool isTolerant,
    required final int nearChars,
    required final int contextChars,
    required final int maxMatches,
  });

  /// Advances the resident search index by at most [maxSections]
  /// sections and returns the coverage wire. The [identity] binds a
  /// freshly created index; later calls pass null.
  Future<Map<String, Object?>> searchIndexEnsure(
    final int maxSections,
    final SearchIndexIdentity? identity,
  );

  /// Runs an indexed query against the resident index; the transport
  /// decodes the indexed-results wire.
  Future<IndexedSearchResults> searchIndexQuery(
    final String query, {
    required final IndexedQueryMode mode,
    required final int? maxMatches,
    required final int? maxExpansions,
    required final int contextChars,
  });

  /// Serializes the resident index (typed refusal over PDF text).
  Future<Map<String, Object?>> searchIndexExport();

  /// Validates and adopts an imported index; returns the coverage wire.
  Future<Map<String, Object?>> searchIndexImport(
    final Map<String, Object?> payload,
    final SearchIndexIdentity? identity,
  );

  /// Drops the resident index.
  Future<void> searchIndexDrop();

  /// Whole-book progression, measured section by section.
  Future<BookProgression> computeProgression();

  /// Whole-book statistics over canonical plain text.
  Future<BookStatistics> computeStatistics();

  /// CFI resolution against the resident book, or null when the CFI is
  /// malformed or resolves nowhere.
  Future<EpubCfiLocation?> resolveCfi(final String cfi);

  /// Book-level CFI construction from a reading position.
  Future<String> buildCfi({required final int contentIndex, required final int offsetInText});

  /// What the engine has touched so far, as the metrics wire map.
  Future<Map<String, Object?>> metrics();

  /// Fails every in-flight request with
  /// `SessionCancelledException`.
  void cancelPending();

  /// Ends the session; pending and subsequent requests complete with
  /// `SessionClosedException`.
  void dispose();
}

/// Inline transport for source opens: like [InlineSessionTransport],
/// plus the gate close on disposal, so the host source never outlives
/// the session.
final class InlineSourceSessionTransport extends InlineSessionTransport {
  /// Wraps the engine and the gate its reads went through.
  InlineSourceSessionTransport(super.engine, this._gate);

  final ByteSourceGate _gate;

  @override
  String? get sourceRevision => _gate.revisionAtOpen;

  @override
  void cancelPending() {
    super.cancelPending();
    _gate.cancelPending();
  }

  @override
  void dispose() {
    super.dispose();
    unawaited(_gate.close());
  }
}

/// Transport that runs the engine in the caller: the fallback when no
/// isolate or Web Worker is available, and the reference behavior the
/// remote transports must match.
class InlineSessionTransport implements SessionTransport {
  /// Wraps the engine this transport drives.
  InlineSessionTransport(this._engine);

  final SessionEngine _engine;

  @override
  int get byteLength => _engine.byteLength;

  @override
  String? get sourceRevision => null;

  var _disposed = false;
  final Set<Completer<Object?>> _pending = <Completer<Object?>>{};

  Future<T> _dispatch<T>(final FutureOr<T> Function() issue) {
    if (_disposed) return Future<T>.error(const SessionClosedException());

    final completer = Completer<Object?>();
    _pending.add(completer);
    unawaited(
      Future<T>.sync(issue).then(
        (final value) {
          if (!completer.isCompleted) completer.complete(value);
          _pending.remove(completer);
        },
        onError: (final Object error, final StackTrace stack) {
          if (!completer.isCompleted) completer.completeError(error, stack);
          _pending.remove(completer);
        },
      ),
    );
    return completer.future.then((final value) => value as T);
  }

  void _drain(final Object error) {
    for (final request in _pending) {
      request.completeError(error);
    }
    _pending.clear();
  }

  @override
  Future<Uint8List?> resource(final String path) => _dispatch(() => _engine.resource(path));
  @override
  Future<Uint8List?> bytesRange(final int offset, final int count) =>
      _dispatch(() => _engine.bytesRange(offset, count));
  @override
  Future<Map<String, Uint8List>> resources(final Set<String> paths) => _dispatch(() async {
    final result = <String, Uint8List>{};
    for (final path in paths) {
      final bytes = await _engine.resource(path);
      if (bytes != null) result[path] = bytes;
    }
    return result;
  });
  @override
  Future<String?> documentText(final String path) => _dispatch(() => _engine.documentText(path));
  @override
  Future<String?> documentSource(final String path) =>
      _dispatch(() => _engine.documentSource(path));
  @override
  Future<PdfPageText?> pdfLines(final int pageIndex) =>
      _dispatch(() => _engine.loadPdfPageLines(pageIndex));
  @override
  Future<PdfPageStructure?> pdfStructure(final int pageIndex) =>
      _dispatch(() => _engine.loadPdfPageStructure(pageIndex));
  @override
  Future<SearchResults> search(
    final String query, {
    required final SearchMode mode,
    required final bool isCaseSensitive,
    required final bool isTolerant,
    required final int nearChars,
    required final int contextChars,
    required final int maxMatches,
  }) => _dispatch(
    () => _engine.search(
      query,
      mode: mode,
      isCaseSensitive: isCaseSensitive,
      isTolerant: isTolerant,
      nearChars: nearChars,
      contextChars: contextChars,
      maxMatches: maxMatches,
    ),
  );
  @override
  Future<BookProgression> computeProgression() => _dispatch(_engine.computeProgression);
  @override
  Future<Map<String, Object?>> searchIndexEnsure(
    final int maxSections,
    final SearchIndexIdentity? identity,
  ) => _dispatch(() => _engine.searchIndexEnsure(maxSections, identity));
  @override
  Future<IndexedSearchResults> searchIndexQuery(
    final String query, {
    required final IndexedQueryMode mode,
    required final int? maxMatches,
    required final int? maxExpansions,
    required final int contextChars,
  }) => _dispatch(
    () => decodeIndexedSearchResultsWire(
      _engine.searchIndexQuery(
        query,
        mode: mode,
        maxMatches: maxMatches,
        maxExpansions: maxExpansions,
        contextChars: contextChars,
      ),
    ),
  );
  @override
  Future<Map<String, Object?>> searchIndexExport() => _dispatch(_engine.searchIndexExport);
  @override
  Future<Map<String, Object?>> searchIndexImport(
    final Map<String, Object?> payload,
    final SearchIndexIdentity? identity,
  ) => _dispatch(() => _engine.searchIndexImport(payload, identity));
  @override
  Future<void> searchIndexDrop() => _dispatch(_engine.searchIndexDrop);
  @override
  Future<BookStatistics> computeStatistics() => _dispatch(_engine.computeStatistics);
  @override
  Future<EpubCfiLocation?> resolveCfi(final String cfi) => _dispatch(() => _engine.resolveCfi(cfi));
  @override
  Future<String> buildCfi({required final int contentIndex, required final int offsetInText}) =>
      _dispatch(() => _engine.buildCfi(contentIndex: contentIndex, offsetInText: offsetInText));
  @override
  Future<Map<String, Object?>> metrics() => _dispatch(_engine.metrics);
  @override
  void cancelPending() {
    _engine.cancelPending();
    _drain(const SessionCancelledException());
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _drain(const SessionClosedException());
    _engine.close();
  }
}
