/// Runs the C03 acceptance lanes and assembles the oracle-gate comparison
/// report: one verdict per TT01-TT08, each resting on commands that ran
/// during this invocation and on the artifacts they wrote under build/.
///
/// Lanes:
/// 1. `tool/tiff_tiles_compare.dart` against the libtiff reference stage
///    (pixels, expected rejections, comparator self-checks) — TT02, TT04.
/// 2. `dart test` per acceptance group of
///    `test/tests/tiff/tiff_tiles_test.dart` — TT01, TT03-TT08.
/// 3. `dart test` of the bounded mutation campaign — TT05.
/// 4. `dart test` of the pre-existing strip suite — TT07.
/// 5. a freshly compiled `unseal_worker.js` under Chrome — TT07.
/// 6. `benchmark/tiff_tiles_benchmarks.dart` — TT08.
/// 7. corpus integrity: tiled manifest hashes and the fuzz corpus
///    manifest — TT08.
///
/// Usage: `dart run tool/tiff_tiles_evidence.dart --out=build/evidence/C03`
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

void main(final List<String> arguments) {
  var outDir = 'build/evidence/C03';
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

  // Lane 1: pixels against libtiff.
  final referencePath = '$outDir/reference.json';
  final compareDir = '$outDir/compare';
  final compareRun = run('compare', [
    dart,
    'run',
    'tool/tiff_tiles_compare.dart',
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
    final id = 'TT0$index';
    groupRuns[id] = run('tests-$id', [
      dart,
      'test',
      'test/tests/tiff/tiff_tiles_test.dart',
      '--plain-name',
      id,
      '-r',
      'expanded',
    ]);
  }
  final fuzzRun = run('tests-fuzz', [
    dart,
    'test',
    'test/tests/tiff/tiff_tiles_fuzz_test.dart',
    '-r',
    'expanded',
  ]);
  final stripRun = run('tests-strips', [
    dart,
    'test',
    'test/tests/tiff/tiff_test.dart',
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
        'test/web/tiff_tiles_browser_test.dart',
        'test/web/tiff_wire_test.dart',
        '-r',
        'expanded',
      ]);
      chromeArtifacts.add(chromeRun.log);
      chromeOk =
          chromeRun.exitCode == 0 &&
          chromeRun.output.contains('the real worker decodes tiled pages');
      chromeNote = chromeOk
          ? 'the freshly compiled unseal_worker.js decodes the embedded tiled fixtures to the VM goldens through WorkerClient.parseInWorker, and the wire keeps pages and metadata'
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
    'benchmark/tiff_tiles_benchmarks.dart',
    '--out=$benchPath',
    '--reps=5',
  ]);
  Map<String, Object?>? bench;
  try {
    bench = (json.decode(File(benchPath).readAsStringSync()) as Map).cast<String, Object?>();
  } on Object {
    bench = null;
  }
  final benchOk = benchRun.exitCode == 0 && bench != null && (bench['pairs'] as List).length >= 5;

  // Lane 7: corpus integrity.
  final corpusCheck = run('corpus-check', [dart, 'run', 'tool/tiff_tiles_fixtures.dart', 'check']);
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
  final compareArtifacts = [compareRun.log, '$compareDir/report.json', '$compareDir/cases.log'];

  verdict(
    'TT01',
    groupOk('TT01') && compareOk,
    'Unseal.parse, Unseal.read, parseTiffBook, readTiffMetadata and detectFormat open classic and BigTIFF tiled files; strip pages keep their goldens next to tiled ones',
    [groupRuns['TT01']!.log, ...compareArtifacts],
  );
  verdict(
    'TT02',
    compareOk,
    'libtiff 4.7.2 native samples and RGBA compared on ${totals['cases']} cases '
        '(${totals['pass']} pass, ${totals['expectedRejection']} expected rejections, '
        '${totals['expectedDifference']} expected differences, ${totals['diverged']} diverged): '
        '${totals['pagesCompared']} pages, ${totals['pixelsCompared']} native pixels and '
        '${totals['rgbaPixelsCompared']} RGBA pixels with zero differences; comparator self-checks behaved',
    compareArtifacts,
  );
  verdict(
    'TT03',
    groupOk('TT03') && compareOk,
    'edge tiles, images smaller than one tile, 1x1 and single-tile images, rectangular and non-multiple-of-16 tiles, LONG8 BigTIFF addresses in both byte orders, SGI strip-tag addressing, and multi-IFD strip/tile mixes verified',
    [groupRuns['TT03']!.log, ...compareArtifacts],
  );
  const matrixIds = [
    'tiled/gray8-none-t16-le.tif',
    'tiled/gray8-packbits-t16-be.tif',
    'tiled/gray8-lzw2-t32-be.tif',
    'tiled/gray8-zip2-t16-big.tif',
    'tiled/rgb8-zip2-t32-big-be.tif',
    'tiled/gray16-zip2-t16-big-be.tif',
    'tiled/gray16-lzw2-t16-le.tif',
    'tiled/bilevel-g4-t16-edge-be.tif',
    'tiled/bilevel-g3-t32x16-be.tif',
    'tiled/bilevel-g3-2d-fill-t32x16.tif',
    'tiled/bilevel-mh-t32x16.tif',
    'tiled/gray8-o2-t16.tif',
    'tiled/gray8-o3-t16.tif',
    'tiled/gray8-o4-t16-be.tif',
    'tiled/cramps-tile.tif',
    'tiled/quad-tile.tif',
    'tiled/fax2d-g4-t64.tif',
    'tiled/ladoga-zip2-t16.tif',
  ];
  const rejectionIds = [
    'tiled/gray8-o5-t16.tif',
    'tiled/gray8-o6-t16.tif',
    'tiled/gray8-o7-t16.tif',
    'tiled/gray8-o8-t16.tif',
    'tiled/bilevel-none-fill2-t32.tif',
    'tiled/zackthecat.tif',
    'strips/quad-tile.jpg.tiff',
  ];
  final matrixOk =
      matrixIds.every((final id) => verdictOf(id) == 'pass') &&
      rejectionIds.every((final id) => verdictOf(id) == 'expected-rejection') &&
      verdictOf('tiled/rgb16-zip2-t16.tif') == 'expected-difference';
  verdict(
    'TT04',
    groupOk('TT04') && compareOk && matrixOk,
    'none/PackBits/LZW/Deflate with and without Predictor 2 over gray8/RGB8/gray16/bilevel, CCITT MH/G3/G4 tiles, orientations 2-4 flipped and 5-8 refused, FillOrder 2 refused, gray16 high byte with 16-bit predictor carries, bilevel photometric semantics all matched libtiff; RGB16 recorded as the declared RGBA-lane difference',
    [groupRuns['TT04']!.log, ...compareArtifacts],
  );
  verdict(
    'TT05',
    groupOk('TT05') && fuzzRun.exitCode == 0 && fuzzRun.output.contains('All tests passed'),
    'missing/mismatched/zero/truncated/out-of-file addresses, overlapping segments (each other, header, directory), oversized and overflowing geometry, footprint bombs, short segments and over-long Deflate streams fail typed before allocation; ${_mutantCount(fuzzRun.output)} tiled mutants decoded or failed typed',
    [groupRuns['TT05']!.log, fuzzRun.log],
  );
  verdict(
    'TT06',
    groupOk('TT06'),
    'pixels, resident bytes, scratch and decode work are independent guards; oversized temporary tiles are charged as work (8 pages of 64 MiB tiles pass, the ninth fails typed); materialized pages accumulate against the resident cap (9 pages of 2048x2048 pass, the tenth fails typed)',
    [groupRuns['TT06']!.log],
  );
  verdict(
    'TT07',
    groupOk('TT07') &&
        stripRun.exitCode == 0 &&
        stripRun.output.contains('All tests passed') &&
        chromeOk &&
        compareOk,
    'VM goldens equal the embedded browser bytes; strip corpus and typed failures of the previous subset unchanged (${_testCount(stripRun.output)} strip tests); Chrome: $chromeNote',
    [groupRuns['TT07']!.log, stripRun.log, ...chromeArtifacts],
  );
  final benchSummary = bench == null
      ? 'benchmark failed'
      : (bench['pairs']! as List)
            .cast<Map<Object?, Object?>>()
            .map((final pair) {
              final ratio = (pair['tiledOverStrips']! as Map)['decodeMedianRatio'];
              final strips = pair['strips']! as Map;
              final tiles = pair['tiles']! as Map;
              return '${pair['label']}: decode x$ratio, peak RSS strips ${_mib(strips['peakRssBytes']! as int)} / tiles ${_mib(tiles['peakRssBytes']! as int)}';
            })
            .join('; ');
  verdict(
    'TT08',
    groupOk('TT08') &&
        benchOk &&
        corpusCheck.exitCode == 0 &&
        inventoryRun.exitCode == 0 &&
        compareOk,
    'complete matrix (compare report over ${totals['cases']} cases), tiled manifest and fuzz corpus manifest verified, strip-vs-tiled benchmark per process with open/decode medians and peak RSS: $benchSummary',
    [
      groupRuns['TT08']!.log,
      benchPath,
      benchRun.log,
      corpusCheck.log,
      inventoryRun.log,
      inventoryPath,
    ],
  );

  final report = <String, Object?>{
    'schemaVersion': 1,
    'mission': 'C03',
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

String _mutantCount(final String output) {
  final match = RegExp(r'(\d+) tiled mutants').firstMatch(output);
  return match?.group(1) ?? '0';
}

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
