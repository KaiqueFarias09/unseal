// Benchmarks for the public full-parse entry points: the synchronous
// dispatcher [EBook.parseBook], the module-level [EpubBook.fromBytes]
// and the isolate-based [EBook.openFromBytes] / [EBook.openFromPath].

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
      'EBook.parseBook — ${fixture.label}',
      () => EBook.parseBook(fixture.bytes),
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
    'EBook.openFromBytes — ${epubSmall.label}',
    () => EBook.openFromBytes(epubSmall.bytes),
    inputBytes: epubSmall.bytes.length,
    note: 'isolate spawn + byte copy included',
  );
  await group.addAsync(
    'EBook.openFromBytes — ${mobi6Alice.label}',
    () => EBook.openFromBytes(mobi6Alice.bytes),
    inputBytes: mobi6Alice.bytes.length,
    note: 'isolate spawn + byte copy included',
  );
  await group.addAsync(
    'EBook.openFromPath — ${epubAlice.label}',
    () => EBook.openFromPath(epubAlice.path),
    note: 'disk read + isolate',
  );
}
