// Compare two schemaVersion-1 benchmark reports (any suite), or run an
// alternating A/B measurement on the same machine.
//
// Two-report mode:
//
//     dart run benchmark/compare_baselines.dart <baseline.json> <current.json> [--filter=<text>]
//
// Joins the two reports on `scenario` and prints the median / p95
// delta per matching row. Comparison is strictly informational — the
// numbers are machine-dependent, so this tool deliberately implements
// no pass/fail gates; only rows whose median regressed by more than
// [slowThresholdPercent] are listed, and the listing is advisory.
//
// A/B mode (preferred: it measures BOTH sides on the SAME machine with
// a discarded warm-up round and ALTERNATED ordering so ambient drift
// cancels instead of biasing one side):
//
//     dart run benchmark/compare_baselines.dart --ab \
//       --a=<command writing a report to its JSON_OUT-like arg> \
//       --b=<command> --rounds=<n> [--workdir=<dir>] [--filter=<text>]
//
// Each round runs A then B, then B then A the next round, collecting
// one report per side per round. The final table reports per-scenario
// median, spread (max-min), and the coefficient of variation across
// rounds, so a noisy row is visible as noise instead of as a
// regression.
//
// Reports are checked for DUPLICATE suite+scenario+fixtureId keys: a
// duplicated row makes joins ambiguous and is rejected with an error.

import 'dart:convert';
import 'dart:io';

/// Median regression above which a row is listed as slower. Advisory
/// only — there is no gate.
const double slowThresholdPercent = 25;

Future<void> main(final List<String> arguments) async {
  if (arguments.contains('--ab')) {
    await _runAb(arguments);
    return;
  }
  final paths = arguments.where((final a) => !a.startsWith('--')).toList();
  final filterArgument = arguments.where((final a) => a.startsWith('--filter=')).firstOrNull;
  if (paths.length != 2) {
    _usage();
    exitCode = 64;
    return;
  }
  final filter = filterArgument?.substring('--filter='.length);
  final baseline = _load(paths[0]);
  final current = _load(paths[1]);

  _checkSchema(baseline, paths[0]);
  _checkSchema(current, paths[1]);
  if (!_rejectDuplicates(baseline, paths[0]) || !_rejectDuplicates(current, paths[1])) {
    return;
  }

  stdout.writeln(
    'baseline : ${baseline['suite']} @ ${(baseline['commit'] as String?)?.substring(0, 8)} '
    '(${baseline['generatedAt']})',
  );
  stdout.writeln(
    'current  : ${current['suite']} @ ${(current['commit'] as String?)?.substring(0, 8)} '
    '(${current['generatedAt']})',
  );
  if (baseline['suite'] != current['suite']) {
    stdout.writeln('warning: suites differ (${baseline['suite']} vs ${current['suite']}).');
  }
  if (baseline['platform'] != current['platform']) {
    stdout
      ..writeln(
        'refusing to compare: platforms differ '
        '(${baseline['platform']} vs ${current['platform']}).',
      )
      ..writeln('Benchmark numbers are machine-dependent by design.');
    exitCode = 2;
    return;
  }

  final baselineRows = _index(baseline, filter);
  final currentRows = _index(current, filter);

  final scenarios = currentRows.keys.toSet()..retainWhere(baselineRows.containsKey);
  stdout.writeln();
  stdout.writeln(
    '${'scenario'.padRight(60)}${'baseline ms'.padLeft(11)}${'current ms'.padLeft(11)}'
    '${'median'.padLeft(9)}${'p95'.padLeft(9)}',
  );
  final slower = <String>[];
  for (final scenario in scenarios.toList()..sort()) {
    final before = baselineRows[scenario]!;
    final after = currentRows[scenario]!;
    final medianDelta = _delta(before['medianMicros'], after['medianMicros']);
    final p95Delta = _delta(before['p95Micros'], after['p95Micros']);
    stdout.writeln(
      '${scenario.padRight(60)}${_ms(before['medianMicros']).padLeft(11)}'
      '${_ms(after['medianMicros']).padLeft(11)}'
      '${_percent(medianDelta).padLeft(9)}${_percent(p95Delta).padLeft(9)}',
    );
    if (medianDelta > slowThresholdPercent) {
      slower.add('$scenario (+${_percent(medianDelta)} median)');
    }
  }

  final added = currentRows.keys.toSet().difference(baselineRows.keys.toSet()).toList()..sort();
  final removed = baselineRows.keys.toSet().difference(currentRows.keys.toSet()).toList()..sort();
  stdout.writeln();
  for (final scenario in added) {
    stdout.writeln('added:   $scenario');
  }
  for (final scenario in removed) {
    stdout.writeln('removed: $scenario');
  }
  stdout.writeln();
  stdout.writeln(
    '${scenarios.length} compared · ${added.length} added · '
    '${removed.length} removed',
  );
  if (slower.isNotEmpty) {
    stdout.writeln();
    stdout.writeln(
      'rows >${slowThresholdPercent.toStringAsFixed(0)}% slower median (informational, no gate):',
    );
    for (final row in slower) {
      stdout.writeln('  $row');
    }
  }
}

