import 'dart:convert' as convert;
import 'dart:io';

/// Runs the B05 acceptance pipeline and assembles the oracle-gate
/// comparison report: one verdict per RS01-RS07 acceptance, each backed
/// by a real command that ran during this invocation.
///
/// Stages:
/// 1. `tool/rar5_compare.dart` over the full RAR 5 corpus (both
///    oracles) — positive comparisons RS01/RS02 and counted rejections
///    RS03.
/// 2. `dart test` on the solid acceptance suites (corruption, order,
///    replay budget, isolation) — RS03/RS04/RS05/RS06.
/// 3. `dart test -p chrome` on the worker session suite — RS06 on a
///    real browser worker (requires a compiled `unseal_worker.js` and a
///    chromedriver on :4444).
/// 4. `tool/rar5_bench.dart --solid scenarios` — RS07 measurements,
///    recorded beside the report.
///
/// Usage: `dart run tool/rar5_solid_evidence.dart --out=build/rar5-solid`
void main(final List<String> arguments) {
  var outDir = 'build/rar5-solid';
  var runChrome = true;
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i].startsWith('--out=')) {
      outDir = arguments[i].substring('--out='.length);
    } else if (arguments[i] == '--skip-chrome') {
      runChrome = false;
    }
  }
  final dart = Platform.resolvedExecutable;

  final cases = <Map<String, Object?>>[];
  String verdict(final String id, final bool ok, final String evidence) {
    final case_ = {'id': id, 'verdict': ok ? 'pass' : 'diverged', 'evidence': evidence};
    cases.add(case_);
    stdout.writeln('${ok ? "ok  " : "FAIL"} $id: $evidence');

    return ok ? 'pass' : 'diverged';
  }

  // RS01/RS02: byte comparison over the whole corpus, solid chains
  // included; the comparator fails on any divergence and counts
  // expected rejections separately in its report.
  final compareReportPath = '$outDir/compare-report.json';
  final fixtures = <String>[
    for (final name
        in Directory('test/resources/books/comic/rar5')
            .listSync()
            .whereType<File>()
            .map((final file) => file.uri.pathSegments.last)
            .where((final name) => name.endsWith('.cbr') || name.endsWith('.rar')))
      'test/resources/books/comic/rar5/$name',
  ]..sort();
  final compareRun = _run([
    dart,
    'run',
    'tool/rar5_compare.dart',
    '--allow-reject',
    '--workdir=$outDir/oracle',
    '--report=$compareReportPath',
    ...fixtures,
  ]);
  var compareOk = compareRun.exitCode == 0;
  Map<String, Object?>? comparatorReport;
  try {
    comparatorReport = (convert.json.decode(File(compareReportPath).readAsStringSync()) as Map)
        .cast<String, Object?>();
  } on Object {
    compareOk = false;
  }
  final totals = comparatorReport?['totals'] as Map<String, Object?>? ?? const {};
  final failures = totals['failures'] as int? ?? 1;
  final compared = totals['compared'] as int? ?? 0;
  verdict(
    'RS01',
    compareOk && failures == 0 && compared > 0 && _hasAllSolidArchives(comparatorReport),
    'rardecode + libarchive byte-identical over ${totals['compared']} entries; '
        'solid archives compared: ${_solidArchiveCount(comparatorReport)}',
  );
  verdict(
    'RS02',
    compareOk && failures == 0,
    'methods, dictionaries (128 KiB-64 MiB), filters (delta/E8/E8-E9/ARM), '
        'empty files, directories, stored-in-chain, zero CRC and UTF-8 paths '
        'exercised by the pinned corpus; no unexpected variant accepted',
  );

  // RS03: corruption and CRC acceptance tests.
  final corruptionRun = _run([
    dart,
    'test',
    'test/tests/comic/rar5_test.dart',
    '--plain-name',
    'RS03',
    '-j',
    '4',
  ]);
  verdict(
    'RS03',
    corruptionRun.exitCode == 0,
    'corruption suite passed: flipped chain bytes, forged data CRC, '
        'truncation, and real zero-CRC verification',
  );

  // RS04/RS05/RS06: the VM acceptance suites.
  final sessionRun = _run([
    dart,
    'test',
    'test/tests/progressive/cbr_session_test.dart',
    'test/tests/comic/rar_random_access_test.dart',
    '-j',
    '4',
  ]);
  verdict(
    'RS04',
    sessionRun.exitCode == 0,
    'eager/session parity, forward/reverse/interleaved order, reopen and '
        'replay behavior all green in the session suites',
  );
  verdict(
    'RS05',
    sessionRun.exitCode == 0,
    'cumulative replay budget exhausts typed under hostile alternation; '
        'checkpoints stay under the 16/96 MiB ceilings; first pass is free',
  );

  final vmIsolationRun = _run([
    dart,
    'test',
    'test/tests/progressive/cbr_session_test.dart',
    '--plain-name',
    'isolated dictionaries',
    '-j',
    '1',
  ]);

  // The browser half runs on a real worker. A missing environment or a
  // failing run fails the whole case — SKIP is never a pass.
  var chromeOk = false;
  var chromeNote = 'Chrome worker run disabled by flag';
  if (runChrome) {
    final chromeRun = _run([
      dart,
      'test',
      '-p',
      'chrome',
      'test/web/session_pdf_cbr_worker_test.dart',
      '--plain-name',
      'solid CBR session in the worker',
      '-j',
      '1',
    ]);
    chromeOk = chromeRun.exitCode == 0;
    chromeNote = chromeOk
        ? 'a real worker session serves forward, reverse and interleaved '
              'loads through the compiled unseal_worker.js'
        : 'the Chrome worker run failed';
  }
  verdict(
    'RS06',
    vmIsolationRun.exitCode == 0 && chromeOk,
    'VM: two sessions walk opposite directions with isolated dictionaries; '
        'Chrome: $chromeNote',
  );

  // RS07: benchmarks, recorded beside the report.
  final benchPath = '$outDir/bench.txt';
  final benchRun = _run([dart, 'run', 'tool/rar5_bench.dart', '--pages=12', '--reps=3']);
  if (benchRun.exitCode == 0) {
    File(benchPath).writeAsStringSync(benchRun.output);
  }
  verdict(
    'RS07',
    benchRun.exitCode == 0,
    'open, eager, forward/reverse walks, repeated decode and RSS growth '
        'measured against the same-shape non-solid baseline ($benchPath)',
  );

  final report = <String, Object?>{
    'mission': 'B05',
    'cases': cases,
    'commandRuns': [
      for (final run in _runs)
        {'argv': run.argv, 'exitCode': run.exitCode, 'outputTail': _tail(run.output)},
    ],
  };
  final reportFile = File('$outDir/comparison.json');
  reportFile.writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln('comparison report written to ${reportFile.path}');

  final failed = cases.any((final case_) => case_['verdict'] != 'pass');
  exit(failed ? 1 : 0);
}

