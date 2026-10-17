import 'dart:async';
import 'dart:convert' as convert;
import 'dart:math' as math;
import 'dart:typed_data';

import '../../foundation/archive/async_archive_random_access.dart';
import '../../foundation/archive/async_byte_reader.dart';
import '../../foundation/archive/async_zip_random_access.dart';
import '../../foundation/archive/zip_byte_source.dart';
import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../../foundation/images/image_type_sniffer.dart';
import '../../foundation/text/canonical_document_text.dart';
import '../cfi/epub_cfi.dart';
import '../cfi/epub_cfi_resolver.dart';
import '../comic/archive/rar_random_access.dart';
import '../detection/detect_format.dart';
import '../detection/entities/detected_format.dart';
import '../epub/codec/epub_xml.dart';
import '../epub/entities/entities.dart';
import '../epub/exceptions/exceptions.dart';
import '../pdf/entities/pdf_book.dart';
import '../pdf/entities/pdf_page.dart';
import '../pdf/entities/pdf_page_text.dart';
import '../pdf/header/pdf_document.dart';
import '../pdf/layout/pdf_page_structure.dart';
import '../pdf/reader/pdf_byte_source.dart';
import '../pdf/reader/pdf_content_stream.dart';
import '../pdf/reflow/pdf_reflow.dart';
import '../reading/book_progression.dart';
import '../search/book_search.dart';
import '../search/entities/search_match.dart';
import '../search/entities/search_mode.dart';
import '../search/entities/search_results.dart';
import '../search/index/book_search_index.dart';
import '../search/index/indexed_query_mode.dart';
import '../search/index/search_index_exceptions.dart';
import '../search/index/search_index_identity.dart';
import '../search/index/search_index_wire.dart';
import '../search/query_compiler.dart';
import 'comic_session_header.dart';
import 'epub_session_header.dart';
import 'pdf_session_header.dart';
import 'session_policy.dart';

const _sessionFormatProbeBytes = 1024;

/// 1-based page path of the PDF branch: exactly the names
/// `PdfReflow` emits for its per-page documents.
final RegExp _pdfPagePathPattern = RegExp(r'^page_(\d+)\.html$');

/// Image paths the session decodes on demand: the same names the
/// eager extraction records for drawable images.
final RegExp _pdfImagePathPattern = RegExp(r'^images/pdf-image-(\d+)\.(\w+)$');

/// Parses a book's structure up front and serves its content on demand.
///
/// Every content operation is asynchronous: the engine owns an
/// [AsyncArchiveRandomAccess] source (zip or RAR) plus a byte-budgeted
/// LRU of inflated entries, and reads bytes through an [AsyncByteReader]
/// — in memory, a file, or a host's remote byte source reached through
/// the transport's bridge. The engine runs inside whatever host the
/// platform layer chooses — a long-lived isolate, a Web Worker, or the
/// calling thread as a fallback. Transports turn its results into
/// small messages; the parsed book never crosses a boundary whole.
///
/// Remote byte sources cover EPUB and CBZ ([openRemote]); RAR and PDF
/// sessions keep opening from bytes or files, whose reads complete
/// immediately through the synchronous adapters.
final class SessionEngine {
  SessionEngine._(
    this.book,
    this._source,
    this._bytes,
    this._byteLength,
    this._policy, {
    required final bool ownsReader,
  }) : _ownsReader = ownsReader,
       _htmlPathSpace = book is EpubBook;

  /// Opens [bytes], inflating only the container's structural
  /// documents.
  ///
  /// Throws [SessionUnsupportedFormatException] for formats the
  /// progressive slice does not cover (everything but EPUB, CBZ, CBR
  /// and PDF today); callers fall back to `Unseal.read`.
  static Future<SessionEngine> openBytes(
    final Uint8List bytes, {
    final String password = '',
    final SessionPolicy policy = const SessionPolicy(),
  }) async {
    if (bytes.isEmpty) throw EmptyBytesException();

    final detected = detectFormat(bytes);
    switch (detected) {
      case DetectedFormat.epub:
        // Zip containers are refined by inventory: EPUB or CBZ.
        final container = MemoryZipByteSource(bytes);
        final reader = SyncAsyncByteReader(container);

        return _openZipSource(
          await AsyncZipRandomAccess.open(reader),
          reader,
          detected,
          policy,
          ownsReader: true,
        );
      case DetectedFormat.comic:
        // The comic detection signature is the RAR marker.
        final container = MemoryZipByteSource(bytes);
        final reader = SyncAsyncByteReader(container);

        return _openComicSource(
          SyncAsyncArchive(RarRandomAccess.open(container)),
          reader,
          policy,
          ownsReader: true,
        );
      case DetectedFormat.pdf:
        // The document parser keeps the bytes as views; the raw
        // source stays addressable for the range op.
        final container = MemoryZipByteSource(bytes);
        final reader = SyncAsyncByteReader(container);

        return _openPdfSource(
          MemoryPdfByteSource(bytes),
          reader,
          policy,
          password,
          ownsReader: true,
        );
      default:
        throw SessionUnsupportedFormatException(
          'The ${detected.name} format has no progressive session support; '
          'open it with Unseal.read instead.',
        );
    }
  }

