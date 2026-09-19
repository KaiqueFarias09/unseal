// Benchmarks for the public full-parse entry points: the synchronous
// dispatcher [Unseal.parse], the module-level [EpubBook.fromBytes]
// and the isolate-based [Unseal.read] / [Unseal.readFile].
//
// The sync loop covers every synchronously-parseable format; the 7-Zip
// formats (CB7, CBC) are async-only at the public API and are measured
// through their own [Unseal.read] rows. A coverage check
// (untimed, once per run) fails the suite when a [BookFormat] loses
// its fixture.

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'package:unseal/unseal.dart';

import 'benchmark_harness.dart';
import 'fixtures.dart';

/// Runs the full parse benchmarks.
Future<void> runParsingBenchmarks() async {
  await _verifyParseFormatCoverage();
  final group = BenchmarkGroup('Full parse');
  for (final fixture in parsingFixtures) {
    group.add(
      'Unseal.parse — ${fixture.label}',
      () => Unseal.parse(fixture.bytes),
      inputBytes: fixture.bytes.length,
      fixtureId: fixture.fixtureId,
    );
  }
  for (final fixture in asyncParsingFixtures) {
    await group.addAsync(
      'Unseal.read — ${fixture.label}',
      () => Unseal.read(fixture.bytes),
      inputBytes: fixture.bytes.length,
      fixtureId: fixture.fixtureId,
      note: 'async-only format · isolate spawn + byte copy included',
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
    'Unseal.read — ${epubSmall.label}',
    () => Unseal.read(epubSmall.bytes),
    inputBytes: epubSmall.bytes.length,
    note: 'isolate spawn + byte copy included',
  );
  await group.addAsync(
    'Unseal.read — ${mobi6Alice.label}',
    () => Unseal.read(mobi6Alice.bytes),
    inputBytes: mobi6Alice.bytes.length,
    note: 'isolate spawn + byte copy included',
  );
  await group.addAsync(
    'Unseal.readFile — ${epubAlice.label}',
    () => Unseal.readFile(epubAlice.path),
    note: 'disk read + isolate',
  );
}

/// Parses every matrix fixture once, untimed — CB7/CBC through the
/// async reader — and fails the run when a [BookFormat] loses its
/// fixture, so benchmark coverage can never silently shrink.
Future<void> _verifyParseFormatCoverage() async {
  final formats = <BookFormat>{
    for (final fixture in parsingFixtures) Unseal.parse(fixture.bytes).format,
  };
  for (final fixture in asyncParsingFixtures) {
    formats.add((await Unseal.read(fixture.bytes)).format);
  }
  if (formats.length != BookFormat.values.length) {
    final missing = BookFormat.values.toSet().difference(formats);
    throw StateError(
      'Benchmark fixture matrix no longer covers every BookFormat — '
      'missing: $missing. Restore a fixture per format in fixtures.dart.',
    );
  }
}
