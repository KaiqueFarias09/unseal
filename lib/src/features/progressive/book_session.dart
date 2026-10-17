import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import '../cfi/epub_cfi_resolver.dart';
import '../pdf/entities/pdf_page_text.dart';
import '../pdf/layout/pdf_page_structure.dart';
import '../reading/book_progression.dart';
import '../search/entities/search_mode.dart';
import '../search/entities/search_results.dart';
import '../search/index/book_search_index.dart';
import '../search/index/indexed_query_mode.dart';
import '../search/index/indexed_search_results.dart';
import '../search/index/search_index_identity.dart';
import 'session_policy.dart';
import 'transport/session_transport.dart';
import 'transport/session_transport_io.dart'
    if (dart.library.js_interop) 'transport/session_transport_web.dart';

/// A progressive reading session over one book.
///
/// The book's compressed source and its inflated content stay resident
/// behind a small delivery layer — a background isolate on native
/// runtimes, a worker-style Web Worker on the web — and the
/// caller receives structure immediately and content on demand:
///
/// ```dart
/// final session = await BookSession.openFile(path);
/// final book = session.book;          // metadata, navigation, reading order
/// final chapter = await session.loadResource(firstChapterPath);
/// ```
///
/// Cache pressure stays bounded by [SessionPolicy.cacheBytes]; `dispose`
/// ends the session and fails every pending request with
/// [SessionClosedException]. The classic `Unseal.read` /
/// `Unseal.readFile` entry points remain the full-materialization path.
final class BookSession {
  BookSession._(this.book, {required this.isProgressive, required SessionTransport transport})
    : _transport = transport;

  final SessionTransport _transport;

  /// The session header: complete book structure (metadata,
  /// navigation, reading order, format-specific spine and inventory
  /// data) with no content files. A concrete `EpubBook`, `ComicBook`
  /// or `PdfBook`.
  final Book book;

  /// Whether content loads entry by entry. The session currently supports
  /// EPUB, CBZ, CBR and PDF, and all of them load content progressively.
  /// Other formats throw [SessionUnsupportedFormatException] when
  /// opened.
  final bool isProgressive;

  /// Total length of the session's raw container source in bytes — the
  /// compressed file for every supported format.
  int get byteLength => _transport.byteLength;

  /// Opens a progressive session over [bytes].
  ///
  /// Throws the parse-time `UnsealException` hierarchy on broken
  /// containers and `SessionUnsupportedFormatException` when the
  /// format has no progressive support. PDF documents open with
  /// [password], like the eager parse.
  static Future<BookSession> open(
    final Uint8List bytes, {
    final String password = '',
    final SessionPolicy policy = const SessionPolicy(),
  }) async {
    final (transport, header) = await openSessionTransport(
      bytes: bytes,
      path: null,
      password: password,
      policy: policy,
    );

    return BookSession._(header, isProgressive: true, transport: transport);
  }

  /// Opens a progressive session over the file at [path].
  ///
  /// On native runtimes the session isolate reads the file itself, so
  /// the compressed source never has to fit in caller memory.
  static Future<BookSession> openFile(
    final String path, {
    final String password = '',
    final SessionPolicy policy = const SessionPolicy(),
  }) async {
    final (transport, header) = await openSessionTransport(
      bytes: null,
      path: path,
      password: password,
      policy: policy,
    );

    return BookSession._(header, isProgressive: true, transport: transport);
  }

  /// Loads the inflated bytes of one container entry, or null when the
  /// entry does not exist.
  Future<Uint8List?> loadResource(final String path) => _transport.resource(path);

  /// Loads several container entries in one round trip; missing paths
  /// are absent from the result.
  Future<Map<String, Uint8List>> loadResources(final Iterable<String> paths) {
    return _transport.resources(Set.of(paths));
  }

  /// Loads the canonical document text of a content document, or null
  /// when the entry does not exist. This is the same offset space
  /// search and CFI address.
  Future<String?> loadDocumentText(final String path) => _transport.documentText(path);

  /// Loads the raw decoded source of a content document (the HTML/CSS
  /// text with markup), or null when the entry does not exist.
  Future<String?> loadDocumentSource(final String path) => _transport.documentSource(path);

  /// Loads one PDF page's text with preserved line geometry — the
  /// canonical post-reflow line set whose joined text is exactly the
  /// page's [loadDocumentText] — the input the facsimile text layer
  /// positions line by line. Negative indexes and indexes past the
  /// page count throw [RangeError]; extraction failures surface typed.
  /// PDF sessions only.
  Future<PdfPageText?> loadPdfPageLines(final int pageIndex) => _transport.pdfLines(pageIndex);

  /// Loads the stable structure of one PDF page (0-based): words,
  /// blocks, columns and tables with verifiable geometry, the page's
  /// source-line space and the mapping from source positions into the
  /// page's canonical text. Built against the session's sampled
  /// reflow plan. Negative indexes and indexes past the page count
  /// throw [RangeError]; PDF sessions only.
  Future<PdfPageStructure?> loadPdfPageStructure(final int pageIndex) =>
      _transport.pdfStructure(pageIndex);

  /// Loads a raw slice of the session's container source: [count] bytes
  /// at [offset], clamped to the end of the source and to
  /// [SessionPolicy.rangeMaxBytes]. Negative offsets or counts, and
  /// offsets past the end, throw [RangeError].
  Future<Uint8List?> loadBytesRange(final int offset, final int count) =>
      _transport.bytesRange(offset, count);

