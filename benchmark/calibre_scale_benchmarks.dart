/// Benchmarks for library-sized inputs: dependency-free `metadata.db` reads and sort-key
/// computation over real, fixture, and synthetic book collections.
///
/// The metadata database group parses the real `metadata.db` of
/// the library pointed at by `ELIVRE_BENCH_LIBRARY` — sqlite-master
/// schema discovery, whole-table b-tree scans and the book / author /
/// series / tag / identifier / format joins — and compares it against
/// the reduced-schema fixture under `test/resources` (48 KB, 3 books)
/// so the cost of a real library's bigger schema is visible.
///
/// The `Sort keys at volume` group computes the package's title and author sort keys for each
/// readable, titled book in the real corpus. It falls back to in-repository fixtures when no
/// library is configured and derives a 1000-title synthetic volume from that corpus. The real
/// corpus carries Portuguese classics — `O cortiço`, `Os Maias`,
/// `A Moreninha`, `Memórias Póstumas de Brás Cubas` — so per-language
/// leading-article handling (`O `, `A `, `Os ` moved to the end) is
/// exercised for real, not only through unit tests.
library;

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'dart:io';

import 'package:e_livre/e_livre.dart';

import 'benchmark_harness.dart';
import 'fixtures.dart';
import 'library_fixtures.dart';

/// Runs both library-scale groups: the metadata.db reader and the sort-key volume benchmarks.
void runCalibreScaleBenchmarks() {
  _runCalibreDatabaseBenchmarks();
  _runSortKeyBenchmarks();
}

void _runCalibreDatabaseBenchmarks() {
  final root = libraryRoot;
  if (root == null) {
    skipLibraryGroup('Calibre metadata.db');

    return;
  }

  final dbFile = File('$root/metadata.db');
  if (!dbFile.existsSync()) {
    stdout.writeln('[Calibre metadata.db] skipped — no metadata.db under $root.');

    return;
  }

  final realBytes = dbFile.readAsBytesSync(); // untimed input load
  final realBooks = CalibreDatabase.parse(realBytes).books.length;
  final fixtureDb = loadFixture('calibre/metadata.db');
  final fixtureBooks = CalibreDatabase.parse(fixtureDb.bytes).books.length;

  final group = BenchmarkGroup('Calibre metadata.db');
  group.add(
    'CalibreDatabase.parse — real library (${formatBytes(realBytes.length)})',
    () => CalibreDatabase.parse(realBytes),
    inputBytes: realBytes.length,
    note: '$realBooks books · schema discovery + b-tree scans + joins',
  );
  group.add(
    'CalibreDatabase.parse — reduced fixture (${formatBytes(fixtureDb.bytes.length)})',
    () => CalibreDatabase.parse(fixtureDb.bytes),
    inputBytes: fixtureDb.bytes.length,
    note: '$fixtureBooks books · same reader, minimal schema',
  );
}

void _runSortKeyBenchmarks() {
  final group = BenchmarkGroup('Sort keys at volume');
  final corpus = _collectCorpus();
  if (corpus.isEmpty) {
    stdout.writeln('[Sort keys at volume] skipped — no readable book metadata.');

    return;
  }

  final synthetic = _syntheticVolume(corpus, 1000);
  final fallback = libraryRoot == null;

  group.add(
    'title + author sort — one pass over the corpus',
    () => _computeSortKeys(corpus),
    inputBytes: _characterCount(corpus),
    note: fallback ? 'fixture fallback · ${corpus.length} books' : '${corpus.length} books',
  );
  group.add(
    'title + author sort — 1000 synthetic titles',
    () => _computeSortKeys(synthetic),
    inputBytes: _characterCount(synthetic),
    note: 'varied reprises of the corpus titles',
  );
  group.add(
    'title sort — pt-BR articles (language pt-BR)',
    () {
      var sink = 0;
      for (final book in synthetic) {
        sink += computeTitleSortKey(book.title, language: 'pt-BR').length;
      }

      return sink;
    },
    inputBytes: _titleCharacterCount(synthetic),
    note: 'O / A / Os article stripping over 1000 titles',
  );
}

