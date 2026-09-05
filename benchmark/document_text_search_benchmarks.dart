// Benchmarks for the canonical document text ([documentText]) and the
// full-text search built on it ([BookSearch.search]).
//
// [documentText] is the shared character offset space of search, CFI
// and reading positions; its implementation is a multi-pass regex
// pipeline (~7 replaceAll passes). The first group pairs it against
// [extractPlainText] — the hand-optimized single-pass text utility —
// on the exact same input, then times [documentText] on individual
// sections of a real multi-section book so the per-KB cost is visible.
//
// `BookSearch.search` has no text cache: every call re-runs
// [documentText] over every HTML section in reading order before any
// pattern is matched. The notes and the double-call line below make
// that rebuild cost visible.

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'dart:io';

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

  // Deliberate A/B: the same chapter through the multi-pass regex
  // pipeline and through the single-pass utility.
  final html = largestHtmlFile;
  if (html != null) {
    group.add(
      'documentText(html) — chapter (${formatBytes(html.content.length)})',
      () => documentText(html.content),
      inputBytes: html.content.length,
      note: 'multi-pass regex pipeline; search/CFI offset space',
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

/// Times [documentText] on individual sections of the real-corpus
/// Shakespeare EPUB: the largest section plus four around the median
/// content length, each row carrying its own input size so the
/// per-KB cost can be compared across section sizes.
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
      () => documentText(section.content),
      inputBytes: section.content.length,
      note: 'html section $rank of ${sections.length}',
    );
  }
}

/// Times [BookSearch.search] once per mode on Alice (a handful of
/// sections) and on the real-corpus Shakespeare EPUB (hundreds of
/// sections). Every line's note reports what the untimed probe found
/// and states the rebuild-per-call cost.
void _runBookSearchGroup() {
  final group = BenchmarkGroup('BookSearch.search');
  final alice = BookReader.parseBook(epubAlice.bytes);

  _addSearch(group, alice, 'alice.epub', 'the', SearchMode.contains);
  _addSearch(group, alice, 'alice.epub', 'rabbit', SearchMode.wholeWords);
  _addSearch(group, alice, 'alice.epub', r'Al*c[ae]', SearchMode.regex);
  _addSearch(group, alice, 'alice.epub', 'white rabbit', SearchMode.proximity);

  // Two identical calls per sample: the total should come out ~2x the
  // single-call line above, proving nothing is cached between calls.
  final htmlBytes = _htmlContentLength(alice);
  group.add(
    'alice.epub — contains "the", twice per sample',
    () {
      final first = alice.search('the');
      final second = alice.search('the');
      return <Object>[first, second];
    },
    inputBytes: htmlBytes,
    note: '~2x the single call above means documentText is not cached',
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
  _addSearch(group, book, 'shakespeare', 'zephyr', SearchMode.contains);
  _addSearch(group, book, 'shakespeare', 'moiety', SearchMode.wholeWords);
  _addSearch(group, book, 'shakespeare', r'Zeph[a-z]+', SearchMode.regex);
  _addSearch(group, book, 'shakespeare', 'moiety dowry', SearchMode.proximity);
}

void _addSearch(
  final BenchmarkGroup group,
  final Book book,
  final String label,
  final String query,
  final SearchMode mode,
) {
  // Untimed probe: warms the code path up and documents the outcome.
  final probe = book.search(query, mode: mode);
  final matches = '${probe.matches.length} match${probe.matches.length == 1 ? '' : 'es'}';
  group.add(
    '$label — ${mode.name} "$query"',
    () => book.search(query, mode: mode),
    inputBytes: probe.truncated ? null : _htmlContentLength(book),
    note:
        '$matches${probe.truncated ? ' (capped at maxMatches)' : ''} · every call '
        'rebuilds documentText for all sections (no cache)',
  );
}

/// Memoized untimed parse of the real-corpus book; `null` when no
/// library is configured, the book is missing, or it fails to parse.
EpubBook? _shakespeareEpub() {
  if (_shakespeareResolved) {
    return _shakespeareBook;
  }
  _shakespeareResolved = true;
  final book = libraryRoot == null ? null : findLibraryBook(_shakespeareFileName);
  if (book != null) {
    try {
      _shakespeareBook = BookReader.parseBook(book.read()) as EpubBook;
    } on Object catch (error) {
      stdout.writeln('[${book.name}] skipped — parsing failed: $error');
    }
  }
  return _shakespeareBook;
}

EpubBook? _shakespeareBook;
bool _shakespeareResolved = false;

/// Total HTML content size of [book], as a throughput hint.
int _htmlContentLength(final Book book) =>
    book.files.html.fold<int>(0, (final total, final file) => total + file.content.length);

/// Picks [count] sections by content length: the largest plus the
/// rest evenly around the median, returned smallest first.
List<TextFile> _representativeSections(final List<TextFile> sections, final int count) {
  final sorted = sections.toList()
    ..sort((final a, final b) => a.content.length.compareTo(b.content.length));
  if (sorted.length <= count) {
    return sorted;
  }
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
