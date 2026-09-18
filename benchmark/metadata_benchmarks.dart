// Benchmarks for the public metadata-only reads: the synchronous
// fast path [BookReader.readMetadataSync] and the isolate-based
// [BookReader.readMetadataFromBytes] / [BookReader.readMetadataFromPath]
// (the latter includes the sidecar metadata merge).

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'package:e_livre/e_livre.dart';

import 'benchmark_harness.dart';
import 'fixtures.dart';

/// Runs the metadata-read benchmarks.
Future<void> runMetadataBenchmarks() async {
  final group = BenchmarkGroup('Metadata-only read');
  for (final fixture in parsingFixtures) {
    group.add(
      'BookReader.readMetadataSync — ${fixture.label}',
      () => BookReader.readMetadataSync(fixture.bytes),
    );
  }

  await group.addAsync(
    'BookReader.readMetadataFromBytes — ${epubSmall.label}',
    () => BookReader.readMetadataFromBytes(epubSmall.bytes),
    note: 'isolate spawn + byte copy included',
  );
  await group.addAsync(
    'BookReader.readMetadataFromBytes — ${mobi8Alice.label}',
    () => BookReader.readMetadataFromBytes(mobi8Alice.bytes),
    note: 'isolate spawn + byte copy included',
  );
  await group.addAsync(
    'BookReader.readMetadataFromPath — ${epubWithSidecar.label}',
    () => BookReader.readMetadataFromPath(epubWithSidecar.path),
    note: 'disk read + isolate + OPF sidecar merge',
  );
}
