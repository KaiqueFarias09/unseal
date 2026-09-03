// Benchmarks for the public full-parse entry points: the synchronous
// dispatcher [BookReader.parseBook], the module-level [EpubBook.fromBytes]
// and the isolate-based [BookReader.openFromBytes] / [BookReader.openFromPath].

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'package:e_livre/e_livre.dart';

import 'benchmark_harness.dart';
import 'fixtures.dart';

/// Runs the full parse benchmarks.
Future<void> runParsingBenchmarks() async {
  final group = BenchmarkGroup('Full parse');
  for (final fixture in parsingFixtures) {
    group.add(
      'BookReader.parseBook — ${fixture.label}',
      () => BookReader.parseBook(fixture.bytes),
      inputBytes: fixture.bytes.length,
    );
  }

  await group.addAsync(
    'EpubBook.fromBytes — ${epubSmall.label}',
    () => EpubBook.fromBytes(epubSmall.bytes),
    note: 'module API, no isolate',
  );
  await group.addAsync(
    'EpubBook.fromBytes — ${epubAlice.label}',
    () => EpubBook.fromBytes(epubAlice.bytes),
    inputBytes: epubAlice.bytes.length,
    note: 'module API, no isolate',
  );

  await group.addAsync(
    'BookReader.openFromBytes — ${epubSmall.label}',
    () => BookReader.openFromBytes(epubSmall.bytes),
    inputBytes: epubSmall.bytes.length,
    note: 'isolate spawn + byte copy included',
  );
  await group.addAsync(
    'BookReader.openFromBytes — ${mobi6Alice.label}',
    () => BookReader.openFromBytes(mobi6Alice.bytes),
    inputBytes: mobi6Alice.bytes.length,
    note: 'isolate spawn + byte copy included',
  );
  await group.addAsync(
    'BookReader.openFromPath — ${epubAlice.label}',
    () => BookReader.openFromPath(epubAlice.path),
    note: 'disk read + isolate',
  );
}