  /// Opens a random-access byte source (file-backed on the VM). The
  /// engine takes ownership: closing the session closes [source]. A
  /// bounded prefix rejects formats that are not ZIP or RAR
  /// containers; the inventory then distinguishes EPUB from CBZ.
  /// Container-level guard failures — corrupt directories, zip64
  /// declarations, safety-cap violations — surface typed from here.
  static Future<SessionEngine> openSource(
    final ZipByteSource source, {
    final String password = '',
    final SessionPolicy policy = const SessionPolicy(),
  }) async {
    if (source.length == 0) {
      source.close();
      throw EmptyBytesException();
    }

    final reader = SyncAsyncByteReader(source);
    final prefixLength = source.length < _sessionFormatProbeBytes
        ? source.length
        : _sessionFormatProbeBytes;
    final DetectedFormat detected;
    try {
      detected = detectFormat(await reader.read(0, prefixLength));
    } on FormatNotSupportedException {
      reader.close();
      throw const SessionUnsupportedFormatException(
        'This format has no progressive session support; open it with Unseal.readFile instead.',
      );
    } on Object {
      reader.close();
      rethrow;
    }

    switch (detected) {
      case DetectedFormat.comic:
        try {
          return await _openComicSource(
            SyncAsyncArchive(RarRandomAccess.open(source)),
            reader,
            policy,
            ownsReader: true,
          );
        } on Object {
          reader.close();
          rethrow;
        }
      case DetectedFormat.epub:
        try {
          return await _openZipSource(
            await AsyncZipRandomAccess.open(reader),
            reader,
            detected,
            policy,
            ownsReader: true,
          );
        } on Object {
          reader.close();
          rethrow;
        }
      case DetectedFormat.pdf:
        // One file handle serves both the document parser and the
        // range op: the PdfByteSource is a view over the same
        // ZipByteSource, so no second file descriptor opens.
        try {
          return await _openPdfSource(
            _PdfSourceOverZip(source),
            reader,
            policy,
            password,
            ownsReader: true,
          );
        } on Object {
          reader.close();
          rethrow;
        }
      default:
        reader.close();
        throw SessionUnsupportedFormatException(
          'The ${detected.name} format has no progressive session support; '
          'open it with Unseal.readFile instead.',
        );
    }
  }

  /// Opens a host-provided byte source — the remote path of
  /// `BookSession.openSource`. Only EPUB and CBZ are covered: RAR and
  /// PDF sessions keep their bytes/file opens this round, and other
  /// ZIP books (office documents, zipped FB2/HTML/TXT, Calibre
  /// collections) are refused explicitly, like the eager dispatch.
  ///
  /// The engine does not own [reader]: the transport's gate closes the
  /// host source when the session is disposed. See `BookSession.openSource`
  /// for the public entry.
  static Future<SessionEngine> openRemote(
    final AsyncByteReader reader, {
    final String password = '',
    final SessionPolicy policy = const SessionPolicy(),
  }) async {
    if (reader.length == 0) throw EmptyBytesException();

    final prefixLength = reader.length < _sessionFormatProbeBytes
        ? reader.length
        : _sessionFormatProbeBytes;
    final DetectedFormat detected;
    try {
      detected = detectFormat(await reader.read(0, prefixLength));
    } on FormatNotSupportedException {
      throw const SessionUnsupportedFormatException(
        'This format has no progressive session support over a byte source; '
        'open it with Unseal.read instead.',
      );
    }

    switch (detected) {
      case DetectedFormat.comic:
        throw const SessionUnsupportedFormatException(
          'CBR (RAR) sessions do not open over external byte sources; '
          'use BookSession.open or openFile.',
        );
      case DetectedFormat.pdf:
        throw const SessionUnsupportedFormatException(
          'PDF sessions do not open over external byte sources; '
          'use BookSession.open or openFile.',
        );
      case DetectedFormat.epub:
        return _openZipSource(
          await AsyncZipRandomAccess.open(reader),
          reader,
          detected,
          policy,
          ownsReader: false,
        );
      default:
        throw SessionUnsupportedFormatException(
          'The ${detected.name} format has no progressive session support; '
          'open it with Unseal.read instead.',
        );
    }
  }

  /// The header book: complete structure, empty content. A concrete
  /// `EpubBook`, `ComicBook` or `PdfBook`, so spine-driven consumers
  /// work unchanged.
  final Book book;

  /// The archive container for the zip/RAR branches; null for PDF,
  /// which owns no archive — its content ops route through [_pdf].
  final AsyncArchiveRandomAccess? _source;