// --- A/B mode ---

Future<void> _runAb(final List<String> arguments) async {
  String? commandA;
  String? commandB;
  var rounds = 3;
  var workdir = Directory.systemTemp.path;
  String? filter;
  for (final argument in arguments) {
    String? value;
    if (argument.contains('=')) {
      value = argument.split('=').skip(1).join('=');
    }
    if (argument.startsWith('--a=') && value != null) {
      commandA = value;
    } else if (argument.startsWith('--b=') && value != null) {
      commandB = value;
    } else if (argument.startsWith('--rounds=') && value != null) {
      rounds = (int.tryParse(value) ?? 3).clamp(1, 20);
    } else if (argument.startsWith('--workdir=') && value != null) {
      workdir = value;
    } else if (argument.startsWith('--filter=') && value != null) {
      filter = value;
    }
  }
  if (commandA == null || commandB == null) {
    stderr.writeln('--ab requires --a=<command> and --b=<command>.');
    exitCode = 64;
    return;
  }

  Directory('$workdir/ab').createSync(recursive: true);
  // One discarded warm-up round so both sides pay cache/JIT warm-up
  // before anything is recorded.
  stdout.writeln('warm-up round (discarded)…');
  if (!_runSide('warmup', 'a', commandA, workdir) || !_runSide('warmup', 'b', commandB, workdir)) {
    exitCode = 2;
    return;
  }

  // ALTERNATED rounds: A-B, then B-A, so whoever runs second each round
  // alternates and sustained drift (thermal, page cache) cannot
  // systematically favor one side.
  final samplesA = <String, List<double>>{};
  final samplesB = <String, List<double>>{};
  for (var round = 1; round <= rounds; round++) {
    final first = round.isOdd ? 'a' : 'b';
    final second = round.isOdd ? 'b' : 'a';
    stdout.writeln('round $round/$rounds: $first then $second');
    if (!_runSide('$round', first, first == 'a' ? commandA : commandB, workdir) ||
        !_runSide('$round', second, second == 'a' ? commandA : commandB, workdir)) {
      exitCode = 2;
      return;
    }
    if (!_absorb('$workdir/ab/round$round-a.json', first, samplesA, samplesB) ||
        !_absorb('$workdir/ab/round$round-b.json', second, samplesA, samplesB)) {
      return;
    }
  }

  _printVarianceTable(samplesA, samplesB, filter);
}

bool _runSide(final String round, final String side, final String command, final String workdir) {
  final out = '$workdir/ab/round$round-$side.json';
  final result = Process.runSync(
    '/bin/sh',
    <String>['-c', command],
    environment: {
      'BENCH_OUT': out,
      'JSON_OUT': out,
      'UNSEAL_BENCH_JSON': out,
      'GRIMOIRE_BENCH_JSON': out,
      'GRIMOIRE_NARRATION_BENCH_JSON': out,
    },
  );
  if (result.exitCode != 0 || !File(out).existsSync()) {
    stderr.writeln('$side (round $round) failed — expected a report at $out.');
    return false;
  }
  return true;
}

bool _absorb(
  final String path,
  final String side,
  final Map<String, List<double>> samplesA,
  final Map<String, List<double>> samplesB,
) {
  final report = _load(path);
  _checkSchema(report, path);
  if (!_rejectDuplicates(report, path)) {
    return false;
  }
  for (final record in (report['results'] as List<Object?>?) ?? <Object?>[]) {
    final row = record! as Map<String, Object?>;
    final scenario = row['scenario']! as String;
    final micros = ((row['medianMicros'] as num?) ?? 0).toDouble();
    (side == 'a' ? samplesA : samplesB).putIfAbsent(scenario, () => <double>[]).add(micros);
  }
  return true;
}

