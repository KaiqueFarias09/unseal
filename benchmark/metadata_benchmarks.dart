// Benchmarks for the public metadata-only reads: the synchronous
// fast path [Unseal.readMetadataSync] and the isolate-based
// [Unseal.readMetadata] / [Unseal.readMetadataFile]
// (the latter includes the sidecar metadata merge).

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'package:unseal/unseal.dart';

import 'benchmark_harness.dart';
import 'fixtures.dart';

/// Runs the metadata-read benchmarks.
Future<void> runMetadataBenchmarks() async {
  final group = BenchmarkGroup('Metadata-only read');
  for (final fixture in parsingFixtures) {
    group.add(
      'Unseal.readMetadataSync — ${fixture.label}',
      () => Unseal.readMetadataSync(fixture.bytes),
      fixtureId: fixture.fixtureId,
    );
  }
  for (final fixture in asyncParsingFixtures) {
    await group.addAsync(
      'Unseal.readMetadata — ${fixture.label}',
      () => Unseal.readMetadata(fixture.bytes),
      fixtureId: fixture.fixtureId,
      note: 'async-only format · isolate spawn + byte copy included',
    );
  }

  await group.addAsync(
    'Unseal.readMetadata — ${epubSmall.label}',
    () => Unseal.readMetadata(epubSmall.bytes),
    note: 'isolate spawn + byte copy included',
  );
  await group.addAsync(
    'Unseal.readMetadata — ${mobi8Alice.label}',
    () => Unseal.readMetadata(mobi8Alice.bytes),
    note: 'isolate spawn + byte copy included',
  );
  await group.addAsync(
    'Unseal.readMetadataFile — ${epubWithSidecar.label}',
    () => Unseal.readMetadataFile(epubWithSidecar.path),
    note: 'disk read + isolate + OPF sidecar merge',
  );
}