  /// The raw container source the range op slices; both archive
  /// wrappers are built over it, and the PDF parser reads the same
  /// source through a [PdfByteSource] view.
  final AsyncByteReader _bytes;

  /// Whether closing the session closes [_bytes]: true for bytes and
  /// file opens, false for remote sources the host still owns.
  final bool _ownsReader;

  /// Total byte length of the raw container source.
  final int _byteLength;

  final SessionPolicy _policy;
  final bool _htmlPathSpace;
  bool _closed = false;

  /// The resident search index, built incrementally across
  /// `searchIndexEnsure` calls; null until the first ensure. PDF
  /// indexes carry the session's sampled extraction profile.
  BookSearchIndex? _searchIndex;

  /// The eligible sections the resident index still has to process.
  List<(int, String)>? _searchIndexPending;

  /// The PDF content state; null for the zip/RAR branches.
  PdfSessionContent? _pdf;

  /// LRU of inflated entries keyed by container path: text entries keep
  /// their [TextFile] (the document-text memo hangs off the instance),
  /// binary entries keep raw bytes. Map literals are insertion-ordered,
  /// so "first key" is the least-recently-used entry.
  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  /// Whether the format materializes eagerly (always false for the
  /// progressive slice today).
  bool get isProgressive => true;

  /// Total length of the raw container source in bytes — the
  /// compressed file for every supported format.
  int get byteLength => _byteLength;

  /// Raw bytes of a container entry, or null when the entry does not
  /// exist.
  Future<Uint8List?> resource(final String path) async {
    _ensureOpen();
    if (_pdf != null) return _pdfResource(path);

    final source = _source!;
    final record = source.find(path);
    if (record == null) return null;

    final cached = _cache[record.name];
    if (cached != null && cached.bytes != null) {
      _touch(record.name);

      return cached.bytes;
    }

    final bytes = await source.inflate(record);
    _store(record.name, _CacheEntry(bytes: bytes));

    return bytes;
  }

  /// Byte lengths of several entries, without inflating: the serving
  /// layer uses this for byte-range headers.
  ///
  /// PDF paths carry no container length: page documents are
  /// generated HTML whose length would need materializing, and image
  /// lengths are known only once the image decoded — null for both.
  int? resourceLength(final String path) {
    _ensureOpen();
    if (_pdf != null) {
      final cached = _cache[path];

      return cached?.bytes?.length;
    }

    final record = _source!.find(path);

    return record?.uncompressedSize;
  }

  /// A raw slice of the container source: [count] bytes at [offset],
  /// clamped to the end of the source and to
  /// [SessionPolicy.effectiveRangeMaxBytes]. Negative offsets/counts
  /// and offsets past the end throw [RangeError].
  Future<Uint8List> bytesRange(final int offset, final int count) async {
    _ensureOpen();
    if (offset < 0) throw RangeError.range(offset, 0, _byteLength, 'offset');
    if (count < 0) throw RangeError.range(count, 0, null, 'count');
    if (offset > _byteLength) throw RangeError.range(offset, 0, _byteLength, 'offset');

    final clamped = math.min(math.min(count, _byteLength - offset), _policy.effectiveRangeMaxBytes);

    return _bytes.read(offset, clamped);
  }

  /// The canonical [TextFile] of a content document, or null when the
  /// entry does not exist.
  Future<TextFile?> textFile(final String path) async {
    _ensureOpen();
    if (_pdf != null) return _pdfTextFile(path);

    final source = _source!;
    final record = source.find(path);
    if (record == null) return null;

    final cached = _cache[record.name];
    if (cached != null && cached.text != null) {
      _touch(record.name);

      return cached.text;
    }

    final bytes = await source.inflate(record);
    final text = _htmlPathSpace
        ? decodeEpubText(bytes)
        : convert.utf8.decode(bytes, allowMalformed: true);
    final file = TextFile(
      content: text,
      name: record.name.split('/').last,
      type: '',
      path: record.name,
    );
    _store(record.name, _CacheEntry(text: file));

    return file;
  }

  /// Geometry lines of one PDF page (0-based) — the canonical
  /// post-reflow line set whose joined text is exactly the page's
  /// `documentText`. Negative indexes and indexes past the page count
  /// throw [RangeError]; extraction failures surface typed.
  Future<PdfPageText> loadPdfPageLines(final int pageIndex) async {
    _ensureOpen();
    final pdf = _pdf;
    final pageCount = pdf?.book.pageCount ?? 0;
    if (pageIndex < 0 || pageIndex >= pageCount) {
      throw RangeError.range(pageIndex, 0, pageCount - 1, 'pageIndex');
    }

    return (await _pdfMaterialize(pageIndex + 1)).pdfPage!;
  }

