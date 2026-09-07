// Benchmarks for the public getters of a parsed book: `metadata`,
// the lazy `statistics` / `MobiBook.chapters` (first access versus
// cached), `TextFile.plainText`, the convenience scalar getters and
// the `BookMetadata` utilities.

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'package:e_livre/e_livre.dart';

import 'benchmark_harness.dart';
import 'fixtures.dart';

/// Runs the parsed-book getter benchmarks.
void runGetterBenchmarks() {
  final epub = BookReader.parseBook(epubSmall.bytes) as EpubBook;
  final aliceEpub = BookReader.parseBook(epubAlice.bytes) as EpubBook;
  final mobi6 = BookReader.parseBook(mobi6Alice.bytes) as MobiBook;
  final mobi8 = BookReader.parseBook(mobi8Alice.bytes) as MobiBook;
  final fb2 = BookReader.parseBook(fb2Alice.bytes) as Fb2Book;
  final comic = BookReader.parseBook(comicSample.bytes) as ComicBook;

  final group = BenchmarkGroup('Parsed book getters');

  group.add(
    'metadata — EpubBook (${epubSmall.shortLabel})',
    () => epub.metadata,
    note: 'recomputed per access',
  );
  group.add(
    'metadata — MobiBook (${mobi6Alice.shortLabel})',
    () => mobi6.metadata,
    note: 'recomputed per access',
  );
  group.add(
    'metadata — Fb2Book (${fb2Alice.shortLabel})',
    () => fb2.metadata,
    note: 'stored field',
  );

  // Lazy members: the cold benchmark parses a fresh book before each
  // timed access (parse untimed); the warm one hits the memoized
  // `late final` value.
  group.addFirstAccess<Book>(
    'statistics — first access (${epubSmall.shortLabel})',
    24,
    () => BookReader.parseBook(epubSmall.bytes),
    (final book) => book.statistics,
    note: 'parse before each access untimed',
  );
  // Pre-touch so the timed access below hits the memoized value.
  // The statement intentionally initializes the lazy getter before timing.
  // ignore: unnecessary_statements
  epub.statistics;
  // The statement intentionally initializes the lazy getter before timing.
  // ignore: unnecessary_statements
  mobi6.statistics;
  // The statement intentionally initializes the lazy getter before timing.
  // ignore: unnecessary_statements
  mobi8.statistics;
  group.add(
    'statistics — cached (${epubSmall.shortLabel})',
    () => epub.statistics,
    note: 'memoized late final',
  );
  group.add(
    'statistics — cached (${mobi6Alice.shortLabel})',
    () => mobi6.statistics,
    note: 'memoized late final',
  );
  group.add(
    'statistics — cached (${mobi8Alice.shortLabel})',
    () => mobi8.statistics,
    note: 'memoized late final',
  );

  group.addFirstAccess<MobiBook>(
    'chapters — first access (${mobi6Alice.shortLabel})',
    12,
    () => BookReader.parseBook(mobi6Alice.bytes) as MobiBook,
    (final book) => book.chapters,
    note: 'parse before each access untimed',
  );
  // The statement intentionally initializes the lazy getter before timing.
  // ignore: unnecessary_statements
  mobi6.chapters;
  group.add(
    'chapters — cached (${mobi6Alice.shortLabel})',
    () => mobi6.chapters,
    note: 'memoized late final',
  );

  final html = largestHtmlFile;
  if (html != null) {
    group.add(
      'TextFile.plainText — largest HTML (${formatBytes(html.content.length)})',
      () => html.plainText,
      inputBytes: html.content.length,
      note: 'recomputed per access',
    );
  }

  group.add('title — EpubBook', () => epub.title);
  group.add('title — MobiBook', () => mobi6.title);
  group.add('title — Fb2Book', () => fb2.title);
  group.add('creators — MobiBook', () => mobi6.creators);
  group.add('version — EpubBook', () => epub.version);
  group.add('pageCount — ComicBook', () => comic.pageCount);
  group.add('images — EpubBook (alice)', () => aliceEpub.images);
  group.add('content — EpubBook (alice)', () => aliceEpub.content);

  _runMetadataUtilityBenchmarks(fb2.metadata);
}

void _runMetadataUtilityBenchmarks(final BookMetadata template) {
  final group = BenchmarkGroup('Metadata utilities');
  // copyWith keeps fields passed as null, so build the bare metadata
  // directly: no title and no authors triggers the filename fallback.
  const bareMetadata = BookMetadata(format: BookFormat.epub);
  const fallbackPath = '/books/Dune - Frank Herbert.epub';
  final statistics = BookStatistics.fromTexts([
    ?plainTextSample,
  ]);

  group.add(
    'BookMetadata.copyWith',
    () => template.copyWith(title: 'Benchmark', isbn: '978-0'),
  );
  group.add('mergeBookMetadata', () => mergeBookMetadata(template, template));
  group.add(
    'applyFilenameFallback — hit',
    () => applyFilenameFallback(bareMetadata, fallbackPath),
  );
  group.add(
    'applyFilenameFallback — miss',
    () => applyFilenameFallback(template, fallbackPath),
  );
  group.add('parseSeriesIndex', () => parseSeriesIndex('2.5'));
  group.add(
    'BookStatistics.estimatedReadingTime',
    statistics.estimatedReadingTime,
  );
}
