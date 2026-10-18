/// Contiguous versus planar versus palette TIFF decoding, measured in
/// separate processes.
///
/// For every source image the benchmark derives layout pairs with libtiff
/// 4.7.2's `tiffcp` (identical pixels, identical codec, one contiguous
/// and one `PlanarConfiguration 2`, plus a palette twin of a gray source)
/// and runs each variant in a fresh Dart process that reports the median
/// open (`readTiffMetadata`) and decode (`parseTiffBook`) times and its
/// own `ProcessInfo.maxRss`. A baseline process that only loads the bytes
/// gives the RSS floor.
///
/// Usage:
///
///     dart run benchmark/tiff_planar_palette_benchmarks.dart \
///       [--out=build/evidence/D03/bench.json] [--reps=5]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/tiff.dart';

const _tiffcp = '/opt/homebrew/bin/tiffcp';

/// (label, tracked source, codec options) for the contiguous/planar
/// pairs. Palette pages take no planar variant (the layout is refused by
/// contract), so the palette source is measured against its gray twin
/// separately.
const _sources = <(String, String, List<String>)>[
  ('quad rgb8 512x384 lzw', 'test/resources/tiff/tiled/quad-tile.tif', ['-c', 'lzw']),
  ('rgb8 128x96 lzw:2', 'test/resources/tiff/rgb-lzw-predictor.tif', ['-c', 'lzw:2']),
  ('rgb8 128x96 packbits', 'test/resources/tiff/rgb-packbits.tif', ['-c', 'packbits']),
];

Future<void> main(final List<String> arguments) async {
  if (arguments.isNotEmpty && arguments.first == '--child') {
    _child(arguments);
    return;
  }
  var out = 'build/evidence/D03/bench.json';
  var reps = 5;
  for (final argument in arguments) {
    if (argument.startsWith('--out=')) out = argument.substring(6);
    if (argument.startsWith('--reps=')) reps = int.parse(argument.substring(7));
  }
  final workDir = Directory('${File(out).absolute.parent.path}/bench-files')
    ..createSync(recursive: true);
  final script = Platform.script.toFilePath();
  // Children run as an AOT snapshot: `dart run` would carry the kernel
  // front end in every child and bury the decoder's RSS under a floor of
  // several hundred MiB.
  final runtime = await _childRuntime(script, workDir.path);
  stdout.writeln('child runtime: ${runtime.join(' ')}');

  final pairs = <Map<String, Object?>>[];
  for (final (label, source, codec) in _sources) {
    final stem = label.split(' ').first.toLowerCase();
    final contig = '${workDir.path}/$stem-contig.tif';
    final planar = '${workDir.path}/$stem-planar.tif';
    final contigArgs = [...codec, source, contig];
    final planarArgs = ['-p', 'separate', ...codec, source, planar];
    for (final argv in [contigArgs, planarArgs]) {
      final result = Process.runSync(_tiffcp, argv);
      if (result.exitCode != 0) {
        stderr.writeln('tiffcp failed: ${argv.join(' ')}\n${result.stderr}');
        exitCode = 1;
        return;
      }
    }
    final baseline = await _measure(runtime, contig, reps, mode: 'baseline');
    final contigRun = await _measure(runtime, contig, reps, mode: 'decode');
    final planarRun = await _measure(runtime, planar, reps, mode: 'decode');
    pairs.add({
      'label': label,
      'source': source,
      'codec': codec.join(' '),
      'tiffcp': {
        'contiguous': [_tiffcp, ...contigArgs],
        'planar': [_tiffcp, ...planarArgs],
      },
      'baselinePeakRssBytes': baseline['peakRssBytes'],
      'contiguous': contigRun,
      'planar': planarRun,
      'planarOverContiguous': {
        'decodeMedianRatio': _ratio(
          planarRun['decodeMedianMicros'],
          contigRun['decodeMedianMicros'],
        ),
        'openMedianRatio': _ratio(planarRun['openMedianMicros'], contigRun['openMedianMicros']),
        'peakRssDeltaRatio': _ratio(
          (planarRun['peakRssBytes']! as int) - (baseline['peakRssBytes']! as int),
          (contigRun['peakRssBytes']! as int) - (baseline['peakRssBytes']! as int),
        ),
      },
    });
    stdout.writeln(
      '$label: contig decode ${contigRun['decodeMedianMicros']} us / '
      'planar ${planarRun['decodeMedianMicros']} us; peak RSS contig '
      '${_mib(contigRun['peakRssBytes']! as int)} / planar ${_mib(planarRun['peakRssBytes']! as int)} '
      '(baseline ${_mib(baseline['peakRssBytes']! as int)})',
    );
  }

  // Palette versus gray twin: same geometry and codec, one page
  // projected through a ColorMap, the other straight to gray.
  final paletteFile = '${workDir.path}/palette8-contig.tif';
  final grayFile = '${workDir.path}/gray8-contig.tif';
  for (final argv in [
    [_tiffcp, '-c', 'none', 'test/resources/tiff/palette-1c-8b.tiff', paletteFile],
    [_tiffcp, '-c', 'none', 'test/resources/tiff/minisblack-1c-8b.tiff', grayFile],
  ]) {
    final result = Process.runSync(argv.first, argv.sublist(1));
    if (result.exitCode != 0) {
      stderr.writeln('tiffcp failed: ${argv.join(' ')}\n${result.stderr}');
      exitCode = 1;
      return;
    }
  }
  final paletteRun = await _measure(runtime, paletteFile, reps, mode: 'decode');
  final grayRun = await _measure(runtime, grayFile, reps, mode: 'decode');
  pairs.add({
    'label': 'palette8 157x151 none vs gray8 twin',
    'palette': paletteRun,
    'gray': grayRun,
    'paletteOverGray': {
      'decodeMedianRatio': _ratio(paletteRun['decodeMedianMicros'], grayRun['decodeMedianMicros']),
      'peakRssDeltaRatio': _ratio(
        (paletteRun['peakRssBytes']! as int) - (grayRun['peakRssBytes']! as int),
        1,
      ),
    },
  });
  stdout.writeln(
    'palette8 vs gray8: palette decode ${paletteRun['decodeMedianMicros']} us / '
    'gray ${grayRun['decodeMedianMicros']} us; peak RSS palette '
    '${_mib(paletteRun['peakRssBytes']! as int)} / gray ${_mib(grayRun['peakRssBytes']! as int)}',
  );

  final report = {
    'schemaVersion': 1,
    'mission': 'D03',
    'unit':
        'per-process median of parseTiffBook (decode) and readTiffMetadata (open), '
        'peak RSS from ProcessInfo.maxRss, AOT child runtime',
    'pairs': pairs,
  };
  File(out).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln('benchmark written to $out');
}