  /// The stable structure of one PDF page (0-based): words, blocks,
  /// columns and tables with geometry, the source-line space and the
  /// mapping into the page's canonical text. Built against the
  /// session's sampled reflow plan — the `session-sample` scope, a
  /// profile distinct from the eager document's. Negative indexes and
  /// indexes past the page count throw [RangeError]. PDF sessions
  /// only.
  Future<PdfPageStructure> loadPdfPageStructure(final int pageIndex) async {
    _ensureOpen();
    final pdf = _pdf;
    final pageCount = pdf?.book.pageCount ?? 0;
    if (pageIndex < 0 || pageIndex >= pageCount) {
      throw RangeError.range(pageIndex, 0, pageCount - 1, 'pageIndex');
    }

    final canonical = (await _pdfMaterialize(pageIndex + 1)).pdfPage!;
    final layout = pdf!.extractor.extractLayout(
      pdf.book.pages[pageIndex],
      onImage: _discardPdfImage,
    );

    return PdfPageStructure.build(
      pageIndex: pageIndex,
      pageCount: pageCount,
      geometry: PdfPageStructure.geometryOfPage(pdf.book.pages[pageIndex]),
      sourceLines: layout.pageText.lines,
      words: layout.words,
      rules: layout.rules,
      canonical: canonical,
      canonicalScope: 'session-sample',
      planRevision: pdfPlanRevision(pdf.plan),
    );
  }

  /// Document text of a content document — the canonical offset space
  /// search and CFI address.
  Future<String?> documentText(final String path) async {
    final file = await textFile(path);

    return file == null ? null : documentTextOf(file);
  }

  /// Raw decoded source of a content document — the HTML/CSS text as
  /// stored (markup included), the shape servers and CFI document
  /// parsers need.
  Future<String?> documentSource(final String path) async => (await textFile(path))?.content;

  /// Full-text search with the [BookSearch.search] contract, executed
  /// section by section so only one chapter is materialized at a time.
  Future<SearchResults> search(
    final String query, {
    final SearchMode mode = SearchMode.contains,
    final bool isCaseSensitive = false,
    final bool isTolerant = true,
    final int nearChars = 60,
    final int contextChars = 48,
    final int maxMatches = 200,
  }) async {
    _ensureOpen();

    final results = <SearchMatch>[];
    final trimmed = query.trim();
    if (trimmed.isEmpty) return SearchResults(query: query, matches: results, isTruncated: false);

    final compiled = compileSearchQuery(
      trimmed,
      mode: mode,
      isCaseSensitive: isCaseSensitive,
      isTolerant: isTolerant,
      nearChars: nearChars,
    );
    var isTruncated = false;
    final sections = book.readingOrder;
    for (var sectionIndex = 0; sectionIndex < sections.length; sectionIndex++) {
      final section = sections[sectionIndex];
      if (!section.isHtml) continue;

      final text = await documentText(section.name);
      if (text == null) continue;

      for (final match in compiled.findMatches(text)) {
        if (results.length >= maxMatches) {
          isTruncated = true;
          break;
        }

        results.add(
          SearchMatch(
            sectionIndex: sectionIndex,
            sectionName: section.name,
            start: match.start,
            end: match.end,
            snippet: searchSnippet(text, match.start, match.end, contextChars),
          ),
        );
      }

      if (isTruncated) break;
    }

    return SearchResults(query: query, matches: results, isTruncated: isTruncated);
  }

  /// Whole-book progression, measured in the host of the engine: walks
  /// every HTML section once, materializing one at a time.
  Future<BookProgression> computeProgression() async {
    _ensureOpen();
    final lengths = <int>[];
    for (final section in book.readingOrder) {
      final length = section.isHtml ? (await documentText(section.name))?.length ?? 0 : 0;
      lengths.add(length);
    }

    return BookProgression.fromSectionLengths(lengths);
  }

  /// Whole-book statistics over the canonical plain text.
  Future<BookStatistics> computeStatistics() async {
    _ensureOpen();
    final texts = <String>[];
    for (final section in book.readingOrder) {
      final file = section.isHtml ? await textFile(section.name) : null;
      texts.add(file?.plainText ?? '');
    }

    return BookStatistics.fromTexts(texts);
  }

  /// Resolves [cfi] against the book, loading only the addressed
  /// document. Book-level CFIs (`epubcfi(/6/N!…)`) name the spine item;
  /// the document loads, then the shared resolver runs on a projection
  /// holding just that content. Returns null for malformed or
  /// unresolvable CFIs, like the inline resolver.
  Future<EpubCfiLocation?> resolveCfi(final String cfi) async {
    _ensureOpen();
    if (book is! EpubBook) return null;

    final parsed = EpubCfi.tryParse(cfi);
    if (parsed == null) return null;

    final contentIndex = _spineIndexOf(parsed);
    if (contentIndex == null) return null;

    final sectionPath = _sectionPathFor(contentIndex);
    if (sectionPath == null) return null;
    if (await documentText(sectionPath) == null) return null;

    return _projection().resolveCfi(parsed);
  }

