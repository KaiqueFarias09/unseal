// Benchmarks for the canonical document text ([DocumentTextScanner.scan]) and the
// full-text search built on it ([BookSearch.search]).
//
// [DocumentTextScanner.scan] is the shared character offset space of search, CFI
// and reading positions; its implementation is a single-pass scanner
// that bulk-copies text spans between markup. The first group pairs it
// against [extractPlainText] — the single-pass text utility — on the
// exact same input (cold compute, then [documentTextOf]'s Expando
// memo), then times [DocumentTextScanner.scan] on individual sections of a real
// multi-section book so the per-KB cost is visible.
//
// `BookSearch.search` memoizes the document text of every section
// ([documentTextOf]), so each pair below separates the cold first
// search (fresh parse, every section scanned) from the warm repeat
// (memo hits, pattern matching only).

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';

import 'benchmark_harness.dart';
import 'fixtures.dart';
import 'library_fixtures.dart';

/// The real-corpus book driving the per-section benchmarks: hundreds
/// of small HTML sections, ideal for measuring per-section cost.
const String _shakespeareFileName =
    'Complete Works of William Shakespeare (Ill - SHAKESPEARE, WILLIAM.epub';

/// How many representative sections are timed individually on the
/// real-corpus book: the largest plus the rest around the median.
const int _representativeSectionCount = 5;

/// Runs the document text and book search benchmark groups.
void runDocumentTextSearchBenchmarks() {
  _runDocumentTextGroup();
  _runBookSearchGroup();
}

void _runDocumentTextGroup() {
  final group = BenchmarkGroup('documentText');

  // Deliberate A/B: the same chapter through the single-pass scanner
  // and through the single-pass whitespace-collapsing utility, plus
  // the memoized accessor built on [DocumentTextScanner.scan].
  final html = largestHtmlFile;
  if (html != null) {
    group.add(
      'documentText(html) — chapter (${formatBytes(html.content.length)})',
      () => DocumentTextScanner(html.content).scan(),
      inputBytes: html.content.length,
      note: 'single-pass scanner; search/CFI offset space',
    );
    group.addFirstAccess<TextFile>(
      'documentTextOf — first access (same chapter)',
      24,
      () => TextFile(content: html.content, name: html.name, type: html.type, path: html.path),
      documentTextOf,
      note: 'fresh TextFile before each access (untimed); cold compute',
    );
    // The memo entry must exist before the timed cached run below;
    // the returned value is deliberately unused.
    // ignore: unnecessary_statements
    documentTextOf(html); // Pre-touch for the cached benchmark below.
    group.add(
      'documentTextOf — cached (same chapter)',
      () => documentTextOf(html),
      note: 'memoized Expando<TextFile> hit',
    );
    group.add(
      'extractPlainText(html) — same chapter (${formatBytes(html.content.length)})',
      () => extractPlainText(html.content),
      inputBytes: html.content.length,
      note: 'single-pass utility (collapses whitespace); A/B reference',
    );
  }

  _addRealCorpusSectionBenchmarks(group);
}

/// Times [DocumentTextScanner.scan] on individual sections of the real-corpus
/// Shakespeare EPUB: the largest section plus four around the median
/// content length, each row carrying its own input size so the
/// per-KB cost can be compared across section sizes, then the whole
/// book through the memoized accessor.
///
/// Parsing and section selection happen untimed.
void _addRealCorpusSectionBenchmarks(final BenchmarkGroup group) {
  final book = _shakespeareEpub();
  if (book == null) {
    skipLibraryGroup('documentText — real corpus');

    return;
  }

  final sections = book.files.html;
  for (final section in _representativeSections(sections, _representativeSectionCount)) {
    final rank = sections.indexOf(section) + 1;
    group.add(
      'documentText(html) — shakespeare ${section.name.split('/').last} '
      '(${formatBytes(section.content.length)})',
      () => DocumentTextScanner(section.content).scan(),
      inputBytes: section.content.length,
      note: 'html section $rank of ${sections.length}',
    );
  }
  for (final section in sections) {
    // Every section must be memoized before the timed warm run below;
    // the returned values are deliberately unused.
    // ignore: unnecessary_statements
    documentTextOf(section);
  }
  group.add(
    'documentTextOf — shakespeare all sections cached '
    '(${formatBytes(_htmlContentLength(book))})',
    () => <Object>[for (final section in sections) documentTextOf(section)],
    inputBytes: _htmlContentLength(book),
    note: 'memo hits over ${sections.length} sections',
  );
}

