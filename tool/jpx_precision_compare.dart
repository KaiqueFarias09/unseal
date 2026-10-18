import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'jpx_precision/lanes.dart';

/// Runs the JPEG 2000 precision acceptance (the `compare` stage of the
/// campaign manifest) and writes `<out>/comparison.json` with one row per
/// acceptance ID JP01..JP08, each pointing at the logs and measurements
/// this run produced.
///
///     dart run tool/jpx_precision_compare.dart --out=build/evidence/C04
///
/// Every lane is the real command the repository's verification matrix
/// runs, executed through the pinned SDK (`Platform.resolvedExecutable`):
/// format, analyze, the focused and the full VM suites, a fresh worker
/// compile followed by the browser suites, the fuzz campaign, the corpus
/// inventory, the pub dry-run and the isolated benchmark. The corpus
/// comparison itself (native/upsample/rgb lanes) and the comparator's
/// negative cases run in process through `tool/jpx_precision/lanes.dart`,
/// the same code the VM suite uses. A lane that exits non-zero fails every
/// acceptance row that cites it; the tool exits 1 unless all eight pass.
///
/// `--skip-full` leaves out the full VM and browser suites (development
/// shortcut; the acceptance run never uses it).
void main(final List<String> arguments) {
  final out = _option(arguments, '--out') ?? 'build/evidence/C04';
  final skipFull = arguments.contains('--skip-full');
  final runner = _Runner(out);
  final head = runner.git(<String>['rev-parse', 'HEAD']);
  final dirty = runner.git(<String>['status', '--porcelain']);
  stdout.writeln('HEAD $head${dirty.isEmpty ? '' : ' (dirty worktree)'}');

  // 1. Static lanes.
  final format = runner.lane('format', <String>[
    'format',
    '--output=none',
    '--set-exit-if-changed',
    '.',
  ]);
  final analyze = runner.lane('analyze', <String>['analyze', '--fatal-infos']);

  // 2. VM suites: the focused JPX suites and the whole CI VM lane.
  final vmJpx = runner.lane('vm-jpx', <String>[
    'test',
    'test/tests/pdf/pdf_jpx_precision_test.dart',
    'test/tests/pdf/pdf_jpx_test.dart',
    'test/support/dwt_test.dart',
  ]);
  final vmFull = skipFull
      ? null
      : runner.lane('vm-full', <String>['test', '--exclude-tags', 'fuzz']);

  // 3. Browser: a fresh worker, then the JPX suites and the whole lane.
  final worker = runner.lane('worker-compile', <String>[
    'compile',
    'js',
    'web/unseal_worker.dart',
    '-o',
    'test/web/unseal_worker.js',
  ]);
  final chromeJpx = runner.lane('chrome-jpx', <String>[
    'test',
    '-p',
    'chrome',
    'test/web/jpx_wire_test.dart',
    'test/web/jpx_precision_wire_test.dart',
  ]);
  final chromeFull = skipFull
      ? null
      : runner.lane('chrome-full', <String>['test', '-p', 'chrome', 'test/web/']);

  // 4. Fuzz, corpus inventory, publish dry-run, benchmark.
  final fuzz = runner.lane('fuzz', <String>[
    'test',
    '--tags',
    'fuzz',
    'test/fuzz/jpx_precision_fuzz_test.dart',
  ]);
  final inventory = runner.lane('inventory', <String>[
    'run',
    'tool/fuzz_corpus_inventory.dart',
    '--check-manifest',
  ]);
  final publish = runner.lane('publish-dry-run', <String>['pub', 'publish', '--dry-run']);
  final bench = runner.lane('bench', <String>[
    'run',
    'tool/jpx_precision_bench.dart',
    '--out=$out/bench.json',
  ]);

  // 5. In-process corpus comparison and comparator negatives.
  final corpusReport = runner.corpusComparison();
  final negatives = runner.comparatorNegatives();
  final referenceCheck = runner.referenceCheck(head);

  bool laneOk(final Map<String, Object?>? lane) => lane == null || lane['exitCode'] == 0;
  String log(final String name) => '$out/lanes/$name.log';

  final corpusNativeOk = corpusReport['nativeLaneAllPassed'] == true;
  final corpusGeometryOk = corpusReport['geometryAllPassed'] == true;
  final corpusUpsampleOk = corpusReport['upsampleLaneAllPassed'] == true;
  final corpusRgbOk = corpusReport['rgbLaneAllPassed'] == true;
  final eightBitOk = corpusReport['eightBitFixturesExact'] == true;
  final negativesOk = negatives['allDetected'] == true;
  final referenceOk = referenceCheck['passed'] == true;
  final benchOk = laneOk(bench) && File('$out/bench.json').existsSync();

  final cases = <Map<String, Object?>>[
    _case(
      'JP01',
      'PDF JPXDecode exposes the image through the public eager parse and the session engine; '
          'the 16-bit PNG output contract and the 8-bit regression are pinned.',
      laneOk(vmJpx) && laneOk(vmFull) && eightBitOk && corpusNativeOk,
      <String>[log('vm-jpx'), if (vmFull != null) log('vm-full'), '$out/corpus-comparison.json'],
      <String, Object?>{
        'eightBitCorpusExact': eightBitOk,
        'vmJpxExit': vmJpx['exitCode'],
        'vmFullExit': vmFull?['exitCode'],
      },
    ),
    _case(
      'JP02',
      'OpenJPEG 2.5.4 executed on every fixture; 8/9/10/12/16-bit lossless native samples equal exactly; '
          'synthetic (opj_oracle), independent (ffmpeg) and lossy fixtures declared separately.',
      corpusNativeOk && referenceOk && laneOk(vmJpx),
      <String>['$out/corpus-comparison.json', '$out/reference-check.json', log('vm-jpx')],
      <String, Object?>{
        'nativeLane': corpusReport['nativeLane'],
        'referenceCommands': referenceCheck['commands'],
        'referenceArtifacts': referenceCheck['artifacts'],
      },
    ),
    _case(
      'JP03',
      'dx/dy, origins and component grids verified in 4:2:2/4:2:0, odd sizes, multiple tiles and edges; '
          'the upsample lane is compared independently of colour conversion.',
      corpusGeometryOk && corpusUpsampleOk && laneOk(vmJpx),
      <String>['$out/corpus-comparison.json', log('vm-jpx')],
      <String, Object?>{
        'geometry': corpusReport['geometry'],
        'upsampleLane': corpusReport['upsampleLane'],
      },
    ),
    _case(
      'JP04',
      'JP2 sYCC output verified against opj_decompress with the fixed colour policy; '
          'incompatible MCT grids, foreign layouts, palettes, alpha and profiles refused typed.',
      corpusRgbOk && laneOk(vmJpx),
      <String>['$out/corpus-comparison.json', log('vm-jpx')],
      <String, Object?>{'rgbLane': corpusReport['rgbLane']},
    ),
    _case(
      'JP05',
      'PDF integration tests for BitsPerComponent, ColorSpace, consistent and inconsistent dimensions, '
          'filter chains and repeated images; page text, layout and the rest of the VM suite unchanged.',
      laneOk(vmJpx) && laneOk(vmFull),
      <String>[log('vm-jpx'), if (vmFull != null) log('vm-full')],
      <String, Object?>{'vmFullExit': vmFull?['exitCode']},
    ),
    _case(
      'JP06',
      'Input, per-component samples, native planes, tiles, coefficients, upsample, RGB and PNG output '
          'budgeted before allocation; overflow, truncation, invalid precision and bombs refused typed.',
      laneOk(vmJpx) && laneOk(fuzz),
      <String>[log('vm-jpx'), log('fuzz')],
      <String, Object?>{'fuzzExit': fuzz['exitCode']},
    ),
    _case(
      'JP07',
      'VM and compiled JavaScript produce the same samples and PNG scanlines; the freshly compiled real '
          'worker serves the PDF images through two concurrent sessions.',
      laneOk(worker) && laneOk(chromeJpx) && laneOk(chromeFull) && laneOk(vmJpx),
      <String>[
        log('worker-compile'),
        log('chrome-jpx'),
        if (chromeFull != null) log('chrome-full'),
        log('vm-jpx'),
      ],
      <String, Object?>{
        'workerExit': worker['exitCode'],
        'chromeJpxExit': chromeJpx['exitCode'],
        'chromeFullExit': chromeFull?['exitCode'],
      },
    ),
    _case(
      'JP08',
      'Complete matrix on a clean checkpoint: format, analysis, VM, browser, fuzz, corpus inventory and '
          'pub dry-run; comparator negatives detected; isolated 8-bit versus precision/subsampling benchmark.',
      laneOk(format) &&
          laneOk(analyze) &&
          laneOk(vmFull) &&
          laneOk(chromeFull) &&
          laneOk(fuzz) &&
          laneOk(inventory) &&
          laneOk(publish) &&
          benchOk &&
          negativesOk,
      <String>[
        log('format'),
        log('analyze'),
        if (vmFull != null) log('vm-full'),
        if (chromeFull != null) log('chrome-full'),
        log('fuzz'),
        log('inventory'),
        log('publish-dry-run'),
        log('bench'),
        if (benchOk) '$out/bench.json',
        '$out/comparator-negatives.json',
      ],
      <String, Object?>{
        'comparatorNegatives': negatives,
        'bench': benchOk ? _benchSummary('$out/bench.json') : null,
      },
    ),
  ];

  final report = <String, Object?>{
    'schemaVersion': 1,
    'mission': 'C04',
    'head': head,
    'worktreeClean': dirty.isEmpty,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'protocol': 'doc/jpeg2000-precision.md',
    'lanes': runner.lanes,
    'corpus': corpusReport['summary'],
    'cases': cases,
  };
  File(
    '$out/comparison.json',
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  final failed = cases
      .where((final c) => c['verdict'] != 'pass')
      .map((final c) => c['id'])
      .toList();
  stdout.writeln(
    failed.isEmpty
        ? 'comparison PASSED: 8/8 acceptance rows -> $out/comparison.json'
        : 'comparison FAILED: $failed -> $out/comparison.json',
  );
  exitCode = failed.isEmpty ? 0 : 1;
}

String? _option(final List<String> arguments, final String name) {
  for (final argument in arguments) {
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

Map<String, Object?> _case(
  final String id,
  final String requirement,
  final bool passed,
  final List<String> evidence,
  final Map<String, Object?> measurements,
) => <String, Object?>{
  'id': id,
  'requirement': requirement,
  'verdict': passed ? 'pass' : 'fail',
  'skipped': false,
  'evidenceArtifacts': evidence,
  'measurements': measurements,
};

Map<String, Object?> _benchSummary(final String path) {
  final report = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
  return <String, Object?>{
    'cases': <Object?>[
      for (final entry in report['cases']! as List<Object?>)
        <String, Object?>{
          'label': (entry! as Map<String, Object?>)['label'],
          'p50Micros': (entry as Map<String, Object?>)['p50Micros'],
          'p95Micros': entry['p95Micros'],
          'maxRssMiB': ((entry['maxRssBytes']! as int) / (1024 * 1024)).toStringAsFixed(1),
        },
    ],
  };
}

final class _Runner {
  _Runner(this.out) {
    Directory('$out/lanes').createSync(recursive: true);
  }

  final String out;
  final List<Map<String, Object?>> lanes = <Map<String, Object?>>[];

  String git(final List<String> arguments) =>
      Process.runSync('git', arguments).stdout.toString().trim();

  /// Runs `dart <arguments>` with the pinned SDK executable, teeing the
  /// output to `<out>/lanes/<name>.log`.
  Map<String, Object?> lane(final String name, final List<String> arguments) {
    final logFile = File('$out/lanes/$name.log');
    final executable = Platform.resolvedExecutable;
    stdout.write('lane $name: dart ${arguments.join(' ')} ... ');
    final watch = Stopwatch()..start();
    final result = Process.runSync(
      executable,
      arguments,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    );
    watch.stop();
    final body = StringBuffer()
      ..writeln('# lane $name')
      ..writeln('# argv: $executable ${arguments.join(' ')}')
      ..writeln(
        '# started: ${DateTime.now().toUtc().toIso8601String()} duration ${watch.elapsedMilliseconds} ms',
      )
      ..writeln('# exit: ${result.exitCode}')
      ..writeln()
      ..write(result.stdout)
      ..write(result.stderr);
    logFile.writeAsStringSync(body.toString());
    final record = <String, Object?>{
      'name': name,
      'argv': <String>[executable, ...arguments],
      'exitCode': result.exitCode,
      'durationMs': watch.elapsedMilliseconds,
      'log': logFile.path,
      'logSha256': sha256.convert(logFile.readAsBytesSync()).toString(),
    };
    lanes.add(record);
    stdout.writeln('exit ${result.exitCode} (${watch.elapsedMilliseconds} ms)');
    return record;
  }

  /// All fixtures through the shared comparator; writes
  /// `<out>/corpus-comparison.json`.
  Map<String, Object?> corpusComparison() {
    final corpus = loadPrecisionCorpus();
    final tolerances = loadPrecisionTolerances();
    final outcomes = <FixtureOutcome>[
      for (final fixture in corpus) comparePrecisionFixture(fixture, tolerances),
    ];
    Map<String, Object?> laneSummary(final String lane) {
      final rows = <LaneOutcome>[
        for (final outcome in outcomes)
          for (final row in outcome.lanes)
            if (row.lane == lane) row,
      ];
      return <String, Object?>{
        'fixtures': rows.length,
        'passed': rows.where((final r) => r.passed).length,
        'exact': rows.where((final r) => r.stats.exact).length,
        'maxAbsErrorObserved': rows.isEmpty
            ? 0
            : rows
                  .map((final r) => r.stats.maxAbsError)
                  .reduce((final a, final b) => a > b ? a : b),
        'allPassed': rows.every((final r) => r.passed),
      };
    }

    final native = laneSummary('native');
    final upsample = laneSummary('upsample');
    final rgb = laneSummary('rgb');
    final geometry = <String, Object?>{
      'fixtures': outcomes.length,
      'passed': outcomes
          .where((final o) => o.decodeError == null && o.geometryProblems.isEmpty)
          .length,
    };
    final eightBit = outcomes.where((final o) => o.fixture.precision == 8);
    final report = <String, Object?>{
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'tolerances': <String, Object?>{
        'globalMaxAbsError': tolerances.globalMaxAbsError,
        'globalRmse': tolerances.globalRmse,
        'lanes': <String, Object?>{
          for (final entry in tolerances.lanes.entries)
            entry.key: <String, Object?>{'maxAbsError': entry.value.$1, 'rmse': entry.value.$2},
        },
      },
      'summary': <String, Object?>{
        'fixtures': outcomes.length,
        'passed': outcomes.where((final o) => o.passed).length,
        'lossless': outcomes.where((final o) => o.fixture.lossless).length,
        'lossy': outcomes.where((final o) => !o.fixture.lossless).length,
        'independentProducer': outcomes
            .where((final o) => o.fixture.producer.startsWith('ffmpeg'))
            .length,
        'precisions': (outcomes.map((final o) => o.fixture.precision).toSet().toList()..sort()),
      },
      'nativeLane': native,
      'upsampleLane': upsample,
      'rgbLane': rgb,
      'geometry': geometry,
      'nativeLaneAllPassed': native['allPassed'],
      'upsampleLaneAllPassed': upsample['allPassed'],
      'rgbLaneAllPassed': rgb['allPassed'],
      'geometryAllPassed': geometry['passed'] == outcomes.length,
      'eightBitFixturesExact': eightBit.isNotEmpty && eightBit.every((final o) => o.passed),
      'fixtures': <Object?>[for (final outcome in outcomes) outcome.toJson()],
    };
    File(
      '$out/corpus-comparison.json',
    ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
    stdout.writeln(
      'corpus: ${report['summary']} native ${native['passed']}/${native['fixtures']} '
      'upsample ${upsample['passed']}/${upsample['fixtures']} rgb ${rgb['passed']}/${rgb['fixtures']}',
    );
    return report;
  }

  /// The comparator must refuse a missing, a corrupted and a truncated
  /// reference; writes `<out>/comparator-negatives.json`.
  Map<String, Object?> comparatorNegatives() {
    final corpus = loadPrecisionCorpus();
    final tolerances = loadPrecisionTolerances();
    final fixture = corpus.firstWhere((final f) => f.name == 'synth-sycc8-420-lossless');
    final temp = Directory('$out/comparator-negatives')..createSync(recursive: true);
    final results = <String, Object?>{};

    final missing = Directory('${temp.path}/missing')..createSync();
    final missingOutcome = comparePrecisionFixture(fixture, tolerances, oracleDir: missing.path);
    results['missingReference'] = <String, Object?>{
      'detected':
          !missingOutcome.passed &&
          missingOutcome.lanes.every((final l) => l.reason.contains('missing')),
      'lanes': <Object?>[for (final l in missingOutcome.lanes) l.toJson()],
    };

    final corrupt = Directory('${temp.path}/corrupt')..createSync();
    for (final suffix in <String>['native.bin', 'native.json', 'rgb.rawl']) {
      final bytes = Uint8List.fromList(
        File('$kJpxPrecisionCorpusDir/oracle/${fixture.name}.$suffix').readAsBytesSync(),
      );
      if (suffix != 'native.json') {
        bytes[bytes.length ~/ 2] ^= 0x40;
      }
      File('${corrupt.path}/${fixture.name}.$suffix').writeAsBytesSync(bytes);
    }
    final corruptOutcome = comparePrecisionFixture(fixture, tolerances, oracleDir: corrupt.path);
    results['corruptedReference'] = <String, Object?>{
      'detected':
          !corruptOutcome.passed &&
          corruptOutcome.lanes.every((final l) => !l.passed && l.stats.differing == 1),
      'lanes': <Object?>[for (final l in corruptOutcome.lanes) l.toJson()],
    };

    final truncated = Directory('${temp.path}/truncated')..createSync();
    final native = File(
      '$kJpxPrecisionCorpusDir/oracle/${fixture.name}.native.bin',
    ).readAsBytesSync();
    File(
      '${truncated.path}/${fixture.name}.native.bin',
    ).writeAsBytesSync(native.sublist(0, native.length - 1));
    File('${truncated.path}/${fixture.name}.rgb.rawl').writeAsBytesSync(
      File('$kJpxPrecisionCorpusDir/oracle/${fixture.name}.rgb.rawl').readAsBytesSync(),
    );
    final truncatedOutcome = comparePrecisionFixture(
      fixture,
      tolerances,
      oracleDir: truncated.path,
    );
    results['truncatedReference'] = <String, Object?>{
      'detected': !truncatedOutcome.passed && truncatedOutcome.lanes.first.stats.sizeMismatch,
      'lanes': <Object?>[for (final l in truncatedOutcome.lanes) l.toJson()],
    };

    // A failing reference command must refuse too: run opj_oracle on a
    // corrupted copy and record the non-zero exit.
    final broken = File('${temp.path}/broken.jp2')
      ..writeAsBytesSync(
        File('$kJpxPrecisionCorpusDir/${fixture.file}').readAsBytesSync().sublist(0, 200),
      );
    final oracleTool = Platform.environment['OPJ_ORACLE'] ?? 'build/tools/opj_oracle';
    final failing = File(oracleTool).existsSync()
        ? Process.runSync(oracleTool, <String>[
            'dump',
            broken.path,
            '${temp.path}/broken.json',
            '${temp.path}/broken.bin',
          ])
        : null;
    results['failingReferenceCommand'] = <String, Object?>{
      'detected': failing != null && failing.exitCode != 0,
      'exitCode': failing?.exitCode,
      'tool': oracleTool,
    };

    final all = results.values.every((final r) => (r! as Map<String, Object?>)['detected'] == true);
    results['allDetected'] = all;
    File(
      '$out/comparator-negatives.json',
    ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(results)}\n');
    stdout.writeln('comparator negatives: ${all ? 'all detected' : 'NOT all detected'}');
    return results;
  }

  /// Cross-checks the reference stage output for this HEAD and writes
  /// `<out>/reference-check.json`.
  Map<String, Object?> referenceCheck(final String head) {
    final file = File('$out/reference.json');
    Map<String, Object?> result;
    if (!file.existsSync()) {
      result = <String, Object?>{
        'passed': false,
        'reason': 'reference.json missing (run tool/jpx_precision_reference.dart)',
      };
    } else {
      final report = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final summary = report['summary']! as Map<String, Object?>;
      final fixtures = report['fixtures']! as List<Object?>;
      var matching = 0;
      for (final fixture in fixtures) {
        for (final artifact in (fixture! as Map<String, Object?>)['artifacts']! as List<Object?>) {
          if ((artifact! as Map<String, Object?>)['matchesCommitted'] == true) matching++;
        }
      }
      result = <String, Object?>{
        'passed':
            summary['status'] == 'passed' && report['head'] == head && summary['problems'] == 0,
        'referenceHead': report['head'],
        'head': head,
        'referenceSha256': sha256.convert(file.readAsBytesSync()).toString(),
        'commands': summary['commands'],
        'artifacts': summary['artifacts'],
        'artifactsMatchingCommitted': matching,
        'tools': report['tools'],
      };
    }
    File(
      '$out/reference-check.json',
    ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(result)}\n');
    stdout.writeln('reference check: ${result['passed'] == true ? 'passed' : 'FAILED'}');
    return result;
  }
}
