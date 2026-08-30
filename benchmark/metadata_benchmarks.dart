// Benchmarks for the public metadata-only reads: the synchronous
// fast path [EBook.readMetadataSync] and the isolate-based
// [EBook.readMetadataFromBytes] / [EBook.readMetadataFromPath]
// (the latter includes the Calibre sidecar merge).

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
      'EBook.readMetadataSync — ${fixture.label}',
      () => EBook.readMetadataSync(fixture.bytes),
    );
  }

  await group.addAsync(
    'EBook.readMetadataFromBytes — ${epubSmall.label}',
    () => EBook.readMetadataFromBytes(epubSmall.bytes),
    note: 'isolate spawn + byte copy included',
  );
  await group.addAsync(
    'EBook.readMetadataFromBytes — ${mobi8Alice.label}',
    () => EBook.readMetadataFromBytes(mobi8Alice.bytes),
    note: 'isolate spawn + byte copy included',
  );
  await group.addAsync(
    'EBook.readMetadataFromPath — ${epubWithSidecar.label}',
    () => EBook.readMetadataFromPath(epubWithSidecar.path),
    note: 'disk read + isolate + OPF sidecar merge',
  );
}
