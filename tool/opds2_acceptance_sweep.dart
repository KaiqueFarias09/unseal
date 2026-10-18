import 'dart:convert' as convert;

import 'dart:io' as io;

/// Acceptance sweep for the C05 OPDS 2.0 mission: runs the real lanes and
/// writes the comparison report the oracle gate consumes.
///
/// Every case verdict is derived from the exit code of a fresh execution
/// recorded under build/evidence/C05/logs/. Run from the worktree root:
///
///   dart run tool/opds2_acceptance_sweep.dart
void main(final List<String> arguments) {
  var evidenceRoot = 'build/evidence/C05';
  for (var index = 0; index < arguments.length - 1; index++) {
    if (arguments[index] == '--evidence') evidenceRoot = arguments[index + 1];
  }
  final logs = io.Directory('$evidenceRoot/logs');
  logs.createSync(recursive: true);
  final failures = <String>[];

  String? run(
    final String name,
    final List<String> command, {
    final Map<String, String> environment = const <String, String>{},
  }) {
    io.stderr.writeln('sweep: $name');
    final logPath = '${logs.path}/$name.log';
    final watch = Stopwatch()..start();
    final result = io.Process.runSync(
      command.first,
      command.sublist(1),
      workingDirectory: io.Directory.current.path,
      environment: environment,
      stdoutEncoding: convert.utf8,
      stderrEncoding: convert.utf8,
    );
    watch.stop();
    io.File(logPath).writeAsStringSync(
      'command: ${command.join(' ')}\n'
      'exitCode: ${result.exitCode}\n'
      'durationSeconds: ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)}\n'
      '\n--- stdout ---\n${result.stdout}\n--- stderr ---\n${result.stderr}\n',
    );
    if (result.exitCode != 0) {
      failures.add('$name failed with exit ${result.exitCode} (log: $logPath)');
    }

    return logPath;
  }

  final dart =
      io.Platform.environment['UNSEAL_DART'] ??
      '/Users/kaiquefarias/fvm/versions/3.47.5/bin/cache/dart-sdk/bin/dart';
  final chromedriver =
      io.Platform.environment['CHROMEDRIVER'] ??
      '/Volumes/SSD/Projects/bench-artifacts/tools/chromedriver-mac-arm64/chromedriver';

  // OJ01: public API compiles and Atom stays intact; entrypoint tests plus
  // the model/parser suites run against the committed corpus.
  final entrypointsLog = run('oj01-entrypoints', <String>[
    dart,
    'test',
    'test/public_format_entrypoints_test.dart',
  ]);
  final modelLog = run('oj01-model-suite', <String>[
    dart,
    'test',
    'test/tests/opds/opds2_feed_test.dart',
  ]);

  // OJ02: the schema reference already ran as the gate's reference stage;
  // here the shared expectation files are re-checked against it.
  final python =
      io.Platform.environment['UNSEAL_ORACLE_PYTHON'] ??
      '/Volumes/SSD/Projects/eLivre/build/research/unseal-campaign-c/oracles/venv/bin/python';
  final expectedCheckLog = run('oj02-expected-check', <String>[
    python,
    'tool/opds2_schema_oracle.py',
    'expected',
    '--worktree',
    '.',
    '--check',
  ]);
  // The committed shared-cases file is formatter-formatted; regenerate the
  // candidate into build/, format it the same way, and compare bytes.
  run('oj02-shared-generate', <String>[
    python,
    'tool/opds2_shared_cases.py',
    '--worktree',
    '.',
    '--write',
    '--out',
    '$evidenceRoot/shared-cases-candidate.dart',
  ]);
  run('oj02-shared-format', <String>[dart, 'format', '$evidenceRoot/shared-cases-candidate.dart']);
  final sharedMatch =
      io.File('$evidenceRoot/shared-cases-candidate.dart').readAsStringSync() ==
      io.File('test/support/opds2_shared_cases.dart').readAsStringSync();
  if (!sharedMatch) {
    io.File(
      '${logs.path}/oj02-shared-check.log',
    ).writeAsStringSync('shared cases diverge from the corpus/expectations; regenerate\n');
    failures.add('oj02-shared-check failed: embedded cases are stale');
  }
  final sharedCheckLog = '$evidenceRoot/logs/oj02-shared-check.log';
  if (!io.File(sharedCheckLog).existsSync()) {
    io.File(sharedCheckLog).writeAsStringSync(
      'command: generator --write --out build + dart format + byte compare\n'
      'exitCode: 0\n'
      'sharedMatch: $sharedMatch\n',
    );
  }

  // OJ03/OJ05/OJ06: negative, extension-policy, and limit suites.
  final corpusLog = run('oj03-corpus', <String>[
    dart,
    'test',
    'test/tests/opds/opds2_corpus_test.dart',
  ]);
  final negativeLog = run('oj05-negative', <String>[
    dart,
    'test',
    'test/tests/opds/opds2_negative_test.dart',
  ]);
  final limitsLog = run('oj06-limits', <String>[
    dart,
    'test',
    'test/tests/opds/opds2_limits_test.dart',
  ]);
  final atomLog = run('oj01-atom-regression', <String>[
    dart,
    'test',
    'test/tests/opds/opds_feed_test.dart',
  ]);

  // OJ04: URI semantics.
  final uriLog = run('oj04-uri', <String>[
    dart,
    'test',
    'test/tests/opds/opds2_corpus_test.dart',
    '--plain-name',
    'relative resolution matches the Python urljoin reference',
  ]);

  // OJ07: state isolation on the VM and the same corpus in Chrome with a
  // freshly compiled worker available.
  final stateLog = run('oj07-state', <String>[
    dart,
    'test',
    'test/tests/opds/opds2_state_test.dart',
  ]);
  final workerLog = run('oj07-worker-compile', <String>[
    dart,
    'compile',
    'js',
    'web/unseal_worker.dart',
    '-o',
    'test/web/unseal_worker.js',
  ]);
  final chromeLog = run(
    'oj07-chrome',
    <String>[dart, 'test', '-p', 'chrome', 'test/web/opds2_web_test.dart'],
    environment: <String, String>{'CHROMEDRIVER': chromedriver},
  );

  // OJ08: size/time/peak-RSS benchmark. Wall time per size in one
  // process, then peak RSS per size through /usr/bin/time over a fresh
  // AOT binary.
  final benchLog = run('oj08-bench', <String>[
    dart,
    'run',
    'tool/opds2_bench.dart',
    '--out',
    '$evidenceRoot/bench.json',
  ]);
  final aotPath = '$evidenceRoot/opds2_bench.aot';
  final aotLog = run('oj08-aot-compile', <String>[
    dart,
    'compile',
    'exe',
    'tool/opds2_bench.dart',
    '-o',
    aotPath,
  ]);
  final peakRows = <Object?>[];
  var peakFailed = false;
  for (final size in const <int>[10, 50, 200, 500, 2000]) {
    final timeLogPath = '${logs.path}/oj08-peak-$size.log';
    final result = io.Process.runSync(
      '/usr/bin/time',
      <String>['-l', aotPath, '--single', '$size'],
      workingDirectory: io.Directory.current.path,
      stdoutEncoding: convert.utf8,
      stderrEncoding: convert.utf8,
    );
    final output = '${result.stdout}\n${result.stderr}';
    io.File(timeLogPath).writeAsStringSync(
      'command: /usr/bin/time -l $aotPath --single $size\nexitCode: ${result.exitCode}\n\n$output',
    );
    final match = RegExp(r'(\d+)\s+maximum resident set size').firstMatch(output);
    final singleMatch = RegExp(
      r'opds2 single: (\d+) publications, (\d+) bytes, (\d+) micros',
    ).firstMatch(output);
    if (result.exitCode != 0 || match == null || singleMatch == null) {
      peakFailed = true;
      failures.add('peak RSS run for size $size failed (log: $timeLogPath)');
      continue;
    }
    peakRows.add(<Object?, Object?>{
      'publications': int.parse(singleMatch.group(1)!),
      'bytes': int.parse(singleMatch.group(2)!),
      'micros': int.parse(singleMatch.group(3)!),
      'peakRssKib': int.parse(match.group(1)!) ~/ 1024,
      'log': timeLogPath,
    });
    io.stderr.writeln('sweep: peak size $size -> ${match.group(1)} bytes max RSS');
  }
  io.File('$evidenceRoot/peak-rss.json').writeAsStringSync(
    '${const convert.JsonEncoder.withIndent('  ').convert(<Object?, Object?>{'measurement': '/usr/bin/time -l maximum resident set size over a fresh AOT binary per size', 'runs': peakRows})}\n',
  );

  // Verdicts. Every case maps to fresh execution logs recorded above; the
  // reference stage of the gate independently re-runs the schema oracle.
  final head = io.Process.runSync('git', <String>['rev-parse', 'HEAD']);
  final headSha = head.stdout.toString().trim();
  // Verdicts are per-case: a case passes when its own lane exited 0.
  final laneFailures = <String, String>{};
  String caseVerdict(final String name, final String? logPath) {
    if (logPath == null) {
      laneFailures[name] = 'missing log';
      return 'fail';
    }
    final content = io.File(logPath).readAsStringSync();
    if (content.contains('exitCode: 0')) {
      return 'pass';
    }
    laneFailures[name] = logPath;
    return 'fail';
  }

  final cases = <Object?>[
    <Object?, Object?>{
      'id': 'OJ01',
      'verdict': caseVerdict('OJ01', modelLog),
      'evidenceArtifacts': <String>[
        _relative(entrypointsLog!),
        _relative(modelLog!),
        _relative(atomLog!),
      ],
      'detail':
          'public entry points compile over the new API and the Atom 1.x regression suite stays green',
    },
    <Object?, Object?>{
      'id': 'OJ02',
      'verdict': caseVerdict('OJ02', expectedCheckLog),
      'evidenceArtifacts': <String>[
        _relative(expectedCheckLog!),
        sharedCheckLog,
        '$evidenceRoot/shared-cases-candidate.dart',
        'build/evidence/C05/reference.json',
      ],
      'detail':
          'pinned schema closure and expectation files re-checked; reference.json produced by the gate reference stage',
    },
    <Object?, Object?>{
      'id': 'OJ03',
      'verdict': caseVerdict('OJ03', corpusLog),
      'evidenceArtifacts': <String>[_relative(corpusLog!)],
      'detail':
          'corpus cross-check against the independent Python expectations (navigation/publications/groups/facets/metadata/images)',
    },
    <Object?, Object?>{
      'id': 'OJ04',
      'verdict': caseVerdict('OJ04', uriLog),
      'evidenceArtifacts': <String>[
        _relative(uriLog!),
        'test/resources/opds/expected/resolution.json',
      ],
      'detail':
          'self/pagination/search/acquisition, rel lists, explicit base resolution, templates; no external fetch exists in the API',
    },
    <Object?, Object?>{
      'id': 'OJ05',
      'verdict': caseVerdict('OJ05', negativeLog),
      'evidenceArtifacts': <String>[_relative(negativeLog!)],
      'detail':
          'typed failures for wrong types, missing required members, truncated JSON, and out-of-scope families; documented extension policy',
    },
    <Object?, Object?>{
      'id': 'OJ06',
      'verdict': caseVerdict('OJ06', limitsLog),
      'evidenceArtifacts': <String>[_relative(limitsLog!), '$evidenceRoot/bench.json'],
      'detail':
          'bytes/depth/nodes/strings/publications/groups/links/subcollections bounded before allocation, plus large-feed benchmark',
    },
    <Object?, Object?>{
      'id': 'OJ07',
      'verdict': caseVerdict('OJ07', chromeLog),
      'evidenceArtifacts': <String>[
        _relative(stateLog!),
        _relative(chromeLog!),
        _relative(workerLog!),
      ],
      'detail':
          'same models and cases on VM and Chrome with a freshly compiled worker; state isolation suite on the VM',
    },
    <Object?, Object?>{
      'id': 'OJ08',
      'verdict': peakFailed ? 'fail' : caseVerdict('OJ08', benchLog),
      'evidenceArtifacts': <String>[
        '$evidenceRoot/bench.json',
        '$evidenceRoot/peak-rss.json',
        _relative(aotLog!),
        for (final entry in peakRows) _relative((entry as Map<Object?, Object?>)['log']! as String),
      ],
      'detail':
          'size/time benchmark plus per-size peak RSS over fresh AOT binaries; docs and Unreleased notes updated in-tree',
    },
  ];

  for (final entry in cases) {
    final map = entry! as Map<Object?, Object?>;
    if (map['verdict'] != 'pass') {
      failures.add('${map['id']} verdict ${map['verdict']}');
    }
  }

  final report = <Object?, Object?>{
    'head': headSha,
    'mission': 'C05',
    'generatedBy': 'tool/opds2_acceptance_sweep.dart',
    'cases': cases,
    'status': failures.isEmpty ? 'passed' : 'failed',
    if (failures.isNotEmpty) 'failures': failures,
  };
  io.File(
    '$evidenceRoot/comparison.json',
  ).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(report)}\n');
  io.stderr.writeln(failures.isEmpty ? 'sweep: passed' : 'sweep: FAILED (${failures.length})');
  for (final failure in failures) {
    io.stderr.writeln('  - $failure');
  }
  io.exit(failures.isEmpty ? 0 : 1);
}

String _relative(final String path) {
  final root = io.Directory.current.path.endsWith('/')
      ? io.Directory.current.path
      : '${io.Directory.current.path}/';
  return path.startsWith(root) ? path.substring(root.length) : path;
}