  /// Builds a book-level CFI for a reading position, loading the
  /// addressed document when needed. Range errors keep the inline
  /// contract.
  Future<String> buildCfi({
    required final int contentIndex,
    required final int offsetInText,
  }) async {
    _ensureOpen();
    if (book is! EpubBook) throw const UnsealException('CFI building needs an EPUB session.');

    final sectionPath = _sectionPathFor(contentIndex);
    if (sectionPath == null) {
      throw RangeError.range(contentIndex, 0, book.readingOrder.length - 1, 'contentIndex');
    }
    if (await documentText(sectionPath) == null) {
      throw RangeError.range(contentIndex, 0, book.readingOrder.length - 1, 'contentIndex');
    }

    return _projection().buildEpubCfi(contentIndex: contentIndex, offsetInText: offsetInText);
  }

  /// Advances the resident search index by at most [maxSections]
  /// sections, materializing each section's canonical text on demand —
  /// the session's own content path, so header placeholders are never
  /// indexed. The first call declares eligibility from the reading
  /// order and fixes the index [identity]; later calls with a
  /// different identity fail typed. Returns the coverage wire.
  Future<Map<String, Object?>> searchIndexEnsure(
    final int maxSections,
    final SearchIndexIdentity? identity,
  ) async {
    _ensureOpen();
    var index = _searchIndex;
    if (index == null) {
      index = BookSearchIndex.empty(
        identity: identity ?? const SearchIndexIdentity(),
        extractionProfile: book is PdfBook ? (book as PdfBook).canonicalTextProfile : null,
      );
      _searchIndexPending = index.beginEligible(book.readingOrder);
      _searchIndex = index;
    } else if (identity != null && !identity.isCompatibleWith(index.identity)) {
      throw const SearchIndexInvalidArgumentException(
        'The resident search index was built with a different identity.',
      );
    }
    var budget = maxSections < 0 ? 0 : maxSections;
    final pending = _searchIndexPending ?? const <(int, String)>[];
    while (budget > 0 && pending.isNotEmpty) {
      final (sectionIndex, path) = pending.first;
      pending.removeAt(0);
      budget--;
      // Materialization is the content path itself: one bounded batch
      // per op, cancellation observable by stopping the calls.
      final text = await documentText(path);
      if (text == null) {
        index.failSection(sectionIndex: sectionIndex, path: path);
      } else {
        index.addSection(sectionIndex: sectionIndex, path: path, text: text);
      }
    }

    return index.coverage.toWire();
  }

  /// Runs an indexed query over the resident index (partial coverage
  /// allowed; the result carries it), as the indexed-results wire.
  Map<String, Object?> searchIndexQuery(
    final String query, {
    required final IndexedQueryMode mode,
    required final int? maxMatches,
    required final int? maxExpansions,
    required final int contextChars,
  }) {
    _ensureOpen();
    final index = _searchIndex;
    if (index == null) {
      throw const SearchIndexException('No resident search index; run searchIndexEnsure first.');
    }

    return encodeIndexedSearchResultsWire(
      index.query(
        query,
        mode: mode,
        maxMatches: maxMatches,
        maxExpansions: maxExpansions,
        contextChars: contextChars,
      ),
    );
  }

  /// Serializes the complete resident index with its extraction profile.
  Map<String, Object?> searchIndexExport() {
    _ensureOpen();
    final index = _searchIndex;
    if (index == null) {
      throw const SearchIndexException('No resident search index; run searchIndexEnsure first.');
    }

    return index.serialize();
  }

  /// Validates and adopts an imported index. The reading order must
  /// match this session's book, and every section's text is
  /// re-digested through the session's materialization before the
  /// postings are trusted.
  Future<Map<String, Object?>> searchIndexImport(
    final Map<String, Object?> payload,
    final SearchIndexIdentity? identity,
  ) async {
    _ensureOpen();
    final orderRevision = payload['readingOrderRevision'];
    if (orderRevision != readingOrderRevisionOf(book.readingOrder)) {
      throw const SearchIndexIncompatibleException(
        'The imported index was built over a different reading order.',
      );
    }
    // Materialize every indexed section through the session's own
    // content path first, so the synchronous import verification reads
    // live text like the 1.3.0 cold-session import did. The texts are
    // held for the import call only — the LRU may evict under them.
    final importedTexts = <String, String>{};
    final sectionsWire = payload['sections'];
    if (sectionsWire is List<Object?>) {
      final order = book.readingOrder;
      for (final sectionWire in sectionsWire) {
        if (sectionWire is! List<Object?> || sectionWire.length < 2) continue;
        final sectionIndex = sectionWire[0];
        final path = sectionWire[1];
        if (sectionIndex is! int || path is! String) continue;
        if (sectionIndex < 0 || sectionIndex >= order.length) continue;
        if (order[sectionIndex].name != path) continue;

        final text = await documentText(path);
        if (text != null) importedTexts[path] = text;
      }
    }
    final index = BookSearchIndex.deserialize(
      payload,
      book: book,
      identity: identity,
      extractionProfile: book is PdfBook ? (book as PdfBook).canonicalTextProfile : null,
      sectionText: (final sectionIndex, final path) {
        final order = book.readingOrder;
        if (sectionIndex >= order.length || order[sectionIndex].name != path) return null;

        return importedTexts[path];
      },
    );
    _searchIndex?.dispose();
    _searchIndex = index;
    _searchIndexPending = const <(int, String)>[];

    return index.coverage.toWire();
  }