  /// Full-text search over the whole book with the `BookSearch.search`
  /// contract, executed against the resident content.
  Future<SearchResults> search(
    final String query, {
    final SearchMode mode = SearchMode.contains,
    final bool isCaseSensitive = false,
    final bool isTolerant = true,
    final int nearChars = 60,
    final int contextChars = 48,
    final int maxMatches = 200,
  }) {
    return _transport.search(
      query,
      mode: mode,
      isCaseSensitive: isCaseSensitive,
      isTolerant: isTolerant,
      nearChars: nearChars,
      contextChars: contextChars,
      maxMatches: maxMatches,
    );
  }

  /// Builds (or advances) the session's resident search index in
  /// bounded batches of [sectionsPerBatch], materializing one section
  /// at a time inside the session's worker. Each batch is one round
  /// trip; [onProgress] fires after every completed batch with the
  /// current coverage.
  ///
  /// Cancelling [cancellation] stops the loop at the next batch
  /// boundary and returns the frozen coverage — the resident index
  /// keeps its partial state, visible to later queries. The first call
  /// binds the index to [identity] when supplied; later calls ignore
  /// it (a different identity fails typed inside the engine).
  Future<SearchIndexCoverage> buildSearchIndex({
    final int sectionsPerBatch = 4,
    final SearchIndexIdentity? identity,
    final SearchIndexCancellationToken? cancellation,
    final void Function(SearchIndexCoverage coverage)? onProgress,
  }) async {
    var coverage = SearchIndexCoverage.fromWire(await _transport.searchIndexEnsure(0, identity));
    while (!coverage.isComplete) {
      if (cancellation?.isCancelled ?? false) return coverage;
      coverage = SearchIndexCoverage.fromWire(
        await _transport.searchIndexEnsure(sectionsPerBatch, null),
      );
      onProgress?.call(coverage);
    }

    return coverage;
  }

  /// The current coverage of the resident search index, reporting
  /// without advancing the build (a zero-section ensure).
  Future<SearchIndexCoverage> searchIndexCoverage() async {
    return SearchIndexCoverage.fromWire(await _transport.searchIndexEnsure(0, null));
  }

  /// Indexed search over the resident index — ranking, prefix and
  /// fuzzy modes per [IndexedQueryMode], hits carrying original UTF-16
  /// ranges and the coverage that produced them. Over a partial index,
  /// an empty result never proves absence in the book: check
  /// [IndexedSearchResults.coverage].
  ///
  /// Throws the typed `SearchIndex*Exception` hierarchy (invalid
  /// argument, exceeded limit) and needs [buildSearchIndex] first.
  Future<IndexedSearchResults> searchIndexed(
    final String query, {
    final IndexedQueryMode mode = IndexedQueryMode.exact,
    final int? maxMatches,
    final int? maxExpansions,
    final int contextChars = 48,
  }) {
    return _transport.searchIndexQuery(
      query,
      mode: mode,
      maxMatches: maxMatches,
      maxExpansions: maxExpansions,
      contextChars: contextChars,
    );
  }

  /// Serializes the resident index into a versioned payload the host
  /// may persist. Refuses while the build is incomplete and, over PDF
  /// text, until the P1 position-mapping acceptance.
  Future<Map<String, Object?>> exportSearchIndex() => _transport.searchIndexExport();

  /// Validates [payload] against this session's book — reading order,
  /// section names and per-section text digests — and adopts it,
  /// replacing any resident index. Mismatched content fails with
  /// `SearchIndexIncompatibleException` and the resident index stays.
  ///
  /// Validation materializes every indexed section's text once; on a
  /// cold session that is the cost of the full pass.
  Future<SearchIndexCoverage> importSearchIndex(
    final Map<String, Object?> payload, {
    final SearchIndexIdentity? identity,
  }) async {
    return SearchIndexCoverage.fromWire(await _transport.searchIndexImport(payload, identity));
  }

  /// Drops the resident search index and releases its memory.
  Future<void> dropSearchIndex() => _transport.searchIndexDrop();

  /// Whole-book reading progression, measured section by section in the
  /// session's worker.
  Future<BookProgression> computeProgression() => _transport.computeProgression();

  /// Whole-book statistics over canonical plain text.
  Future<BookStatistics> computeStatistics() => _transport.computeStatistics();

  /// Resolves a CFI against the book, loading only the addressed
  /// document. Malformed or unresolving CFIs complete with null.
  Future<EpubCfiLocation?> resolveCfi(final String cfi) => _transport.resolveCfi(cfi);

  /// Builds a book-level CFI for a reading position. Range errors keep
  /// the inline resolver's contract.
  Future<String> buildCfi({required final int contentIndex, required final int offsetInText}) {
    return _transport.buildCfi(contentIndex: contentIndex, offsetInText: offsetInText);
  }

  /// Completes every in-flight request with
  /// [SessionCancelledException]. New requests remain valid.
  void cancelPending() => _transport.cancelPending();

  /// Ends the session: the worker dies, pending and subsequent requests
  /// complete with [SessionClosedException]. Reopen with a new session.
  void dispose() => _transport.dispose();
}
