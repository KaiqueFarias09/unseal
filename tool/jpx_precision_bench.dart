// Isolated JPEG 2000 precision benchmark: wall-clock p50/mean/p95 per
// full decode plus the process peak RSS, one process per case so the
// memory measurements never share a heap (doc/jpeg2000-precision.md,
// evidence section).
//
//     dart run tool/jpx_precision_bench.dart --out=build/evidence/C04/bench.json
//     dart run tool/jpx_precision_bench.dart --case=2 --iterations=200
//
// The parent mode spawns one child per case with the pinned SDK dart
// executable; children print one JSON line on stdout.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_decoder.dart';

const String _precisionDir = 'test/resources/pdf/jpeg2000/precision';
const String _plainDir = 'test/resources/pdf/jpeg2000';

/// The benchmark matrix: every case names a committed fixture and its
/// expected projection cost. Case 0 is the 8-bit baseline the previous
/// subset shipped.
final List<({String label, String dir, String file, int iterations})> _cases =
    <({String label, String dir, String file, int iterations})>[
      (
        label: '8-bit gray 64x64 5/3 lossless (baseline)',
        dir: _plainDir,
        file: 'gray53-lossless-lrcp.j2k',
        iterations: 400,
      ),
      (
        label: '16-bit gray 64x48 5/3 lossless',
        dir: _precisionDir,
        file: 'synth-gray16-lossless.j2k',
        iterations: 400,
      ),
      (
        label: '16-bit gray 64x48 9/7 lossy',
        dir: _precisionDir,
        file: 'synth-gray16-lossy.j2k',
        iterations: 400,
      ),
      (
        label: '16-bit RGB 63x45 RCT lossless',
        dir: _precisionDir,
        file: 'synth-rgb16-rct-lossless-odd.j2k',
        iterations: 200,
      ),
      (
        label: '8-bit gray 63x48 dx=2 subsampled + upsample',
        dir: _precisionDir,
        file: 'synth-gray8-sub2x1-origin.j2k',
        iterations: 400,
      ),
      (
        label: '8-bit sYCC 4:2:0 63x45 odd-origin JP2 (native + rgb)',
        dir: _precisionDir,
        file: 'real-sycc8-420-lossless-odd-ffmpeg.jp2',
        iterations: 200,
      ),
      (
        label: '16-bit sYCC 4:2:0 64x48 JP2 (native + rgb)',
        dir: _precisionDir,
        file: 'synth-sycc16-420-lossless.jp2',
        iterations: 200,
      ),
      (
        label: '12-bit sYCC 4:2:0 63x45 origin+tiles JP2 (native + rgb)',
        dir: _precisionDir,
        file: 'synth-sycc12-420-lossless-origin-tiles.jp2',
        iterations: 200,
      ),
    ];

void main(final List<String> arguments) {
  final caseArgument = _option(arguments, '--case');
  final outArgument = _option(arguments, '--out');
  if (caseArgument != null) {
    _child(int.parse(caseArgument), _option(arguments, '--iterations'));
    return;
  }
  _parent(outArgument);
}

String? _option(final List<String> arguments, final String name) {
  for (final argument in arguments) {
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

/// Runs one case in this process and prints the measurement.
void _child(final int index, final String? iterationOverride) {
  final (:label, :dir, :file, :iterations) = _cases[index];
  final count = iterationOverride == null ? iterations : int.parse(iterationOverride);
  final bytes = Uint8List.fromList(File('$dir/$file').readAsBytesSync());
  final peakRss = ProcessInfo.maxRss;

  for (var i = 0; i < 8; i++) {
    decodeJpxImage(bytes); // Warm-up: JIT and code-page touch.
  }
  final samples = <double>[];
  var checksum = 0;
  for (var i = 0; i < count; i++) {
    final watch = Stopwatch()..start();
    final image = decodeJpxImage(bytes);
    final planes = image.outputPlanes; // Include the projection cost.
    checksum += planes.first[0] + planes.last[planes.first.length - 1];
    watch.stop();
    samples.add(watch.elapsedMicroseconds.toDouble());
  }
  samples.sort();
  final output = <String, Object?>{
    'case': index,
    'label': label,
    'fixture': file,
    'inputBytes': bytes.length,
    'iterations': count,
    'p50Micros': samples[samples.length ~/ 2],
    'meanMicros': samples.fold<double>(0, (final a, final b) => a + b) / samples.length,
    'p95Micros': samples[(samples.length * 95) ~/ 100],
    'maxRssBytes': ProcessInfo.maxRss,
    'baselineMaxRssBytes': peakRss,
    'checksum': checksum,
  };
  // A measurement tool: stdout is the deliverable.
  // ignore: avoid_print
  print(const JsonEncoder().convert(output));
}

/// Spawns one child per case, collects the measurements and writes the
/// parent report.
void _parent(final String? outPath) {
  final dartExecutable = Platform.resolvedExecutable;
  final results = <Map<String, Object?>>[];
  for (var index = 0; index < _cases.length; index++) {
    final result = Process.runSync(dartExecutable, <String>[
      'run',
      'tool/jpx_precision_bench.dart',
      '--case=$index',
    ], stdoutEncoding: const Utf8Codec(allowMalformed: true));
    if (result.exitCode != 0) {
      stderr.writeln('case $index failed (${result.exitCode}): ${result.stderr}');
      exitCode = 1;
      return;
    }
    final line = result.stdout
        .toString()
        .split('\n')
        .firstWhere((final line) => line.startsWith('{'));
    final measurement = jsonDecode(line) as Map<String, Object?>;
    results.add(measurement);
    // A measurement tool: stdout is the deliverable.
    // ignore: avoid_print
    print(
      '${measurement['label']}: p50 ${measurement['p50Micros']} us  '
      'mean ${(measurement['meanMicros'] as double).toStringAsFixed(0)} us  '
      'p95 ${measurement['p95Micros']} us  '
      'peak RSS ${(measurement['maxRssBytes'] as int) / (1024 * 1024)} MiB  '
      '(${measurement['inputBytes']} B in)',
    );
  }
  final report = <String, Object?>{
    'protocol':
        'One fresh dart process per case (memory isolation); wall clock '
        'around decodeJpxImage plus the output projection, 8 warm-up '
        'decodes, peak RSS from ProcessInfo on the pinned SDK.',
    'sdk': const bool.fromEnvironment('dart.vm.product') ? 'product' : 'dev',
    'cases': results,
  };
  final text = '${const JsonEncoder.withIndent('  ').convert(report)}\n';
  if (outPath == null) {
    // A measurement tool: stdout is the deliverable.
    // ignore: avoid_print
    print(text);
    return;
  }
  File(outPath)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
  stderr.writeln('wrote $outPath');
}