  /// Drops the resident index and releases its memory.
  void searchIndexDrop() {
    _ensureOpen();
    _searchIndex?.dispose();
    _searchIndex = null;
    _searchIndexPending = null;
  }

  /// Releases the container source and the cache. Further ops throw
  /// [SessionClosedException]. Remote readers are not closed here —
  /// the host's gate owns their source.
  void close() {
    if (_closed) return;

    _closed = true;
    _searchIndex?.dispose();
    _searchIndex = null;
    _searchIndexPending = null;
    _cache.clear();
    // The PDF branch owns no archive wrapper: the raw source itself
    // carries the file handle (the PdfByteSource is a view over it).
    if (_ownsReader) {
      if (_source != null) {
        unawaited(_source.close());
      } else {
        _bytes.close();
      }
    }
  }

  void _ensureOpen() {
    if (_closed) throw const SessionClosedException();
  }

  String? _sectionPathFor(final int contentIndex) {
    final order = book.readingOrder;
    if (contentIndex < 0 || contentIndex >= order.length) return null;

    return order[contentIndex].name;
  }

  /// The reading-order index a CFI addresses — the same
  /// `spineStep.index ~/ 2 - 1` arithmetic the shared resolver applies,
  /// needed here to load the document before the resolver runs.
  int? _spineIndexOf(final EpubCfi cfi) {
    final segments = cfi.start.segments;
    if (segments.isEmpty) return null;

    final spineSegment = segments.first;
    if (spineSegment.steps.isEmpty) return null;

    final spineStep = spineSegment.steps.last;
    if (spineStep.isText || spineStep.index == 0) return null;

    return spineStep.index ~/ 2 - 1;
  }

  /// An [EpubBook] equal to the header except that `files.html` holds
  /// the currently cached documents — the shape the shared CFI
  /// resolver and builder consume.
  EpubBook _projection() {
    final header = book as EpubBook;
    final html = <TextFile>[
      for (final entry in _cache.values)
        if (entry.text != null) entry.text!,
    ];

    return EpubBook(
      navigation: header.navigation,
      pageList: header.pageList,
      landmarks: header.landmarks,
      files: Files(
        images: const <BinaryFile>[],
        css: const <TextFile>[],
        html: html,
        fonts: const <BinaryFile>[],
        others: const <BinaryFile>[],
      ),
      cover: header.cover,
      package: header.package,
      spinePaths: header.spinePaths,
      spineIdrefs: header.spineIdrefs,
      contentViewports: header.contentViewports,
      nonLinearSpinePaths: header.nonLinearSpinePaths,
      archiveEntries: header.archiveEntries,
    );
  }

  void _store(final String key, final _CacheEntry entry) {
    _cache[key] = entry;
    _evictOverBudget();
  }

  void _touch(final String key) {
    final entry = _cache.remove(key);
    if (entry != null) _cache[key] = entry;
  }

  void _evictOverBudget() {
    var budget = 0;
    for (final entry in _cache.values) {
      budget += entry.weightBytes;
    }

    final limit = _policy.effectiveCacheBytes;
    while (budget > limit && _cache.isNotEmpty) {
      final oldest = _cache.keys.first;
      budget -= _cache.remove(oldest)!.weightBytes;
    }
  }

  /// PDF session over a random-access byte source. The header build
  /// parses the structure and samples the reflow plan, so a broken or
  /// encrypted document fails right here with the eager parse's typed
  /// error. The engine seeds its cache with the sampled extractions.
  static Future<SessionEngine> _openPdfSource(
    final PdfByteSource pdfSource,
    final AsyncByteReader bytes,
    final SessionPolicy policy,
    final String password, {
    required final bool ownsReader,
  }) async {
    final header = buildPdfSessionHeader(pdfSource, password: password, policy: policy);
    final engine =
        SessionEngine._(header.book, null, bytes, bytes.length, policy, ownsReader: ownsReader)
          .._pdf = PdfSessionContent(
            book: header.book,
            source: pdfSource,
            document: header.document,
            extractor: header.extractor,
            plan: header.plan,
          );

    for (var i = 0; i < header.sampledPageTexts.length; i++) {
      engine._store('page_${i + 1}.html', _CacheEntry(pdfPage: header.sampledPageTexts[i]));
    }

    return engine;
  }