/// Times [BookSearch.search] once per mode on Alice (a handful of
/// sections) and on the real-corpus Shakespeare EPUB (hundreds of
/// sections). Every mode is measured cold (fresh parse per sample,
/// untimed; the first search computes the document text of every
/// section) and warm (the per-section memo is already filled, so only
/// pattern matching runs). The notes report what the untimed probe
/// found.
void _runBookSearchGroup() {
  final group = BenchmarkGroup('BookSearch.search');
  final alice = BookReader.parseBook(epubAlice.bytes);

  _addSearch(
    group,
    'alice.epub',
    alice,
    () => BookReader.parseBook(epubAlice.bytes),
    'the',
    SearchMode.contains,
    coldSamples: 16,
  );
  // Same query through the Unicode whole-word boundaries — the
  // regression timing for the boundary rewrite (zero-width ASCII `\b`
  // replaced by a trailing lookahead plus a per-candidate leading
  // check, so the `\p{...}` classes stay out of the scan path).
  _addSearch(
    group,
    'alice.epub',
    alice,
    () => BookReader.parseBook(epubAlice.bytes),
    'the',
    SearchMode.wholeWords,
    coldSamples: 12,
  );
  _addSearch(
    group,
    'alice.epub',
    alice,
    () => BookReader.parseBook(epubAlice.bytes),
    'rabbit',
    SearchMode.wholeWords,
    coldSamples: 12,
  );
  _addSearch(
    group,
    'alice.epub',
    alice,
    () => BookReader.parseBook(epubAlice.bytes),
    r'Al*c[ae]',
    SearchMode.regex,
    coldSamples: 12,
  );
  _addSearch(
    group,
    'alice.epub',
    alice,
    () => BookReader.parseBook(epubAlice.bytes),
    'white rabbit',
    SearchMode.proximity,
    coldSamples: 12,
  );

  _addRealCorpusSearchBenchmarks(group);
}

void _addRealCorpusSearchBenchmarks(final BenchmarkGroup group) {
  final book = _shakespeareEpub();
  if (book == null) {
    skipLibraryGroup('BookSearch.search — real corpus');

    return;
  }
  // Rare words so a full scan of every section happens before the
  // result cap can truncate the run (the notes report match counts).
  _addSearch(
    group,
    'shakespeare',
    book,
    () => BookReader.parseBook(_shakespeareEpubBytes()!) as EpubBook,
    'zephyr',
    SearchMode.contains,
    coldSamples: 6,
  );
  _addSearch(
    group,
    'shakespeare',
    book,
    () => BookReader.parseBook(_shakespeareEpubBytes()!) as EpubBook,
    'moiety',
    SearchMode.wholeWords,
    coldSamples: 6,
  );
  _addSearch(
    group,
    'shakespeare',
    book,
    () => BookReader.parseBook(_shakespeareEpubBytes()!) as EpubBook,
    r'Zeph[a-z]+',
    SearchMode.regex,
    coldSamples: 6,
  );
  _addSearch(
    group,
    'shakespeare',
    book,
    () => BookReader.parseBook(_shakespeareEpubBytes()!) as EpubBook,
    'moiety dowry',
    SearchMode.proximity,
    coldSamples: 6,
  );
}

/// Adds the cold/warm search pair for one query: cold measures the
/// first search on a freshly parsed book (parse untimed), warm the
/// repeat on the pre-probed instance whose section texts are already
/// memoized.
void _addSearch(
  final BenchmarkGroup group,
  final String label,
  final Book book,
  final Book Function() rebuildBook,
  final String query,
  final SearchMode mode, {
  required final int coldSamples,
}) {
  // Untimed probe: documents the outcome and fills the memo for the
  // warm variant below.
  final probe = book.search(query, mode: mode);
  final matches = '${probe.matches.length} match${probe.matches.length == 1 ? '' : 'es'}';

  group.addFirstAccess<Book>(
    '$label — ${mode.name} "$query" (cold)',
    coldSamples,
    rebuildBook,
    (final fresh) => fresh.search(query, mode: mode),
    note:
        '$matches${probe.isTruncated ? ' (capped at maxMatches)' : ''} · '
        'first search computes documentText for all sections',
  );
  group.add(
    '$label — ${mode.name} "$query" (warm)',
    () => book.search(query, mode: mode),
    inputBytes: probe.isTruncated ? null : _htmlContentLength(book),
    note: '$matches · documentText memoized per section',
  );
}

/// Memoized untimed parse of the real-corpus book; `null` when no
/// library is configured, the book is missing, or it fails to parse.
EpubBook? _shakespeareEpub() {
  if (_shakespeareResolved) return _shakespeareBook;

  _shakespeareResolved = true;
  final book = libraryRoot == null ? null : findLibraryBook(_shakespeareFileName);
  if (book != null) {
    try {
      _shakespeareBytes = book.read();
      _shakespeareBook = BookReader.parseBook(_shakespeareBytes!) as EpubBook;
    } on Object catch (error) {
      stdout.writeln('[${book.name}] skipped — parsing failed: $error');
    }
  }

  return _shakespeareBook;
}

/// The cached bytes of the real-corpus book, for fresh cold parses.
Uint8List? _shakespeareEpubBytes() => _shakespeareBytes;

EpubBook? _shakespeareBook;
Uint8List? _shakespeareBytes;
bool _shakespeareResolved = false;

/// Total HTML content size of [book], as a throughput hint.
int _htmlContentLength(final Book book) {
  return book.files.html.fold<int>(0, (final total, final file) => total + file.content.length);
}

/// Picks [count] sections by content length: the largest plus the
/// rest evenly around the median, returned smallest first.
List<TextFile> _representativeSections(final List<TextFile> sections, final int count) {
  final sorted = sections.toList()
    ..sort((final a, final b) => a.content.length.compareTo(b.content.length));
  if (sorted.length <= count) return sorted;

  final largest = sorted.removeLast();
  final median = sorted.length ~/ 2;
  final below = (count - 1) ~/ 2;
  final above = count - 2 - below;
  final picks = <TextFile>{
    for (var offset = -below; offset <= above; offset++)
      sorted[(median + offset).clamp(0, sorted.length - 1)],
  };

  return <TextFile>[...picks, largest]
    ..sort((final a, final b) => a.content.length.compareTo(b.content.length));
}
