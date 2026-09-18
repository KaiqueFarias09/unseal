// Whole-library throughput benchmarks over the user's real corpus.
//
// Unlike every other group — which measures one fixture book at a
// time — these scan the entire configured library in a single
// pass, exercising mixed formats at library scale. The corpus root
// comes from `ELIVRE_BENCH_LIBRARY` (see `library_fixtures.dart`);
// the whole group skips gracefully when it is unset.
//
// Giant singles pin the two largest books of a real library (a 98 MB
// MOBI textbook and an 81 MB AZW3) so regression sweeps can re-measure
// the format pipelines at sizes the checked-in fixtures never reach.

import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';

import 'benchmark_harness.dart';
import 'library_fixtures.dart';

/// The exact name of the largest real-corpus book (98.3 MB MOBI).
const String _masteringChemistryMobi =
    'Mastering Chemistry -- for Basic Chemistry - Karen C. Timberlake.mobi';

/// The exact name of the second-largest real-corpus book (81 MB AZW3).
const String _familiaRomanaAzw3 = 'Familia Romana (Lingua Latina) - Hans H. Orberg.azw3';

/// Runs the whole-library corpus benchmarks.
Future<void> runLibraryCorpusBenchmarks() async {
  if (libraryRoot == null || libraryBooks.isEmpty) {
    skipLibraryGroup('Real library corpus');

    return;
  }

  final group = BenchmarkGroup('Real library corpus');
  final books = libraryBooks;
  final totalBytes = books.fold<int>(0, (final sum, final book) => sum + book.size);
  group.add(
    'parseBook — whole library, single pass (${books.length} books)',
    () => _runLibraryPass(books, totalBytes, BookReader.parseBook, _parsePassTable),
    inputBytes: totalBytes,
    note: '${books.length} books, single pass',
  );
  group.add(
    'readMetadataSync — whole library, single pass (${books.length} books)',
    () => _runLibraryPass(books, totalBytes, BookReader.readMetadataSync, _metadataPassTable),
    inputBytes: totalBytes,
    note: '${books.length} books, single pass',
  );

  await _addGiantBookBenchmarks(
    group,
    findLibraryBook(_masteringChemistryMobi),
    'Mastering Chemistry mobi',
    withOpenFromBytes: true,
  );
  await _addGiantBookBenchmarks(group, findLibraryBook(_familiaRomanaAzw3), 'Familia Romana azw3');
}

final _FirstPassTable _parsePassTable = _FirstPassTable('parseBook');
final _FirstPassTable _metadataPassTable = _FirstPassTable('readMetadataSync');

/// Runs [operation] once per book in a single library pass, folding a
/// cheap fingerprint of every result into the returned checksum.
Object? _runLibraryPass(
  final List<LibraryBook> books,
  final int totalBytes,
  final Object? Function(Uint8List bytes) operation,
  final _FirstPassTable table,
) {
  var fingerprint = 0;
  var failures = 0;
  table.begin();
  final total = Stopwatch()..start();
  for (final book in books) {
    final watch = Stopwatch()..start();
    Object? error;
    try {
      fingerprint = Object.hash(fingerprint, operation(book.read()).runtimeType);
    } on Object catch (caught) {
      error = caught;
      failures++;
    }

    watch.stop();
    table.record(book, watch.elapsed, error);
  }
  total.stop();
  table.finish(books: books, totalBytes: totalBytes, elapsed: total.elapsed, failures: failures);

  return fingerprint;
}

/// Adds the parse / metadata benchmarks for one oversized real book.
///
/// [withOpenFromBytes] additionally probes the isolate-based reader;
/// the probe doubles the peak memory (isolate spawn + full byte copy
/// on top of the input), so a failed probe omits that benchmark with a
/// printed note instead of failing the suite.
Future<void> _addGiantBookBenchmarks(
  final BenchmarkGroup group,
  final LibraryBook? book,
  final String displayName, {
  final bool withOpenFromBytes = false,
}) async {
  if (book == null) {
    stdout.writeln(
      '[Real library corpus] "$displayName" not found in the library — '
      'giant-book benchmarks omitted.',
    );

    return;
  }

  final label = '$displayName (${formatBytes(book.size)})';
  final bytes = book.read();

  group.add(
    'BookReader.parseBook — $label',
    () => BookReader.parseBook(bytes),
    inputBytes: bytes.length,
  );
  group.add('BookReader.readMetadataSync — $label', () => BookReader.readMetadataSync(bytes));
  if (withOpenFromBytes) {
    await _addOpenFromBytesBenchmark(group, bytes, label);
  }
}

Future<void> _addOpenFromBytesBenchmark(
  final BenchmarkGroup group,
  final Uint8List bytes,
  final String label,
) async {
  final name = 'BookReader.openFromBytes — $label';
  if (!matchesFilter('${group.title} — $name')) return;

  try {
    // Trial run first: on constrained machines the doubled peak memory
    // can fail; omit the benchmark rather than break the suite.
    await BookReader.openFromBytes(bytes).timeout(const Duration(minutes: 5));
  } on Object catch (error) {
    stdout.writeln('[Real library corpus] $name probe failed — omitted ($error).');

    return;
  }

  await group.addAsync(
    name,
    () => BookReader.openFromBytes(bytes),
    inputBytes: bytes.length,
    note: 'isolate spawn + byte copy included',
  );
}

/// Prints the per-book duration breakdown of the very first library
/// pass, once, so the console keeps the whole-corpus table.
final class _FirstPassTable {
  _FirstPassTable(this.operation);

  /// The operation the table times, e.g. `parseBook`.
  final String operation;

  bool _printed = false;

  void begin() {
    if (_printed) return;

    _printed = true;
    stdout
      ..writeln()
      ..writeln('Real library corpus — $operation, first pass (cold):')
      ..writeln("${'size'.padLeft(10)}${'ms'.padLeft(10)}  book");
  }

  void record(final LibraryBook book, final Duration elapsed, final Object? error) {
    if (!_printed) return;

    final duration = error == null
        ? (elapsed.inMicroseconds / 1000).toStringAsFixed(1).padLeft(10)
        : 'FAILED'.padLeft(10);
    stdout.writeln('${formatBytes(book.size).padLeft(10)}$duration  ${book.name}');
  }

  void finish({
    required final List<LibraryBook> books,
    required final int totalBytes,
    required final Duration elapsed,
    required final int failures,
  }) {
    if (!_printed) return;

    final milliseconds = (elapsed.inMicroseconds / 1000).toStringAsFixed(1).padLeft(10);
    stdout.writeln(
      '${formatBytes(totalBytes).padLeft(10)}$milliseconds  '
      'total — ${books.length} books, $failures failures',
    );
  }
}