  /// The PDF page document at [path] (`page_<i>.html`, 1-based), or
  /// null for any other path.
  Future<TextFile?> _pdfTextFile(final String path) async {
    final match = _pdfPagePathPattern.firstMatch(path);
    if (match == null) return null;

    final page = int.parse(match.group(1)!);
    if (page < 1 || page > (_pdf!.book.pageCount)) return null;

    final cached = _cache[path];
    if (cached != null && cached.text != null) {
      _touch(path);

      return cached.text;
    }

    return (await _pdfMaterialize(page)).text;
  }

  /// Materializes page [page] (1-based): the page's text plus — the
  /// frozen §3.4 decision — page [page] − 1's geometry when it exists,
  /// reflowed together so the continuation flag between the two pages
  /// is computed exactly, then the pair's canonical line set. Both
  /// extractions cache; the target's entry carries its [TextFile] and
  /// canonical [PdfPageText] together.
  Future<_CacheEntry> _pdfMaterialize(final int page) async {
    final pdf = _pdf!;
    final path = 'page_$page.html';
    final cached = _cache[path];
    if (cached != null && cached.text != null) {
      _touch(path);

      return cached;
    }

    final pdfBook = pdf.book;
    final previousPage = page - 1;
    final List<PdfPageText> texts;
    final List<PdfPage> pages;
    if (previousPage >= 1) {
      texts = <PdfPageText>[await _pdfExtract(previousPage), await _pdfExtract(page)];
      pages = <PdfPage>[pdfBook.pages[previousPage - 1], pdfBook.pages[page - 1]];
    } else {
      texts = <PdfPageText>[await _pdfExtract(page)];
      pages = <PdfPage>[pdfBook.pages[0]];
    }

    final (files, canonicalTexts) = PdfReflow.applyWithPlan(
      texts,
      pages,
      pdf.plan,
      firstPageNumber: previousPage >= 1 ? previousPage : 1,
      computeContinuations: true,
    );
    final entry = _CacheEntry(text: files.last, pdfPage: canonicalTexts.last);
    _store(path, entry);

    return entry;
  }

  /// The extracted text of page [page] (1-based), reusing the
  /// extraction cached at open or by an earlier materialization.
  Future<PdfPageText> _pdfExtract(final int page) async {
    final pdf = _pdf!;
    final path = 'page_$page.html';
    final cached = _cache[path];
    if (cached != null && cached.pdfPage != null) {
      _touch(path);

      return cached.pdfPage!;
    }

    final extracted = pdf.extractor.extract(pdf.book.pages[page - 1], onImage: _discardPdfImage);
    // Seeding only fills empty slots: a materialized entry (text +
    // lines) is never downgraded to an extraction-only one.
    if (_cache[path] == null) _store(path, _CacheEntry(pdfPage: extracted));

    return extracted;
  }

  /// The image bytes a `images/pdf-image-<n>.<ext>` path names,
  /// decoded on demand by object number; null for unknown paths,
  /// absent objects and undecodable codecs. No eager-style cap: the
  /// header never lists images, so serving is the only dedup that
  /// matters (documented delta against `_extractPageContent`).
  Future<Uint8List?> _pdfResource(final String path) async {
    final match = _pdfImagePathPattern.firstMatch(path);
    if (match == null) return null;

    final cached = _cache[path];
    if (cached != null && cached.bytes != null) {
      _touch(path);

      return cached.bytes;
    }

    final extension = match.group(2)!;
    final decoded = decodePdfImageObject(_pdf!.document, int.parse(match.group(1)!));
    if (decoded == null || decoded.$2 != extension) return null;

    _store(path, _CacheEntry(bytes: decoded.$1));

    return decoded.$1;
  }

