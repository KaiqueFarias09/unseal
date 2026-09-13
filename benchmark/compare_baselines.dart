// Compare two schemaVersion-1 benchmark reports (any suite).
//
//     dart run benchmark/compare_baselines.dart <baseline.json> <current.json> [--filter=<text>]
//
// Joins the two reports on `scenario` and prints the median / p95
// delta per matching row. Comparison is strictly informational — the
// numbers are machine-dependent, so this tool deliberately implements
// no pass/fail gates; only same-machine, same-commit-ish runs should
// be compared. Rows present in only one report are listed as added /
// removed.

import 'dart:convert';
import 'dart:io';

Future<void> main(final List<String> arguments) async {
  final paths = arguments.where((final a) => !a.startsWith('--')).toList();
  final filterArgument = arguments.where((final a) => a.startsWith('--filter=')).firstOrNull;
  if (paths.length != 2 || filterArgument == null && arguments.contains('--filter')) {
    _usage();
    exitCode = 64;
    return;
  }
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
    if (medianDelta > 0.25) {
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
    stdout.writeln('rows >25% slower median (informational, no gate):');
    for (final row in slower) {
      stdout.writeln('  $row');
    }
  }
}

void _usage() {
  stderr.writeln(
    'usage: dart run benchmark/compare_baselines.dart <baseline.json> '
    '<current.json> [--filter=<text>]',
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
