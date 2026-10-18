/// Strip versus tiled TIFF decoding, measured in separate processes.
///
/// For every source image the benchmark derives two files with libtiff
/// 4.7.2's `tiffcp`, identical pixels and codec, one in strips and one in
/// tiles, then runs each variant in a fresh Dart process that reports the
/// median open (`readTiffMetadata`) and decode (`parseTiffBook`) times and
/// its own `ProcessInfo.maxRss`. A baseline process that only loads the
/// bytes gives the RSS floor. Nothing is shared between processes, so the
/// peak RSS of one variant never includes another's buffers.
///
/// Usage:
///
///     dart run benchmark/tiff_tiles_benchmarks.dart \
///       [--out=build/evidence/C03/bench.json] [--reps=5] [--tile=256]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/tiff.dart';

const _tiffcp = '/opt/homebrew/bin/tiffcp';

/// (label, tracked source, codec options for tiffcp).
const _sources = <(String, String, List<String>)>[
  ('cramps gray8 800x607', 'test/resources/tiff/tiled/cramps.tif', ['-c', 'none']),
  ('cramps gray8 800x607 lzw:2', 'test/resources/tiff/tiled/cramps.tif', ['-c', 'lzw:2']),
  ('quad rgb8 512x384 lzw', 'test/resources/tiff/tiled/quad-tile.tif', ['-c', 'lzw']),
  ('quad rgb8 512x384 zip:2', 'test/resources/tiff/tiled/quad-tile.tif', ['-c', 'zip:2']),
  ('testfax4 bilevel 2453x3369 g4', 'test/resources/tiff/testfax4.tiff', ['-c', 'g4']),
  ('testfax4 bilevel 2453x3369 packbits', 'test/resources/tiff/testfax4.tiff', ['-c', 'packbits']),
  ('ladoga gray16 158x118 zip:2', 'test/resources/tiff/tiled/ladoga.tif', ['-c', 'zip:2']),
];

Future<void> main(final List<String> arguments) async {
  if (arguments.isNotEmpty && arguments.first == '--child') {
    _child(arguments);
    return;
  }
  var out = 'build/evidence/C03/bench.json';
  var reps = 5;
  var tile = 256;
  for (final argument in arguments) {
    if (argument.startsWith('--out=')) out = argument.substring(6);
    if (argument.startsWith('--reps=')) reps = int.parse(argument.substring(7));
    if (argument.startsWith('--tile=')) tile = int.parse(argument.substring(7));
  }
  final workDir = Directory('${File(out).parent.path}/bench-files')..createSync(recursive: true);
  final script = Platform.script.toFilePath();
  // Children run as an AOT snapshot: `dart run` would carry the kernel
  // front end in every child and bury the decoder's RSS under a floor of
  // several hundred MiB.
  final runtime = await _childRuntime(script, workDir.path);
  stdout.writeln('child runtime: ${runtime.join(' ')}');

  final pairs = <Map<String, Object?>>[];
  for (final (label, source, codec) in _sources) {
    final stem = label.replaceAll(RegExp('[^a-z0-9]+'), '-');
    final strips = '${workDir.path}/$stem-strips.tif';
    final tiles = '${workDir.path}/$stem-tiles.tif';
    final stripArgs = ['-s', '-r', '64', ...codec, source, strips];
    final tileArgs = ['-t', '-w', '$tile', '-l', '$tile', ...codec, source, tiles];
    for (final argv in [stripArgs, tileArgs]) {
      final result = Process.runSync(_tiffcp, argv);
      if (result.exitCode != 0) {
        stderr.writeln('tiffcp failed: ${argv.join(' ')}\n${result.stderr}');
        exitCode = 1;
        return;
      }
    }
    final baseline = await _measure(runtime, strips, reps, mode: 'baseline');
    final stripRun = await _measure(runtime, strips, reps, mode: 'decode');
    final tileRun = await _measure(runtime, tiles, reps, mode: 'decode');
    pairs.add({
      'label': label,
      'source': source,
      'codec': codec.join(' '),
      'tiffcp': {
        'strips': [_tiffcp, ...stripArgs],
        'tiles': [_tiffcp, ...tileArgs],
      },
      'baselinePeakRssBytes': baseline['peakRssBytes'],
      'strips': stripRun,
      'tiles': tileRun,
      'tiledOverStrips': {
        'decodeMedianRatio': _ratio(tileRun['decodeMedianMicros'], stripRun['decodeMedianMicros']),
        'openMedianRatio': _ratio(tileRun['openMedianMicros'], stripRun['openMedianMicros']),
        'peakRssDeltaRatio': _ratio(
          (tileRun['peakRssBytes']! as int) - (baseline['peakRssBytes']! as int),
          (stripRun['peakRssBytes']! as int) - (baseline['peakRssBytes']! as int),
        ),
      },
    });
    stdout.writeln(
      '$label: strips decode ${stripRun['decodeMedianMicros']} us / '
      'tiles ${tileRun['decodeMedianMicros']} us; peak RSS strips '
      '${_mib(stripRun['peakRssBytes']! as int)} / tiles ${_mib(tileRun['peakRssBytes']! as int)} '
      '(baseline ${_mib(baseline['peakRssBytes']! as int)})',
    );
  }
  final head = Process.runSync('git', ['rev-parse', 'HEAD']).stdout.toString().trim();
  final report = <String, Object?>{
    'schemaVersion': 1,
    'benchmark': 'tiff-tiles strip-vs-tiled',
    'head': head,
    'dart': Platform.version,
    'childRuntime': runtime,
    'tileSize': tile,
    'reps': reps,
    'method': {
      'open': 'readTiffMetadata median over reps, microseconds',
      'decode': 'parseTiffBook median over reps, microseconds (every page to BMP)',
      'peakRss': 'ProcessInfo.maxRss of a dedicated child process after its work',
      'baseline': 'child process that only reads the strip file bytes',
    },
    'pairs': pairs,
  };
  File(out).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln('bench report written to $out');
}