  /// Inventory dispatch over a zip container: EPUB when the structure
  /// says so, CBZ for comic inventories, explicit refusal for other zip
  /// books (office documents, zipped FB2/HTML/TXT, Calibre comic
  /// collections).
  static Future<SessionEngine> _openZipSource(
    final AsyncZipRandomAccess source,
    final AsyncByteReader bytes,
    final DetectedFormat? detected,
    final SessionPolicy policy, {
    required final bool ownsReader,
  }) async {
    SessionUnsupportedFormatException unsupported(final String family) {
      return SessionUnsupportedFormatException(
        'The ${family.isEmpty ? 'zip' : family} container has no progressive session support; '
        'open it with Unseal.read instead.',
      );
    }

    try {
      final names = <String>[
        for (final record in source.entries)
          if (record.isFile) record.name.toLowerCase(),
      ];
      // Zip containers that are not EPUB-or-CBZ books: office documents,
      // zipped FB2/HTML/TXT, Calibre comic collections. The full parse
      // owns those; the session refuses them explicitly.
      final isOtherZipBook =
          names.any((final name) => name == 'comics.txt') ||
          names.any((final name) => name == 'word/document.xml') ||
          names.any((final name) => name == 'content.xml') ||
          names.any((final name) => name.endsWith('.fb2')) ||
          names.any(
            (final name) =>
                !name.contains('/') && (name.endsWith('.html') || name.endsWith('.htm')),
          );
      if (isOtherZipBook) throw unsupported(detected?.name ?? '');

      final looksLikeEpub =
          source.find('META-INF/container.xml') != null ||
          names.any((final name) => name.endsWith('.opf'));
      // A bytes-less source carries no detection signature: the
      // container inventory decides, like the eager dispatch's archive
      // checks.
      final epubCandidate = detected == null || detected == DetectedFormat.epub;
      if (epubCandidate && looksLikeEpub) {
        final book = await buildEpubSessionHeader(source, policy: policy);

        return SessionEngine._(book, source, bytes, bytes.length, policy, ownsReader: ownsReader);
      }

      var hasImages = false;
      for (final record in source.entries) {
        if (!record.isFile || record.name.toLowerCase() == 'comicinfo.xml') continue;
        if (sniffImageType(await source.head(record, 64)) != null) {
          hasImages = true;

          break;
        }
      }
      if (!hasImages) throw unsupported(detected?.name ?? '');
      final book = await buildComicSessionHeader(source, format: BookFormat.cbz, policy: policy);

      return SessionEngine._(book, source, bytes, bytes.length, policy, ownsReader: ownsReader);
    } on SessionUnsupportedFormatException {
      _closeOwned(source, bytes, ownsReader);
      rethrow;
    } on UnsealException {
      _closeOwned(source, bytes, ownsReader);
      rethrow;
    }
  }

  /// Comic session over a RAR container. The header build sniffs every
  /// entry, so a CBR the eager parse would reject (undecodable
  /// compressed entries, bombs past the guards) fails right here with
  /// the same typed error.
  static Future<SessionEngine> _openComicSource(
    final SyncAsyncArchive source,
    final AsyncByteReader bytes,
    final SessionPolicy policy, {
    required final bool ownsReader,
  }) async {
    try {
      final book = await buildComicSessionHeader(source, format: BookFormat.cbr, policy: policy);

      return SessionEngine._(book, source, bytes, bytes.length, policy, ownsReader: ownsReader);
    } on UnsealException {
      _closeOwned(source, bytes, ownsReader);
      rethrow;
    }
  }

  static void _closeOwned(
    final AsyncArchiveRandomAccess source,
    final AsyncByteReader bytes,
    final bool ownsReader,
  ) {
    if (!ownsReader) return;

    unawaited(source.close());
  }
}

/// A [PdfByteSource] view over a [ZipByteSource] — the file-backed
/// open path keeps a single descriptor serving both the document
/// parser and the range op.
final class _PdfSourceOverZip implements PdfByteSource {
  _PdfSourceOverZip(this._zip);

  final ZipByteSource _zip;

  @override
  int get length => _zip.length;

  @override
  Uint8List read(final int offset, final int count) => _zip.read(offset, count);

  @override
  void close() => _zip.close();
}

/// One cached container entry: at most one of the payloads is set.
final class _CacheEntry {
  _CacheEntry({this.bytes, this.text, this.pdfPage});

  final Uint8List? bytes;
  final TextFile? text;

  /// The PDF branch's canonical post-reflow line set for the same
  /// page [text] holds — the geometry `loadPdfPageLines` serves.
  final PdfPageText? pdfPage;

  int get weightBytes {
    final raw = bytes;
    if (raw != null) return raw.length;

    final text = this.text;
    if (text != null) {
      // Text counts by UTF-16 code units, like the EPUB branch; the
      // line set rides along at a per-line estimate (geometry objects,
      // not raw bytes).
      return text.content.length * 2 + (pdfPage?.lines.length ?? 0) * 64;
    }

    final lines = pdfPage?.lines;
    if (lines != null) return lines.length * 64;

    return 0;
  }
}

/// The PDF branch's resident state: the header book, the byte source,
/// the parsed document, the shared extractor and the sampled reflow
/// plan.
///
/// Lives only on PDF sessions; the zip/RAR branches keep theirs in the
/// archive container and cache.
final class PdfSessionContent {
  /// Builds the state from the open header's parts.
  PdfSessionContent({
    required this.book,
    required this.source,
    required this.document,
    required this.extractor,
    required this.plan,
  });

  /// The header book (placeholder pages), so page geometry and the
  /// page count sit next to the extraction state.
  final PdfBook book;

  /// The byte source the document parsed from; `close` releases it.
  final PdfByteSource source;

  /// The parsed document structure the extractor reads through.
  final PdfDocument document;

  /// The one extractor the session materializes pages with — its font
  /// caches stay warm across pages, like the eager parse's.
  final PdfTextExtractor extractor;

  /// The sampled reflow plan every page materializes under.
  final PdfReflowPlan plan;
}

void _discardPdfImage(final int objectNumber, final Uint8List bytes, final String extension) {
  // Session pages keep image placements, not image bytes: files
  // decode on demand through the resource op.
}
