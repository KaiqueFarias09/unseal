import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import '../cfi/epub_cfi_resolver.dart';
import '../pdf/entities/pdf_page_text.dart';
import '../reading/book_progression.dart';
import '../search/entities/search_mode.dart';
import '../search/entities/search_results.dart';
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