/// Compiles this program to an AOT snapshot and returns the child argv
/// prefix; falls back to `dart run` when the AOT toolchain is missing.
Future<List<String>> _childRuntime(final String script, final String workDir) async {
  final sdkBin = File(Platform.resolvedExecutable).parent.path;
  final aotRuntime = '$sdkBin/dartaotruntime';
  final snapshot = '$workDir/tiff_tiles_benchmarks.aot';
  if (File(aotRuntime).existsSync()) {
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'aot-snapshot',
      script,
      '-o',
      snapshot,
    ]);
    if (compile.exitCode == 0 && File(snapshot).existsSync()) return [aotRuntime, snapshot];
    stderr.writeln('AOT compile failed, falling back to dart run: ${compile.stderr}');
  }
  return [Platform.resolvedExecutable, 'run', script];
}

Future<Map<String, Object?>> _measure(
  final List<String> runtime,
  final String path,
  final int reps, {
  required final String mode,
}) async {
  final result = await Process.run(runtime.first, [
    ...runtime.skip(1),
    '--child',
    mode,
    path,
    '$reps',
  ]);
  if (result.exitCode != 0) {
    throw StateError('child failed for $path: ${result.stderr}');
  }
  return (json.decode(result.stdout.toString().trim().split('\n').last) as Map)
      .cast<String, Object?>();
}

void _child(final List<String> arguments) {
  final mode = arguments[1];
  final path = arguments[2];
  final reps = int.parse(arguments[3]);
  final bytes = Uint8List.fromList(File(path).readAsBytesSync());
  final report = <String, Object?>{'mode': mode, 'path': path, 'fileBytes': bytes.length};
  if (mode == 'decode') {
    final opens = <int>[];
    final decodes = <int>[];
    var pages = 0;
    var bmpBytes = 0;
    for (var rep = 0; rep < reps; rep++) {
      final openWatch = Stopwatch()..start();
      readTiffMetadata(bytes);
      opens.add(openWatch.elapsedMicroseconds);
      final decodeWatch = Stopwatch()..start();
      final book = parseTiffBook(bytes);
      decodes.add(decodeWatch.elapsedMicroseconds);
      pages = book.pageCount;
      bmpBytes = book.pages.fold(0, (final sum, final page) => sum + page.image.content.length);
    }
    opens.sort();
    decodes.sort();
    report['pages'] = pages;
    report['bmpBytes'] = bmpBytes;
    report['openMedianMicros'] = opens[opens.length ~/ 2];
    report['decodeMedianMicros'] = decodes[decodes.length ~/ 2];
    report['decodeMinMicros'] = decodes.first;
    report['decodeMaxMicros'] = decodes.last;
  }
  report['peakRssBytes'] = ProcessInfo.maxRss;
  report['currentRssBytes'] = ProcessInfo.currentRss;
  stdout.writeln(json.encode(report));
  exit(0);
}

double _ratio(final Object? a, final Object? b) {
  final numerator = (a as num).toDouble();
  final denominator = (b as num).toDouble();
  if (denominator == 0) return numerator == 0 ? 1 : double.infinity;
  return double.parse((numerator / denominator).toStringAsFixed(3));
}

String _mib(final int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';
