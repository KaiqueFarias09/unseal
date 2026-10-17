import 'dart:convert' as convert;
import 'dart:math' as math;
import 'dart:typed_data';

import '../../foundation/archive/archive_random_access.dart';
import '../../foundation/archive/zip_byte_source.dart';
import '../../foundation/archive/zip_random_access.dart';
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
/// The engine is pure and synchronous: it owns an [ArchiveRandomAccess]
/// source (zip or RAR) plus a byte-budgeted LRU of inflated entries and
/// runs inside whatever host the platform layer chooses — a long-lived
/// isolate, a Web Worker, or the calling thread as a fallback.
/// Transports turn its results into small messages; the parsed book
/// never crosses a boundary whole.
final class SessionEngine {
  SessionEngine._(this.book, this._source, this._bytes, this._byteLength, this._policy)
    : _htmlPathSpace = book is EpubBook;

  /// Opens [bytes], inflating only the container's structural
  /// documents.
  ///
  /// Throws [SessionUnsupportedFormatException] for formats the
  /// progressive slice does not cover (everything but EPUB, CBZ, CBR
  /// and PDF today); callers fall back to `Unseal.read`.
  factory SessionEngine.openBytes(
    final Uint8List bytes, {
    final String password = '',
    final SessionPolicy policy = const SessionPolicy(),
  }) {
    if (bytes.isEmpty) throw EmptyBytesException();

    final detected = detectFormat(bytes);
    switch (detected) {
      case DetectedFormat.epub:
        // Zip containers are refined by inventory: EPUB or CBZ.
        final container = MemoryZipByteSource(bytes);

        return _openZipSource(ZipRandomAccess.open(container), container, detected, policy);
      case DetectedFormat.comic:
        // The comic detection signature is the RAR marker.
        final container = MemoryZipByteSource(bytes);

        return _openComicSource(RarRandomAccess.open(container), container, policy);
      case DetectedFormat.pdf:
        // The document parser keeps the bytes as views; the raw
        // source stays addressable for the range op.
        final container = MemoryZipByteSource(bytes);

        return _openPdfSource(MemoryPdfByteSource(bytes), container, policy, password);
      default:
        throw SessionUnsupportedFormatException(
          'The ${detected.name} format has no progressive session support; '
          'open it with Unseal.read instead.',
        );
    }
  }

  /// Opens a random-access byte source (file-backed on the VM). A
  /// bounded prefix rejects formats that are not ZIP or RAR containers;
  /// the inventory then distinguishes EPUB from CBZ. Container-level
  /// guard failures (including [Zip64NotSupportedException]) surface
  /// from here.
  factory SessionEngine.openSource(
    final ZipByteSource source, {
    final String password = '',
    final SessionPolicy policy = const SessionPolicy(),
  }) {
    if (source.length == 0) {
      source.close();
      throw EmptyBytesException();
    }

    final prefixLength = source.length < _sessionFormatProbeBytes
        ? source.length
        : _sessionFormatProbeBytes;
    final DetectedFormat detected;
    try {
      detected = detectFormat(source.read(0, prefixLength));
    } on FormatNotSupportedException {
      source.close();
      throw const SessionUnsupportedFormatException(
        'This format has no progressive session support; open it with Unseal.readFile instead.',
      );
    } on Object {
      source.close();
      rethrow;
    }

    switch (detected) {
      case DetectedFormat.comic:
        try {
          return _openComicSource(RarRandomAccess.open(source), source, policy);
        } on Object {
          source.close();
          rethrow;
        }
      case DetectedFormat.epub:
        try {
          return _openZipSource(ZipRandomAccess.open(source), source, detected, policy);
        } on Object {
          source.close();
          rethrow;
        }
      case DetectedFormat.pdf:
        // One file handle serves both the document parser and the
        // range op: the PdfByteSource is a view over the same
        // ZipByteSource, so no second file descriptor opens.
        try {
          return _openPdfSource(_PdfSourceOverZip(source), source, policy, password);
        } on Object {
          source.close();
          rethrow;
        }
      default:
        source.close();
        throw SessionUnsupportedFormatException(
          'The ${detected.name} format has no progressive session support; '
          'open it with Unseal.readFile instead.',
        );
    }
  }

  /// The header book: complete structure, empty content. A concrete
  /// `EpubBook`, `ComicBook` or `PdfBook`, so spine-driven consumers
  /// work unchanged.
  final Book book;

  /// The archive container for the zip/RAR branches; null for PDF,
  /// which owns no archive — its content ops route through [_pdf].
  final ArchiveRandomAccess? _source;