bool _hasAllSolidArchives(final Map<String, Object?>? report) {
  if (report == null) return false;
  const solid = [
    'rar5-solid-chain.cbr',
    'rar5-solid-comic.cbr',
    'rar5-solid-mixed.cbr',
    'rar5-solid-dict-grow.cbr',
    'rar5-solid-filter-e8.cbr',
    'libarchive-solid.rar',
  ];
  final compared = (report['archives']! as List).cast<Map<String, Object?>>().toSet();

  return solid.every(
    (final name) => compared.any(
      (final archive) => archive['name'] == name && (archive['entries']! as List).isNotEmpty,
    ),
  );
}

int _solidArchiveCount(final Map<String, Object?>? report) {
  if (report == null) return 0;

  return (report['archives']! as List)
      .cast<Map<String, Object?>>()
      .where((final archive) => (archive['name']! as String).contains('solid'))
      .where((final archive) => (archive['entries']! as List).isNotEmpty)
      .length;
}

final List<_CommandRun> _runs = [];

_CommandRun _run(final List<String> argv) {
  stdout.writeln('+ ${argv.skip(1).join(' ')}');
  final result = Process.runSync(argv.first, argv.sublist(1));
  final run = _CommandRun(argv, result.exitCode, '${result.stdout}\n${result.stderr}');
  _runs.add(run);
  if (result.exitCode != 0) {
    stdout.writeln(_tail(run.output));
  }

  return run;
}

String _tail(final String output) {
  final lines = output.trim().split('\n');

  return lines.length <= 12 ? output.trim() : '...\n${lines.sublist(lines.length - 12).join('\n')}';
}

final class _CommandRun {
  _CommandRun(this.argv, this.exitCode, this.output);

  final List<String> argv;
  final int exitCode;
  final String output;
}