void _printVarianceTable(
  final Map<String, List<double>> samplesA,
  final Map<String, List<double>> samplesB,
  final String? filter,
) {
  final scenarios = <String>{...samplesA.keys, ...samplesB.keys}.toList()..sort();
  stdout.writeln();
  stdout.writeln(
    '${'scenario'.padRight(56)}${'A ms'.padLeft(10)}${'B ms'.padLeft(10)}'
    '${'A cv%'.padLeft(7)}${'B cv%'.padLeft(7)}${'A spread'.padLeft(9)}'
    '${'B spread'.padLeft(9)}${'delta'.padLeft(9)}',
  );
  for (final scenario in scenarios) {
    if (filter != null && !scenario.toLowerCase().contains(filter.toLowerCase())) {
      continue;
    }
    final a = samplesA[scenario] ?? <double>[];
    final b = samplesB[scenario] ?? <double>[];
    if (a.isEmpty || b.isEmpty) {
      continue;
    }
    final medianA = _median(a);
    final medianB = _median(b);
    stdout.writeln(
      '${scenario.padRight(56)}${_ms(medianA).padLeft(10)}${_ms(medianB).padLeft(10)}'
      '${_cv(a).padLeft(7)}${_cv(b).padLeft(7)}'
      '${_spread(a).padLeft(9)}${_spread(b).padLeft(9)}'
      '${_percent(_delta(medianA, medianB)).padLeft(9)}',
    );
  }
  stdout.writeln();
  stdout.writeln(
    'cv% = coefficient of variation across rounds; spread = max-min. '
    'High cv% marks a noisy row: treat its delta as noise, not a regression.',
  );
}

double _median(final List<double> values) {
  final sorted = values.toList()..sort();
  return sorted[sorted.length ~/ 2];
}

double _mean(final List<double> values) =>
    values.fold(0.0, (final sum, final v) => sum + v) / values.length;

String _cv(final List<double> values) {
  if (values.length < 2) {
    return '—';
  }
  final mean = _mean(values);
  if (mean == 0) {
    return '—';
  }
  final variance =
      values.fold(0.0, (final sum, final v) => sum + (v - mean) * (v - mean)) / values.length;
  return '${(variance / mean * 100).abs().toStringAsFixed(1)}%';
}

String _spread(final List<double> values) =>
    _ms(values.reduce((final a, final b) => a > b ? a : b) - values.reduce(_smaller));

double _smaller(final double a, final double b) => a < b ? a : b;

// --- shared helpers ---

void _usage() {
  stderr.writeln(
    'usage: dart run benchmark/compare_baselines.dart <baseline.json> '
    '<current.json> [--filter=<text>]\n'
    '       dart run benchmark/compare_baselines.dart --ab --a=<cmd> --b=<cmd> '
    '--rounds=<n> [--workdir=<dir>] [--filter=<text>]',
  );
}

Map<String, Object?> _load(final String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('missing report: $path');
    exitCode = 64;
    throw StateError('missing report');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

void _checkSchema(final Map<String, Object?> report, final String path) {
  if (report['schemaVersion'] != 1) {
    stderr.writeln('$path: unsupported schemaVersion ${report['schemaVersion']}');
    exitCode = 64;
    throw StateError('bad schema');
  }
}

/// A duplicate suite+scenario+fixtureId row makes joins ambiguous —
/// most often two runs appended into one file — and is rejected instead
/// of silently picking the last one.
bool _rejectDuplicates(final Map<String, Object?> report, final String path) {
  final seen = <String, String>{};
  for (final record in (report['results'] as List<Object?>?) ?? <Object?>[]) {
    final row = record! as Map<String, Object?>;
    final key = '${row['suite']}|${row['scenario']}|${row['fixtureId'] ?? ''}';
    if (seen.containsKey(key)) {
      stderr.writeln(
        '$path: duplicate suite+scenario+fixtureId row '
        '(suite=${row['suite']}, scenario=${row['scenario']}, '
        'fixtureId=${row['fixtureId']}) — split the reports before comparing.',
      );
      exitCode = 64;
      return false;
    }
    seen[key] = path;
  }
  return true;
}

Map<String, Map<String, Object?>> _index(final Map<String, Object?> report, final String? filter) {
  final rows = <String, Map<String, Object?>>{};
  for (final record in (report['results'] as List<Object?>?) ?? <Object?>[]) {
    final row = record! as Map<String, Object?>;
    final scenario = row['scenario']! as String;
    if (filter != null && !scenario.toLowerCase().contains(filter.toLowerCase())) {
      continue;
    }
    rows[scenario] = row;
  }
  return rows;
}

double _delta(final Object? before, final Object? after) {
  final base = (before as num?)?.toDouble() ?? 0;
  final cur = (after as num?)?.toDouble() ?? 0;
  if (base <= 0) {
    return 0;
  }
  return (cur - base) / base * 100;
}

String _ms(final Object? micros) => (((micros as num?)?.toDouble() ?? 0) / 1000).toStringAsFixed(2);

String _percent(final double delta) => '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}%';
