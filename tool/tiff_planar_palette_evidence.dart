/// Runs the D03 acceptance lanes and assembles the oracle-gate comparison
/// report: one verdict per TC01-TC08, each resting on commands that ran
/// during this invocation and on the artifacts they wrote under build/.
///
/// Lanes:
/// 1. `tool/tiff_planar_palette_compare.dart` against the libtiff
///    reference stage (pixels, native samples, indices, colormaps,
///    expected rejections, comparator self-checks) — TC02, TC04, TC05.
/// 2. `dart test` per acceptance group of
///    `test/tests/tiff/tiff_planar_palette_test.dart` — TC01-TC08.
/// 3. `dart test` of the C03 strip and tiled suites — TC07.
/// 4. `dart test` of the tiled mutation campaign — TC05, TC08.
/// 5. a freshly compiled `unseal_worker.js` under Chrome — TC07.
/// 6. `benchmark/tiff_planar_palette_benchmarks.dart` — TC08.
/// 7. corpus integrity: planar/palette and tiled manifests plus the fuzz
///    corpus manifest — TC08.
///
/// Usage: `dart run tool/tiff_planar_palette_evidence.dart --out=build/evidence/D03`
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

void main(final List<String> arguments) {
  var outDir = 'build/evidence/D03';
  var runChrome = true;
  for (final argument in arguments) {
    if (argument.startsWith('--out=')) outDir = argument.substring(6);
    if (argument == '--skip-chrome') runChrome = false;
  }
  final logs = Directory('$outDir/lanes')..createSync(recursive: true);
  final dart = Platform.resolvedExecutable;
  final runs = <_CommandRun>[];
  final cases = <Map<String, Object?>>[];

  _CommandRun run(final String lane, final List<String> argv) {
    stdout.writeln('+ [$lane] ${argv.join(' ')}');
    final watch = Stopwatch()..start();
    final result = Process.runSync(argv.first, argv.sublist(1));
    final output = '${result.stdout}\n${result.stderr}';
    final log = File('${logs.path}/$lane.log')..writeAsStringSync(output);
    final record = _CommandRun(
      lane,
      argv,
      result.exitCode,
      log.path,
      watch.elapsedMilliseconds,
      output,
    );
    runs.add(record);
    if (result.exitCode != 0) stdout.writeln(_tail(output));
    return record;
  }

  void verdict(
    final String id,
    final bool ok,
    final String evidence,
    final List<String> artifacts,
  ) {
    cases.add({
      'id': id,
      'verdict': ok ? 'pass' : 'diverged',
      'evidence': evidence,
      'evidenceArtifacts': artifacts,
    });
    stdout.writeln('${ok ? "ok  " : "FAIL"} $id: $evidence');
  }

  // Lane 1: pixels, samples, indices, and colormaps against libtiff.
  final referencePath = '$outDir/reference.json';
  final compareDir = '$outDir/compare';
  final compareRun = run('compare', [
    dart,
    'run',
    'tool/tiff_planar_palette_compare.dart',
    '--reference=$referencePath',
    '--out=$compareDir',
  ]);
  Map<String, Object?>? compareReport;
  try {
    compareReport = (json.decode(File('$compareDir/report.json').readAsStringSync()) as Map)
        .cast<String, Object?>();
  } on Object {
    compareReport = null;
  }
  final totals =
      (compareReport?['totals'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
  final compareCases = ((compareReport?['cases'] as List?) ?? const <Object?>[])
      .cast<Map<Object?, Object?>>();
  String? verdictOf(final String id) {
    for (final record in compareCases) {
      if (record['id'] == id) return record['verdict'] as String?;
    }
    return null;
  }

  final compareOk =
      compareRun.exitCode == 0 &&
      compareReport != null &&
      totals['diverged'] == 0 &&
      (totals['pass'] as int? ?? 0) > 0 &&
      compareReport['selfChecksBehaved'] == true &&
      compareReport['head'] == _head();

  // Lane 2: acceptance groups.
  final groupRuns = <String, _CommandRun>{};
  for (var index = 1; index <= 8; index++) {
    final id = 'TC0$index';
    groupRuns[id] = run('tests-$id', [
      dart,
      'test',
      'test/tests/tiff/tiff_planar_palette_test.dart',
      '--plain-name',
      id,
      '-r',
      'expanded',
    ]);
  }

  // Lane 3: the C03 strip and tiled suites must stay green.
  final stripRun = run('tests-strips', [
    dart,
    'test',
    'test/tests/tiff/tiff_test.dart',
    '-r',
    'expanded',
  ]);
  final tilesRun = run('tests-tiles', [
    dart,
    'test',
    'test/tests/tiff/tiff_tiles_test.dart',
    '-r',
    'expanded',
  ]);
  final fuzzRun = run('tests-fuzz', [
    dart,
    'test',
    'test/tests/tiff/tiff_tiles_fuzz_test.dart',
    '-r',
    'expanded',
  ]);

  // Lane 5: a real browser worker, freshly compiled.
  var chromeOk = false;
  var chromeNote = 'Chrome lane disabled by flag';
  final chromeArtifacts = <String>[];
  if (runChrome) {
    final compileRun = run('worker-compile', [
      dart,
      'compile',
      'js',
      'web/unseal_worker.dart',
      '-o',
      'test/web/unseal_worker.js',
    ]);
    chromeArtifacts.add(compileRun.log);
    if (compileRun.exitCode == 0) {
      final chromeRun = run('chrome', [
        dart,
        'test',
        '-p',
        'chrome',
        'test/web/tiff_planar_palette_browser_test.dart',
        'test/web/tiff_tiles_browser_test.dart',
        'test/web/tiff_wire_test.dart',
        '-r',
        'expanded',
      ]);
      chromeArtifacts.add(chromeRun.log);
      chromeOk =
          chromeRun.exitCode == 0 &&
          chromeRun.output.contains('the real worker decodes planar and palette pages');
      chromeNote = chromeOk
          ? 'the freshly compiled unseal_worker.js decodes the embedded planar/palette '
                'fixtures to the VM goldens through WorkerClient.parseInWorker, next to the '
                'tiled C03 worker lane, and the wire keeps pages and metadata'
          : 'the Chrome run failed';
    } else {
      chromeNote = 'the current worker failed to compile';
    }
  }

  // Lane 6: benchmark.
  final benchPath = '$outDir/bench.json';
  final benchRun = run('bench', [
    dart,
    'run',
    'benchmark/tiff_planar_palette_benchmarks.dart',
    '--out=$benchPath',
    '--reps=5',
  ]);
  Map<String, Object?>? bench;
  try {
    bench = (json.decode(File(benchPath).readAsStringSync()) as Map).cast<String, Object?>();
  } on Object {
    bench = null;
  }
  final benchOk = benchRun.exitCode == 0 && bench != null && (bench['pairs'] as List).length >= 4;

  // Lane 7: corpus integrity.
  final corpusCheck = run('corpus-check', [
    dart,
    'run',
    'tool/tiff_planar_palette_fixtures.dart',
    'check',
  ]);
  final tiledCheck = run('tiled-check', [dart, 'run', 'tool/tiff_tiles_fixtures.dart', 'check']);
  final inventoryPath = '$outDir/inventory-report.json';
  final inventoryRun = run('inventory', [
    dart,
    'run',
    'tool/fuzz_corpus_inventory.dart',
    '--check-manifest',
    '--out-report=$inventoryPath',
  ]);

  // Verdicts.
  bool groupOk(final String id) =>
      groupRuns[id]!.exitCode == 0 && groupRuns[id]!.output.contains('All tests passed');
  bool suiteOk(final _CommandRun runRecord) =>
      runRecord.exitCode == 0 && runRecord.output.contains('All tests passed');
  final compareArtifacts = [compareRun.log, '$compareDir/report.json', '$compareDir/cases.log'];

  verdict(
    'TC01',
    groupOk('TC01') && compareOk,
    'Unseal.parse, Unseal.read, parseTiffBook, readTiffMetadata and detectFormat open planar '
        'and palette pages in classic and BigTIFF files; contiguous strip and tiled goldens are unchanged',
    [groupRuns['TC01']!.log, ...compareArtifacts],
  );
  verdict(
    'TC02',
    compareOk && groupOk('TC02'),
    'libtiff 4.7.2 compared on ${totals['cases']} cases (${totals['pass']} pass, '
        '${totals['expectedRejection']} expected rejections, ${totals['expectedDifference']} expected '
        'differences, ${totals['diverged']} diverged): ${totals['pagesCompared']} pages, '
        '${totals['pixelsCompared']} projected pixels, ${totals['nativeSamplesCompared']} native '
        'samples at full precision (16-bit low bytes included), ${totals['indicesCompared']} palette '
        'indices, ${totals['colormapEntriesCompared']} ColorMap entries and '
        '${totals['rgbaPixelsCompared']} RGBA pixels with zero differences; comparator self-checks behaved',
    [groupRuns['TC02']!.log, ...compareArtifacts],
  );
  const planarIds = [
    'planar-palette/planar8-none-strips.tif',
    'planar-palette/planar8-rows8.tif',
    'planar-palette/planar8-none-t16-le.tif',
    'planar-palette/planar8-packbits-t32-be.tif',
    'planar-palette/planar8-zip2-t16-big.tif',
    'planar-palette/planar8-lzw2-strips.tif',
    'planar-palette/planar8-o2-t16.tif',
    'planar-palette/quad-planar-zip2-t64-big-be.tif',
    'planar-palette/flower-rgb-planar-08.tif',
    'derived/gate-planar8-lzw-t64-be.tif',
    'derived/gate-planar8-packbits-strips.tif',
  ];
  // 16-bit planar keeps the single documented RGBA-lane rounding
  // difference; the native lane is still exact for all of them.
  const planar16Ids = [
    'planar-palette/planar16-none-strips.tif',
    'planar-palette/planar16-zip2-t16.tif',
    'planar-palette/planar16-lzw-t32-be.tif',
    'planar-palette/planar16-o3-strips-big-be.tif',
    'planar-palette/flower-rgb-planar-16.tif',
    'planar-palette/flower-planar16-zip2-t16.tif',
    'derived/gate-planar16-none-t32.tif',
  ];
  final planarOk =
      planarIds.every((final id) => verdictOf(id) == 'pass') &&
      planar16Ids.every((final id) => verdictOf(id) == 'expected-difference');
  verdict(
    'TC03',
    groupOk('TC03') && compareOk && planarOk,
    'Planar RGB 8/16-bit by strips and tiles, classic and BigTIFF, both byte orders, '
        'none/PackBits/LZW/Deflate with predictor 1 and 2 (one-sample stride) matched libtiff '
        'band by band; planar 16-bit recorded as the declared RGBA-lane rounding difference',
    [groupRuns['TC03']!.log, ...compareArtifacts],
  );
  const paletteIds = [
    'planar-palette/palette8-none-t16-le.tif',
    'planar-palette/palette8-packbits-strips-be.tif',
    'planar-palette/palette8-zip-t16-big.tif',
    'planar-palette/palette8-o4-t32.tif',
    'planar-palette/palette1-none-strips-be.tif',
    'planar-palette/palette4-enc-strips.tif',
    'planar-palette/palette2-enc-strips-be.tif',
    'planar-palette/palette8-enc-strips.tif',
    'planar-palette/palette8-legacy8bit.tif',
    'planar-palette/palette4-t16.tif',
    'planar-palette/palette2-packbits-strips.tif',
    'planar-palette/jello.tif',
    'planar-palette/flower-palette-02.tif',
    'planar-palette/flower-palette-04.tif',
    'planar-palette/flower-palette-08.tif',
    'planar-palette/palette-1c-8b.tiff',
    'derived/gate-palette8-none-strips.tif',
    'derived/gate-palette4-zip-t32-big.tif',
    'derived/gate-jello-lzw-strips-be.tif',
    'derived/gate-palette2-o2-strips.tif',
  ];
  final paletteOk =
      paletteIds.every((final id) => verdictOf(id) == 'pass') &&
      verdictOf('planar-palette/mixed-planar-palette-3page.tif') == 'pass' &&
      verdictOf('planar-palette/mixed-planar-big-be-2page.tif') == 'expected-difference';
  verdict(
    'TC04',
    groupOk('TC04') && compareOk && paletteOk,
    'Palettes of 1/2/4/8 bits with exact 16-bit ColorMaps, libtiff projection (byte-range '
        'tables direct, full-range v >> 8), orientations 2-4, edge tiles and padding, and '
        'multi-IFD mixes matched libtiff; the legacy byte-range ColorMap fixture is compared '
        'explicitly, not silently heurized',
    [groupRuns['TC04']!.log, ...compareArtifacts],
  );
  const rejectionIds = [
    'planar-palette/flower-palette-16.tif',
    'planar-palette/flower-rgb-planar-02.tif',
    'planar-palette/flower-rgb-planar-04.tif',
    'planar-palette/flower-separated-planar-08.tif',
    'planar-palette/flower-separated-planar-16.tif',
    'planar-palette/palette8-lzw2-reject.tif',
    'planar-palette/minisblack-2c-8b-alpha.tiff',
  ];
  final rejectionsOk = rejectionIds.every((final id) => verdictOf(id) == 'expected-rejection');
  verdict(
    'TC05',
    groupOk('TC05') &&
        rejectionsOk &&
        fuzzRun.exitCode == 0 &&
        fuzzRun.output.contains('All tests passed'),
    'Missing/truncated/oversize ColorMaps, band array mismatches, overlapping bands, '
        'out-of-file band ranges, 16-bit palettes, sub-byte planar RGB, separated photometric, '
        'palette+predictor 2, palette/planar CCITT, alpha in planes, and scratch bombs fail typed '
        'before allocation; the tiled mutation campaign stays clean',
    [groupRuns['TC05']!.log, fuzzRun.log, ...compareArtifacts],
  );
  verdict(
    'TC06',
    groupOk('TC06'),
    'Pixels, resident bytes (RGB buffer plus all live band buffers and palette tables), and '
        'decode work are independent guards: three 4096x4096 16-bit band tiles cost 96 MiB of '
        'work per page (six pages exceed the cap), three 16384x8192 band tiles need 384 MiB of '
        'scratch and are refused before inflation, and 2048x2048 planar pages fit eight to the '
        'resident cap where the contiguous gray twin fits nine',
    [groupRuns['TC06']!.log],
  );
  verdict(
    'TC07',
    groupOk('TC07') && suiteOk(stripRun) && suiteOk(tilesRun) && chromeOk && compareOk,
    'VM goldens equal the embedded browser bytes; the C03 strip corpus (${_testCount(stripRun.output)} tests) '
        'and tiled corpus (${_testCount(tilesRun.output)} tests) stay approved; Chrome: $chromeNote',
    [groupRuns['TC07']!.log, stripRun.log, tilesRun.log, ...chromeArtifacts],
  );
  final benchSummary = bench == null
      ? 'benchmark failed'
      : (bench['pairs']! as List)
            .cast<Map<Object?, Object?>>()
            .map((final pair) {
              if (pair.containsKey('planarOverContiguous')) {
                final ratio = (pair['planarOverContiguous']! as Map)['decodeMedianRatio'];
                final contig = pair['contiguous']! as Map;
                final planar = pair['planar']! as Map;
                return '${pair['label']}: planar/contig decode $ratio%, peak RSS '
                    '${_mib(contig['peakRssBytes']! as int)} / ${_mib(planar['peakRssBytes']! as int)}';
              }
              final ratio = (pair['paletteOverGray']! as Map)['decodeMedianRatio'];
              return '${pair['label']}: palette/gray decode $ratio%';
            })
            .join('; ');
  verdict(
    'TC08',
    groupOk('TC08') &&
        benchOk &&
        corpusCheck.exitCode == 0 &&
        tiledCheck.exitCode == 0 &&
        inventoryRun.exitCode == 0 &&
        compareOk,
    'complete matrix (compare report over ${totals['cases']} cases with behaving negatives), '
        'planar/palette and tiled manifests plus the fuzz corpus manifest verified, layout/channel '
        'benchmark per process with open/decode medians and peak RSS: $benchSummary',
    [
      groupRuns['TC08']!.log,
      benchPath,
      benchRun.log,
      corpusCheck.log,
      tiledCheck.log,
      inventoryRun.log,
      inventoryPath,
      ...compareArtifacts,
    ],
  );

  final report = <String, Object?>{
    'schemaVersion': 1,
    'mission': 'D03',
    'head': _head(),
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'referenceSha256': File(referencePath).existsSync()
        ? sha256.convert(File(referencePath).readAsBytesSync()).toString()
        : null,
    'compareTotals': totals,
    'cases': cases,
    'commandRuns': [
      for (final record in runs)
        {
          'lane': record.lane,
          'argv': record.argv,
          'exitCode': record.exitCode,
          'elapsedMillis': record.elapsedMillis,
          'log': record.log,
          'logSha256': sha256.convert(utf8.encode(record.output)).toString(),
          'outputTail': _tail(record.output),
        },
    ],
  };
  final reportFile = File('$outDir/comparison.json');
  reportFile.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln('comparison report written to ${reportFile.path}');
  exit(cases.any((final record) => record['verdict'] != 'pass') ? 1 : 0);
}

String _head() => Process.runSync('git', ['rev-parse', 'HEAD']).stdout.toString().trim();

String _testCount(final String output) {
  final match = RegExp(r'\+(\d+): All tests passed').firstMatch(output);
  return match?.group(1) ?? '0';
}

String _mib(final int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MiB';

String _tail(final String output) {
  final lines = output.trim().split('\n');
  return lines.length <= 12 ? output.trim() : '...\n${lines.sublist(lines.length - 12).join('\n')}';
}

final class _CommandRun {
  _CommandRun(this.lane, this.argv, this.exitCode, this.log, this.elapsedMillis, this.output);

  final String lane;
  final List<String> argv;
  final int exitCode;
  final String log;
  final int elapsedMillis;
  final String output;
}