  /// The raw container source the range op slices; both archive
  /// wrappers are built over it, and the PDF parser reads the same
  /// source through a [PdfByteSource] view.
  final ZipByteSource _bytes;

  /// Total byte length of the raw container source.
  final int _byteLength;

  final SessionPolicy _policy;
  final bool _htmlPathSpace;
  bool _closed = false;

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
  Uint8List? resource(final String path) {
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

    final bytes = source.inflate(record);
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
  Uint8List bytesRange(final int offset, final int count) {
    _ensureOpen();
    if (offset < 0) throw RangeError.range(offset, 0, _byteLength, 'offset');
    if (count < 0) throw RangeError.range(count, 0, null, 'count');
    if (offset > _byteLength) throw RangeError.range(offset, 0, _byteLength, 'offset');

    final clamped = math.min(math.min(count, _byteLength - offset), _policy.effectiveRangeMaxBytes);

    return _bytes.read(offset, clamped);
  }

  /// The canonical [TextFile] of a content document, or null when the
  /// entry does not exist.
  TextFile? textFile(final String path) {
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

    final bytes = source.inflate(record);
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
  PdfPageText loadPdfPageLines(final int pageIndex) {
    _ensureOpen();
    final pdf = _pdf;
    final pageCount = pdf?.book.pageCount ?? 0;
    if (pageIndex < 0 || pageIndex >= pageCount) {
      throw RangeError.range(pageIndex, 0, pageCount - 1, 'pageIndex');
    }

    return _pdfMaterialize(pageIndex + 1).pdfPage!;
  }

  /// The stable structure of one PDF page (0-based): words, blocks,
  /// columns and tables with geometry, the source-line space and the
  /// mapping into the page's canonical text. Built against the
  /// session's sampled reflow plan — the `session-sample` scope, a
  /// profile distinct from the eager document's. Negative indexes and
  /// indexes past the page count throw [RangeError]. PDF sessions
  /// only.
  PdfPageStructure loadPdfPageStructure(final int pageIndex) {
    _ensureOpen();
    final pdf = _pdf;
    final pageCount = pdf?.book.pageCount ?? 0;
    if (pageIndex < 0 || pageIndex >= pageCount) {
      throw RangeError.range(pageIndex, 0, pageCount - 1, 'pageIndex');
    }

    final canonical = _pdfMaterialize(pageIndex + 1).pdfPage!;
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
  String? documentText(final String path) {
    final file = textFile(path);

    return file == null ? null : documentTextOf(file);
  }

  /// Raw decoded source of a content document — the HTML/CSS text as
  /// stored (markup included), the shape servers and CFI document
  /// parsers need.
  String? documentSource(final String path) => textFile(path)?.content;

  /// Full-text search with the [BookSearch.search] contract, executed
  /// section by section so only one chapter is materialized at a time.
  SearchResults search(
    final String query, {
    final SearchMode mode = SearchMode.contains,
    final bool isCaseSensitive = false,
    final bool isTolerant = true,
    final int nearChars = 60,
    final int contextChars = 48,
    final int maxMatches = 200,
  }) {
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

      final text = documentText(section.name);
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
  BookProgression computeProgression() {
    _ensureOpen();
    final lengths = <int>[
      for (final section in book.readingOrder)
        section.isHtml ? (documentText(section.name)?.length ?? 0) : 0,
    ];

    return BookProgression.fromSectionLengths(lengths);
  }

  /// Whole-book statistics over the canonical plain text.
  BookStatistics computeStatistics() {
    _ensureOpen();

    return BookStatistics.fromTexts(<String>[
      for (final section in book.readingOrder)
        if (section.isHtml) textFile(section.name)?.plainText ?? '' else '',
    ]);
  }

  /// Resolves [cfi] against the book, loading only the addressed
  /// document. Book-level CFIs (`epubcfi(/6/N!…)`) name the spine item;
  /// the document loads, then the shared resolver runs on a projection
  /// holding just that content. Returns null for malformed or
  /// unresolvable CFIs, like the inline resolver.
  EpubCfiLocation? resolveCfi(final String cfi) {
    _ensureOpen();
    if (book is! EpubBook) return null;

    final parsed = EpubCfi.tryParse(cfi);
    if (parsed == null) return null;

    final contentIndex = _spineIndexOf(parsed);
    if (contentIndex == null) return null;

    final sectionPath = _sectionPathFor(contentIndex);
    if (sectionPath == null) return null;
    if (documentText(sectionPath) == null) return null;

    return _projection().resolveCfi(parsed);
  }

  /// Builds a book-level CFI for a reading position, loading the
  /// addressed document when needed. Range errors keep the inline
  /// contract.
  String buildCfi({required final int contentIndex, required final int offsetInText}) {
    _ensureOpen();
    if (book is! EpubBook) throw const UnsealException('CFI building needs an EPUB session.');

    final sectionPath = _sectionPathFor(contentIndex);
    if (sectionPath == null) {
      throw RangeError.range(contentIndex, 0, book.readingOrder.length - 1, 'contentIndex');
    }
    if (documentText(sectionPath) == null) {
      throw RangeError.range(contentIndex, 0, book.readingOrder.length - 1, 'contentIndex');
    }

    return _projection().buildEpubCfi(contentIndex: contentIndex, offsetInText: offsetInText);
  }

  /// Releases the container source and the cache. Further ops throw
  /// [SessionClosedException].
  void close() {
    if (_closed) return;

    _closed = true;
    _cache.clear();
    // The PDF branch owns no archive wrapper: the raw source itself
    // carries the file handle (the PdfByteSource is a view over it).
    if (_source != null) {
      _source.close();
    } else {
      _bytes.close();
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
  static SessionEngine _openPdfSource(
    final PdfByteSource pdfSource,
    final ZipByteSource bytes,
    final SessionPolicy policy,
    final String password,
  ) {
    final header = buildPdfSessionHeader(pdfSource, password: password, policy: policy);
    final engine = SessionEngine._(header.book, null, bytes, bytes.length, policy)
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
  TextFile? _pdfTextFile(final String path) {
    final match = _pdfPagePathPattern.firstMatch(path);
    if (match == null) return null;

    final page = int.parse(match.group(1)!);
    if (page < 1 || page > (_pdf!.book.pageCount)) return null;

    final cached = _cache[path];
    if (cached != null && cached.text != null) {
      _touch(path);

      return cached.text;
    }

    return _pdfMaterialize(page).text;
  }

  /// Materializes page [page] (1-based): the page's text plus — the
  /// frozen §3.4 decision — page [page] − 1's geometry when it exists,
  /// reflowed together so the continuation flag between the two pages
  /// is computed exactly, then the pair's canonical line set. Both
  /// extractions cache; the target's entry carries its [TextFile] and
  /// canonical [PdfPageText] together.
  _CacheEntry _pdfMaterialize(final int page) {
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
      texts = <PdfPageText>[_pdfExtract(previousPage), _pdfExtract(page)];
      pages = <PdfPage>[pdfBook.pages[previousPage - 1], pdfBook.pages[page - 1]];
    } else {
      texts = <PdfPageText>[_pdfExtract(page)];
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
  PdfPageText _pdfExtract(final int page) {
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
  Uint8List? _pdfResource(final String path) {
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
  static SessionEngine _openZipSource(
    final ZipRandomAccess source,
    final ZipByteSource bytes,
    final DetectedFormat? detected,
    final SessionPolicy policy,
  ) {
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
        final book = buildEpubSessionHeader(source, policy: policy);

        return SessionEngine._(book, source, bytes, bytes.length, policy);
      }

      var hasImages = false;
      for (final record in source.entries) {
        if (!record.isFile || record.name.toLowerCase() == 'comicinfo.xml') continue;
        if (sniffImageType(source.head(record, 64)) != null) {
          hasImages = true;

          break;
        }
      }
      if (!hasImages) throw unsupported(detected?.name ?? '');
      final book = buildComicSessionHeader(source, format: BookFormat.cbz, policy: policy);

      return SessionEngine._(book, source, bytes, bytes.length, policy);
    } on SessionUnsupportedFormatException {
      source.close();
      rethrow;
    } on UnsealException {
      source.close();
      rethrow;
    }
  }

  /// Comic session over a RAR container. The header build sniffs every
  /// entry, so a CBR the eager parse would reject (undecodable
  /// compressed entries, bombs past the guards) fails right here with
  /// the same typed error.
  static SessionEngine _openComicSource(
    final RarRandomAccess source,
    final ZipByteSource bytes,
    final SessionPolicy policy,
  ) {
    try {
      final book = buildComicSessionHeader(source, format: BookFormat.cbr, policy: policy);

      return SessionEngine._(book, source, bytes, bytes.length, policy);
    } on UnsealException {
      source.close();
      rethrow;
    }
  }
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

void _discardPdfImage(final int objectNumber, final Uint8List bytes, final String extension) {
  // Session pages keep image placements, not image bytes: files
  // decode on demand through the resource op.
}