Future<List<String>> _childRuntime(final String script, final String workDir) async {
  final sdkBin = File(Platform.resolvedExecutable).parent.path;
  final aotRuntime = '$sdkBin/dartaotruntime';
  final snapshot = '$workDir/tiff_planar_palette_benchmarks.aot';
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
  final String file,
  final int reps, {
  required final String mode,
}) async {
  final opens = <int>[];
  final decodes = <int>[];
  int peakRss = 0;
  for (var i = 0; i < reps; i++) {
    final result = await Process.run(runtime.first, [
      ...runtime.sublist(1),
      '--child',
      mode,
      file,
    ], stdoutEncoding: utf8);
    if (result.exitCode != 0) {
      stderr.writeln(result.stderr);
      throw StateError('child process failed for $file ($mode)');
    }
    final report = json.decode(result.stdout as String) as Map<String, Object?>;
    opens.add(report['openMicros']! as int);
    decodes.add(report['decodeMicros']! as int);
    peakRss = peakRss < (report['peakRssBytes']! as int) ? report['peakRssBytes']! as int : peakRss;
  }
  int median(final List<int> values) {
    final sorted = [...values]..sort();
    return sorted[sorted.length ~/ 2];
  }

  return {
    'openMedianMicros': median(opens),
    'decodeMedianMicros': median(decodes),
    'peakRssBytes': peakRss,
    'reps': reps,
  };
}

int _ratio(final Object? numerator, final Object? denominator) =>
    ((numerator! as int) * 100 / (denominator! as int)).round();

String _mib(final int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';

void _child(final List<String> arguments) {
  final mode = arguments[1];
  final bytes = Uint8List.fromList(File(arguments[2]).readAsBytesSync());
  final watch = Stopwatch()..start();
  if (mode == 'baseline') {
    // Load the bytes and touch nothing else.
    final checksum = bytes.length;
    watch.stop();
    stdout.writeln(
      json.encode({
        'openMicros': watch.elapsedMicroseconds,
        'decodeMicros': 0,
        'peakRssBytes': ProcessInfo.maxRss,
        'checksum': checksum,
      }),
    );
    return;
  }
  final openWatch = Stopwatch()..start();
  readTiffMetadata(bytes);
  openWatch.stop();
  final decodeWatch = Stopwatch()..start();
  final book = parseTiffBook(bytes);
  decodeWatch.stop();
  stdout.writeln(
    json.encode({
      'openMicros': openWatch.elapsedMicroseconds,
      'decodeMicros': decodeWatch.elapsedMicroseconds,
      'peakRssBytes': ProcessInfo.maxRss,
      'pages': book.pageCount,
    }),
  );
}
