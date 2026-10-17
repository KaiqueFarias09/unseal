// Benchmarks for the JPEG 2000 codec: direct decodeJpxImage runs over
// the committed fixture family (the 64x64 lossless gray and RGB pair
// and the 256x256 lossy tile), the sizes PDF pages actually ship.

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_decoder.dart';

import 'benchmark_harness.dart';

const String _fixturesDir = 'test/resources/pdf/jpeg2000';

/// Runs the JPEG 2000 decoder benchmarks over the committed fixtures.
///
/// The codec is internal, so the group talks to `decodeJpxImage`
/// directly instead of going through a public entry point; skipping
/// the PDF layer keeps the numbers about the codec itself.
void runJpxBenchmarks() {
  final group = BenchmarkGroup('JPX');
  void addFixture(final String name, final String file) {
    final path = '$_fixturesDir/$file';
    final fixture = File(path);
    if (!fixture.existsSync()) {
      return;
    }
    final bytes = Uint8List.fromList(fixture.readAsBytesSync());
    decodeJpxImage(bytes); // Warm-up: JIT and code-page touch.
    group.add(
      'decodeJpxImage — $name',
      () => decodeJpxImage(bytes),
      inputBytes: bytes.length,
    );
  }

  addFixture('gray 64x64 5/3 lossless', 'gray53-lossless-lrcp.j2k');
  addFixture('rgb 64x64 5/3 RCT lossless', 'rgb53-lossless-rct.j2k');
  addFixture('gray 256x256 9/7 lossy', 'gray97-lossy-256.j2k');
}
