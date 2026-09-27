import 'dart:convert' as convert;
import 'dart:typed_data';

import '../../foundation/archive/zip_byte_source.dart';
import '../../foundation/archive/zip_random_access.dart';
import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../../foundation/images/image_type_sniffer.dart';
import '../../foundation/text/canonical_document_text.dart';
import '../cfi/epub_cfi.dart';
import '../cfi/epub_cfi_resolver.dart';
import '../detection/detect_format.dart';
import '../detection/entities/detected_format.dart';
import '../epub/codec/epub_xml.dart';
import '../epub/entities/entities.dart';
import '../epub/exceptions/exceptions.dart';
import '../reading/book_progression.dart';
import '../search/book_search.dart';
import '../search/entities/search_match.dart';
import '../search/entities/search_mode.dart';
import '../search/entities/search_results.dart';
import '../search/query_compiler.dart';
import 'comic_session_header.dart';
import 'epub_session_header.dart';
import 'session_policy.dart';

/// Parses a book's structure up front and serves its content on demand.
///
/// The engine is pure and synchronous: it owns a [ZipRandomAccess]
/// source plus a byte-budgeted LRU of inflated entries and runs inside
/// whatever host the platform layer chooses — a long-lived isolate, a
/// Web Worker, or the calling thread as a fallback. Transports turn its
/// results into small messages; the parsed book never crosses a
/// boundary whole.
final class SessionEngine {
  SessionEngine._(this.book, this._source, this._policy) : _htmlPathSpace = book is EpubBook;

  /// Opens [bytes], inflating only the container's structural documents.
  ///
  /// Throws [SessionUnsupportedFormatException] for formats the
  /// progressive slice does not cover (everything but EPUB and CBZ
  /// today); callers fall back to `Unseal.read`.
  factory SessionEngine.openBytes(
    final Uint8List bytes, {
    final SessionPolicy policy = const SessionPolicy(),
  }) {
    if (bytes.isEmpty) throw EmptyBytesException();

    final detected = detectFormat(bytes);
    if (detected != DetectedFormat.epub && detected != DetectedFormat.comic) {
      throw SessionUnsupportedFormatException(
        'The ${detected.name} format has no progressive session support; '
        'open it with Unseal.read instead.',
      );
    }

    final source = ZipRandomAccess.open(MemoryZipByteSource(bytes));

    return _openSource(source, detected, policy);
  }

  /// Opens an already built random-access byte source (file-backed on
  /// the VM). The caller owns detection for bytes-less sources: this
  /// entry point assumes a zip container and classifies EPUB vs comic
  /// from the inventory. Container-level guard failures (including
  /// [Zip64NotSupportedException]) surface from here.
  factory SessionEngine.openSource(
    final ZipByteSource source, {
    final SessionPolicy policy = const SessionPolicy(),
  }) {
    return _openSource(ZipRandomAccess.open(source), null, policy);
  }

  /// The header book: complete structure, empty content. A concrete
  /// `EpubBook` or `ComicBook`, so spine-driven consumers work
  /// unchanged.
  final Book book;

  final ZipRandomAccess _source;
  final SessionPolicy _policy;
  final bool _htmlPathSpace;
  bool _closed = false;

  /// LRU of inflated entries keyed by container path: text entries keep
  /// their [TextFile] (the document-text memo hangs off the instance),
  /// binary entries keep raw bytes. Map literals are insertion-ordered,
  /// so "first key" is the least-recently-used entry.
  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  /// Whether the format materializes eagerly (always false for the
  /// progressive slice today).
  bool get isProgressive => true;

  /// Raw bytes of a container entry, or null when the entry does not
  /// exist.
  Uint8List? resource(final String path) {
    _ensureOpen();
    final record = _source.find(path);
    if (record == null) return null;

    final cached = _cache[record.name];
    if (cached != null && cached.bytes != null) {
      _touch(record.name);

      return cached.bytes;
    }

    final bytes = _source.inflate(record);
    _store(record.name, _CacheEntry(bytes: bytes));

    return bytes;
  }

  /// Byte lengths of several entries, without inflating: the serving
  /// layer uses this for byte-range headers.
  int? resourceLength(final String path) {
    _ensureOpen();
    final record = _source.find(path);

    return record?.uncompressedSize;
  }

  /// The canonical [TextFile] of a content document, or null when the
  /// entry does not exist.
  TextFile? textFile(final String path) {
    _ensureOpen();
    final record = _source.find(path);
    if (record == null) return null;

    final cached = _cache[record.name];
    if (cached != null && cached.text != null) {
      _touch(record.name);

      return cached.text;
    }

    final bytes = _source.inflate(record);
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

  /// Document text of a content document — the canonical offset space
  /// search and CFI address.
  String? documentText(final String path) {
    final file = textFile(path);

    return file == null ? null : documentTextOf(file);
  }

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
    if (trimmed.isEmpty) {
      return SearchResults(query: query, matches: results, isTruncated: false);
    }

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
    if (book is! EpubBook) {
      throw const UnsealException('CFI building needs an EPUB session.');
    }

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
    _source.close();
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

  static SessionEngine _openSource(
    final ZipRandomAccess source,
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
      if (isOtherZipBook) {
        throw unsupported(detected?.name ?? '');
      }

      final looksLikeEpub =
          source.find('META-INF/container.xml') != null ||
          names.any((final name) => name.endsWith('.opf'));
      // A bytes-less source carries no detection signature: the
      // container inventory decides, like the eager dispatch's archive
      // checks.
      final epubCandidate = detected == null || detected == DetectedFormat.epub;
      if (epubCandidate && looksLikeEpub) {
        final book = buildEpubSessionHeader(source, policy: policy);

        return SessionEngine._(book, source, policy);
      }

      var hasImages = false;
      for (final record in source.entries) {
        if (!record.isFile || record.name.toLowerCase() == 'comicinfo.xml') continue;
        if (sniffImageType(source.head(record, 64)) != null) {
          hasImages = true;
          break;
        }
      }
      if (hasImages) {
        final book = buildComicSessionHeader(source, policy: policy);

        return SessionEngine._(book, source, policy);
      }

      throw unsupported(detected?.name ?? '');
    } on SessionUnsupportedFormatException {
      source.close();
      rethrow;
    } on UnsealException {
      source.close();
      rethrow;
    }
  }
}

/// One cached container entry: at most one of the payloads is set.
final class _CacheEntry {
  _CacheEntry({this.bytes, this.text});

  final Uint8List? bytes;
  final TextFile? text;

  int get weightBytes {
    final raw = bytes;
    if (raw != null) return raw.length;
    final text = this.text;
    if (text != null) return text.content.length * 2;

    return 0;
  }
}