/// One corpus book reduced to the inputs of sort-key computation:
/// title, author names and the language selecting the article list.
final class _CorpusBook {
  /// Creates a corpus book snapshot.
  const _CorpusBook({required this.title, required this.authors, required this.language});

  /// The book title as stored in the file.
  final String title;

  /// Author names, in display order.
  final List<String> authors;

  /// The first declared language (`pt`, `en`, ...), or `null` when
  /// the file carries none.
  final String? language;
}

/// Reads the metadata of every corpus book once (untimed). Falls back
/// to the in-repo fixtures when no library is configured; unreadable
/// books are skipped with a printed warning.
List<_CorpusBook> _collectCorpus() {
  if (libraryRoot == null) return _fixtureCorpus();

  final corpus = <_CorpusBook>[];
  var untitled = 0;
  for (final book in libraryBooks) {
    try {
      final metadata = BookReader.readMetadataSync(book.read());
      final title = metadata.title;
      if (title == null || title.isEmpty) {
        untitled++;

        continue;
      }

      corpus.add(_fromMetadata(metadata));
    } catch (error) {
      stdout.writeln('[Sort keys at volume] skipped ${book.name} — $error');
    }
  }
  if (untitled > 0) {
    stdout.writeln('[Sort keys at volume] $untitled books without a title skipped.');
  }

  return corpus;
}

/// Corpus derived from the in-repo fixtures, used when no real
/// library is configured; still parsed once, untimed.
List<_CorpusBook> _fixtureCorpus() {
  final corpus = <_CorpusBook>[];
  for (final fixture in <BookFixture>[
    epubSmall,
    epubAlice,
    epubLinearAlgebra,
    mobi6Alice,
    mobi8Alice,
    fb2Alice,
  ]) {
    final metadata = BookReader.readMetadataSync(fixture.bytes);
    final title = metadata.title;
    if (title == null || title.isEmpty) continue;

    corpus.add(_fromMetadata(metadata));
  }

  return corpus;
}

_CorpusBook _fromMetadata(final BookMetadata metadata) {
  return _CorpusBook(
    title: metadata.title!,
    authors: metadata.authors,
    language: metadata.languages.isEmpty ? null : metadata.languages.first,
  );
}

/// Articles prepended while varying the synthetic titles; mixes
/// Portuguese and English leading articles so the stripping logic
/// stays hot.
const List<String> _syntheticArticles = <String>['', 'O ', 'A ', 'Os ', 'The ', 'Um '];

/// Edition-style suffixes appended while varying the synthetic titles.
const List<String> _syntheticSuffixes = <String>[
  '',
  ' (Edição comentada)',
  ' - Edição Exclusiva Amazon',
  ' [Annotated]',
  ': A Novel',
];

/// Builds [count] titles by repeating and varying the [corpus] titles
/// (article prefixes, edition suffixes) — untimed setup.
List<_CorpusBook> _syntheticVolume(final List<_CorpusBook> corpus, final int count) {
  final synthetic = <_CorpusBook>[];
  for (var i = 0; i < count; i++) {
    final base = corpus[i % corpus.length];
    final article = _syntheticArticles[i % _syntheticArticles.length];
    final suffix = _syntheticSuffixes[(i ~/ _syntheticArticles.length) % _syntheticSuffixes.length];
    synthetic.add(
      _CorpusBook(
        title: '$article${base.title}$suffix',
        authors: base.authors,
        language: base.language,
      ),
    );
  }

  return synthetic;
}

/// One pass computing both sort keys of every book; returns a cheap
/// checksum so the VM cannot discard the work.
int _computeSortKeys(final List<_CorpusBook> books) {
  var sink = 0;
  for (final book in books) {
    sink += computeTitleSortKey(book.title, language: book.language).length;
    sink += authorsToSortString(book.authors).length;
  }

  return sink;
}

/// Total title + author name character count of the corpus.
int _characterCount(final List<_CorpusBook> books) {
  var total = 0;
  for (final book in books) {
    total += book.title.length;
    for (final author in book.authors) {
      total += author.length;
    }
  }

  return total;
}

/// Total title character count of the corpus.
int _titleCharacterCount(final List<_CorpusBook> books) {
  var total = 0;
  for (final book in books) {
    total += book.title.length;
  }

  return total;
}
