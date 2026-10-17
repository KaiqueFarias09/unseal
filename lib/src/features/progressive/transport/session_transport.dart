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
import '../session_engine.dart';

/// The delivery layer behind the public `BookSession`: one session's ops
/// its resident engine.
abstract interface class SessionTransport {
  /// Total length of the session's raw container source in bytes.
  int get byteLength;

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

  /// Fails every in-flight request with
  /// `SessionCancelledException`.
  void cancelPending();

  /// Ends the session; pending and subsequent requests complete with
  /// `SessionClosedException`.
  void dispose();
}

/// Transport that runs the engine in the caller: the fallback when no
/// isolate or Web Worker is available, and the reference behavior the
/// remote transports must match.
final class InlineSessionTransport implements SessionTransport {
  /// Wraps the engine this transport drives.
  InlineSessionTransport(this._engine);

  final SessionEngine _engine;

  @override
  int get byteLength => _engine.byteLength;

  @override
  Future<Uint8List?> resource(final String path) async => _engine.resource(path);

  @override
  Future<Uint8List?> bytesRange(final int offset, final int count) async =>
      _engine.bytesRange(offset, count);

  @override
  Future<Map<String, Uint8List>> resources(final Set<String> paths) async {
    final result = <String, Uint8List>{};
    for (final path in paths) {
      final bytes = _engine.resource(path);
      if (bytes != null) result[path] = bytes;
    }

    return result;
  }

  @override
  Future<String?> documentText(final String path) async => _engine.documentText(path);

  @override
  Future<String?> documentSource(final String path) async => _engine.documentSource(path);

  @override
  Future<PdfPageText?> pdfLines(final int pageIndex) async => _engine.loadPdfPageLines(pageIndex);

  @override
  Future<PdfPageStructure?> pdfStructure(final int pageIndex) async =>
      _engine.loadPdfPageStructure(pageIndex);

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
    return _engine.search(
      query,
      mode: mode,
      isCaseSensitive: isCaseSensitive,
      isTolerant: isTolerant,
      nearChars: nearChars,
      contextChars: contextChars,
      maxMatches: maxMatches,
    );
  }

  @override
  Future<BookProgression> computeProgression() async => _engine.computeProgression();

  @override
  Future<Map<String, Object?>> searchIndexEnsure(
    final int maxSections,
    final SearchIndexIdentity? identity,
  ) async => _engine.searchIndexEnsure(maxSections, identity);

  @override
  Future<IndexedSearchResults> searchIndexQuery(
    final String query, {
    required final IndexedQueryMode mode,
    required final int? maxMatches,
    required final int? maxExpansions,
    required final int contextChars,
  }) async => decodeIndexedSearchResultsWire(
    _engine.searchIndexQuery(
      query,
      mode: mode,
      maxMatches: maxMatches,
      maxExpansions: maxExpansions,
      contextChars: contextChars,
    ),
  );

  @override
  Future<Map<String, Object?>> searchIndexExport() async => _engine.searchIndexExport();

  @override
  Future<Map<String, Object?>> searchIndexImport(
    final Map<String, Object?> payload,
    final SearchIndexIdentity? identity,
  ) async => _engine.searchIndexImport(payload, identity);

  @override
  Future<void> searchIndexDrop() async => _engine.searchIndexDrop();

  @override
  Future<BookStatistics> computeStatistics() async => _engine.computeStatistics();

  @override
  Future<EpubCfiLocation?> resolveCfi(final String cfi) async => _engine.resolveCfi(cfi);

  @override
  Future<String> buildCfi({required final int contentIndex, required final int offsetInText}) {
    return Future<String>.value(
      _engine.buildCfi(contentIndex: contentIndex, offsetInText: offsetInText),
    );
  }

  @override
  void cancelPending() {
    // Engine ops run synchronously here: nothing can be in flight.
  }

  @override
  void dispose() => _engine.close();
}
