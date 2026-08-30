// Benchmarks for the public format detection API:
// [detectFormat] and [refineMobiFormat].

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'package:e_livre/e_livre.dart';

import 'benchmark_harness.dart';
import 'fixtures.dart';

/// Runs the format detection benchmarks.
void runDetectionBenchmarks() {
  final group = BenchmarkGroup('Format detection');
  for (final fixture in parsingFixtures) {
    group.add(
      'detectFormat — ${fixture.label}',
      () => detectFormat(fixture.bytes),
    );
  }
  group.add(
    'refineMobiFormat — ${mobi6Alice.label}',
    () => refineMobiFormat(mobi6Alice.bytes),
  );
  group.add(
    'refineMobiFormat — ${mobi8Alice.label}',
    () => refineMobiFormat(mobi8Alice.bytes),
  );
}
