/// Fuzz campaign runner for the eLivre robustness suite.
///
/// Drives bounded fuzzing campaigns over deterministic generated
/// inputs (and, when present, the tracked corpus at
/// `test/resources/fuzz/`), executing every input inside a KILLABLE
/// worker isolate with a hard wall-clock deadline — the same
/// kill-on-timeout discipline as `benchmark/library_sweep.dart`. A
/// wedged parser is killed and classified as `timeout`; an isolate
/// death (stack overflow, VM abort) is classified as `crash`; a
/// process death at the same input twice classifies as `oom`.
///
/// Campaigns run for HOURS locally but stay strictly bounded by
/// `--iterations`; results stream into an atomic checkpoint so any
/// interruption resumes without re-running completed inputs.
///
/// Output is a schema-compatible JSON report (schemaVersion/suite/
/// scenario/fixtureId/status/error-type) written to the artifacts
/// folder — never into the repository.
///
/// Usage:
///
///     dart run tool/fuzz_runner.dart campaign \
///       [--family=all|zip|pdf|mobi|fb2|text|azw4|comic|images] \
///       [--iterations=<n-per-family>] [--seed=<n>] \
///       [--timeout-seconds=<n>] [--max-input-bytes=<n>] \
///       [--corpus] [--out=<file>] [--checkpoint=<file>] \
///       [--skip=<fixtureId>]... [--no-fail]
///
///     dart run tool/fuzz_runner.dart single \
///       --family=<f> --seed=<n> --index=<n> [--timeout-seconds=<n>]
library;

import 'dart:convert';
import 'dart:io';

import '../test/fuzz/harness/fuzz_corpus.dart';
import '../test/fuzz/harness/fuzz_inputs.dart';
import '../test/fuzz/harness/fuzz_invariants.dart';

void main(final List<String> arguments) async {
  if (arguments.isEmpty) {
    _usage();
    exitCode = 64;
    return;
  }
  final options = _Options.parse(arguments.skip(1));
  switch (arguments.first) {
    case 'campaign':
      await _campaign(options);
    case 'single':
      await _single(options);
    default:
      stderr.writeln('Unknown mode: ${arguments.first}');
      _usage();
      exitCode = 64;
  }
}

void _usage() {
  stderr.writeln(
    'usage: dart run tool/fuzz_runner.dart <campaign|single> [--family=<f>] '
    '[--iterations=<n>] [--seed=<n>] [--timeout-seconds=<n>] '
    '[--max-input-bytes=<n>] [--corpus] [--out=<file>] [--checkpoint=<file>] '
    '[--skip=<fixtureId>] [--no-fail]',
  );
}

/// Parsed command-line options.
final class _Options {
  _Options.parse(final Iterable<String> arguments) {
    for (final argument in arguments) {
      final value = argument.contains('=') ? argument.split('=').skip(1).join('=') : null;
      if (argument.startsWith('--family=')) {
        family = value;
      } else if (argument.startsWith('--iterations=')) {
        iterations = int.tryParse(value ?? '') ?? iterations;
      } else if (argument.startsWith('--index=')) {
        singleIndex = int.tryParse(value ?? '') ?? singleIndex;
      } else if (argument.startsWith('--seed=')) {
        seed = int.tryParse(value ?? '') ?? seed;
      } else if (argument.startsWith('--timeout-seconds=')) {
        timeoutSeconds = int.tryParse(value ?? '') ?? timeoutSeconds;
      } else if (argument.startsWith('--max-input-bytes=')) {
        maxInputBytes = int.tryParse(value ?? '') ?? maxInputBytes;
      } else if (argument == '--corpus') {
        includeCorpus = true;
      } else if (argument.startsWith('--out=')) {
        out = value;
      } else if (argument.startsWith('--checkpoint=')) {
        checkpoint = value;
      } else if (argument.startsWith('--skip=')) {
        skips.add(value ?? '');
      } else if (argument == '--no-fail') {
        failOnDefect = false;
      }
    }
  }

  String? family;
  int iterations = 200;
  int singleIndex = 0;
  int seed = 20260913;
  int timeoutSeconds = 60;
  int maxInputBytes = 8 << 20;
  bool includeCorpus = false;
  String? out;
  String? checkpoint;
  final List<String> skips = <String>[];
  bool failOnDefect = true;
}

// --- campaign ---

Future<void> _campaign(final _Options options) async {
  final families = _resolveFamilies(options.family);
  final timeout = Duration(seconds: options.timeoutSeconds);
  final work = <_WorkItem>[];
  for (final family in families) {
    for (var index = 0; index < options.iterations; index++) {
      final input = generateFuzzInput(family: family, seed: options.seed, index: index);
      if (input.bytes.length > options.maxInputBytes) continue;
      work.add(_WorkItem(input: input, scenario: _scenarioOf(family, index)));
    }
  }
  if (options.includeCorpus) {
    final root = fuzzCorpusRoot();
    for (final file in fuzzCorpusFiles(limit: 512)) {
      final id = root == null ? file.path : fuzzCorpusFixtureId(file, root);
      work.add(
        _WorkItem(
          input: FuzzInput(fixtureId: id, family: FuzzFamily.text, bytes: file.readAsBytesSync()),
          scenario: 'corpus',
        ),
      );
    }
  }

  final checkpoint = _Checkpoint.load(options.checkpoint);
  final pending = work.where((final item) => !checkpoint.has(item.input.fixtureId)).toList();
  stdout.writeln(
    'campaign: ${work.length} inputs, ${work.length - pending.length} checkpointed, '
    '${pending.length} pending · families=${families.map((f) => f.name).join(',')} '
    '· seed=${options.seed} · timeout=${options.timeoutSeconds}s',
  );

  final results = <String, Map<String, Object?>>{};
  for (final item in work) {
    final existing = checkpoint.get(item.input.fixtureId);
    if (existing != null) {
      results[item.input.fixtureId] = existing;
      continue;
    }
    if (options.skips.contains(item.input.fixtureId)) {
      final record = _record(
        item,
        status: 'oom',
        errorType: 'ProcessDeathSkipped',
        detail: 'skipped via --skip after repeated process death',
        durationMs: 0,
      );
      results[item.input.fixtureId] = record;
      await checkpoint.record(item.input.fixtureId, record);
      stdout.writeln('skipped(oom) ${item.input.fixtureId}');
      continue;
    }
    stderr.writeln('attempt ${item.input.fixtureId}');
    final watch = Stopwatch()..start();
    final verdict = await runBoundedParse(item.input.bytes, timeout: timeout);
    watch.stop();
    final record = _recordFromVerdict(item, verdict, watch.elapsedMilliseconds);
    results[item.input.fixtureId] = record;
    await checkpoint.record(item.input.fixtureId, record);
    if (verdict.status != FuzzStatus.ok && verdict.status != FuzzStatus.skipped) {
      stdout.writeln(
        '${verdict.status.name.toUpperCase().padRight(7)} ${item.input.fixtureId} '
        '${verdict.defectSummary ?? ''} ${watch.elapsedMilliseconds}ms '
        '${item.input.bytes.length}B',
      );
    }
  }

  final report = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'fuzz-campaign',
    'suite': 'e_livre-fuzz',
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'platform': _platformId,
    'sdk': _sdkVersion,
    'commit': _commitId,
    'config': <String, Object?>{
      'families': families.map((final f) => f.name).toList(),
      'iterations': options.iterations,
      'seed': options.seed,
      'timeoutSeconds': options.timeoutSeconds,
      'maxInputBytes': options.maxInputBytes,
      'corpus': options.includeCorpus,
    },
    'totals': _totals(results.values.toList()),
    'results': results.values.toList(),
  };
  _writeJson(options.out ?? 'artifacts/fuzz/fuzz-campaign.json', report);

  final totals = _totals(results.values.toList());
  final defects =
      totals['untyped']! + totals['crash']! + totals['timeout']! + totals['oom']!;
  stdout.writeln('campaign done: $totals');
  if (defects > 0 && options.failOnDefect) {
    exitCode = 1;
  }
}

String _scenarioOf(final FuzzFamily family, final int index) {
  const strategies = <String>['mutated-seed', 'magic-random', 'structural-hostile', 'pure-random'];
  final strategy = strategies[index % 4];
  return '${family.name}/$strategy';
}

Map<String, Object?> _recordFromVerdict(
  final _WorkItem item,
  final FuzzVerdict verdict,
  final int durationMs,
) => _record(
  item,
  status: verdict.status.name,
  errorType: verdict.defectSummary ?? _firstErrorType(verdict),
  detail: null,
  durationMs: durationMs,
  verdict: verdict,
);

String? _firstErrorType(final FuzzVerdict verdict) {
  for (final entry in FuzzEntryPoint.values) {
    final verdictEntry = verdict.entries[entry];
    if (verdictEntry == null) continue;
    if (verdictEntry.errorType != null) return verdictEntry.errorType;
  }
  return null;
}

Map<String, Object?> _record(
  final _WorkItem item, {
  required final String status,
  required final String? errorType,
  required final String? detail,
  required final int durationMs,
  final FuzzVerdict? verdict,
}) => <String, Object?>{
  'schemaVersion': 1,
  'suite': 'e_livre-fuzz',
  'scenario': item.scenario,
  'fixtureId': item.input.fixtureId,
  'status': status,
  'errorType': ?errorType,
  if (detail != null) 'error': <String, Object?>{'type': errorType ?? '', 'message': detail},
  'family': item.input.family.name,
  'inputBytes': item.input.bytes.length,
  'durationMs': durationMs,
  if (verdict != null) 'entries': verdict.toJson()['entries'],
};

Map<String, int> _totals(final List<Map<String, Object?>> results) {
  final counts = <String, int>{
    'total': results.length,
    'ok': 0,
    'typed': 0,
    'untyped': 0,
    'crash': 0,
    'timeout': 0,
    'oom': 0,
    'skipped': 0,
  };
  for (final result in results) {
    final status = result['status'] as String? ?? 'skipped';
    counts[status] = (counts[status] ?? 0) + 1;
  }
  return counts;
}

// --- single ---

Future<void> _single(final _Options options) async {
  final family = _resolveFamilies(options.family).first;
  final input = generateFuzzInput(family: family, seed: options.seed, index: options.singleIndex);
  stdout.writeln('single ${input.fixtureId} bytes=${input.bytes.length}');
  final watch = Stopwatch()..start();
  final verdict = await runBoundedParse(
    input.bytes,
    timeout: Duration(seconds: options.timeoutSeconds),
  );
  watch.stop();
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'fixtureId': input.fixtureId,
      'inputBytes': input.bytes.length,
      'durationMs': watch.elapsedMilliseconds,
      'verdict': verdict.toJson(),
    }),
  );
  if (verdict.isDefect && options.failOnDefect) exitCode = 1;
}

// --- helpers ---

List<FuzzFamily> _resolveFamilies(final String? name) {
  if (name == null || name == 'all') return FuzzFamily.all;
  return <FuzzFamily>[FuzzFamily.values.firstWhere((final f) => f.name == name)];
}

final class _WorkItem {
  _WorkItem({required this.input, required this.scenario});

  final FuzzInput input;
  final String scenario;
}

/// Writes a JSON payload atomically: temp file on the SAME volume,
/// then rename, so a crash can never leave a torn report.
void _writeJson(final String path, final Map<String, Object?> payload) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  final tmp = File('${file.path}.tmp');
  tmp.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(payload)}\n', flush: true);
  tmp.renameSync(file.path);
}

String get _platformId {
  final abiMatch = RegExp(r'on "([a-z0-9_]+)"').firstMatch(Platform.version);
  final abi = abiMatch?.group(1) ?? '';
  final arch = abi.contains('arm64')
      ? 'arm64'
      : abi.contains('x64')
      ? 'x64'
      : abi.replaceAll('_', '-');
  return arch.isEmpty ? Platform.operatingSystem : '${Platform.operatingSystem}-$arch';
}

String get _sdkVersion => 'Dart ${Platform.version.split(' ').first}';

String get _commitId {
  try {
    final result = Process.runSync('git', <String>[
      'rev-parse',
      'HEAD',
    ], workingDirectory: Directory.current.path);
    if (result.exitCode == 0) return (result.stdout as String).trim();
  } on Object {
    // Fall through to `unknown`.
  }
  return 'unknown';
}

/// Crash-safe campaign checkpoint; atomically rewritten after every
/// recorded input so interrupted campaigns resume.
final class _Checkpoint {
  _Checkpoint(this.path, this.completed);

  final String? path;
  final Map<String, Map<String, Object?>> completed;
  Future<void> _chain = Future.value();

  static _Checkpoint load(final String? path) {
    if (path == null) return _Checkpoint(null, <String, Map<String, Object?>>{});
    final file = File(path);
    if (file.existsSync()) {
      try {
        final decoded = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        return _Checkpoint(
          path,
          (decoded['completed'] as Map<String, Object?>).cast<String, Map<String, Object?>>(),
        );
      } on Object {
        stderr.writeln('checkpoint unreadable — starting fresh.');
      }
    }
    return _Checkpoint(path, <String, Map<String, Object?>>{});
  }

  bool has(final String fixtureId) => completed.containsKey(fixtureId);

  Map<String, Object?>? get(final String fixtureId) => completed[fixtureId];

  Future<void> record(final String fixtureId, final Map<String, Object?> record) {
    if (path == null) return Future.value();
    _chain = _chain.then((_) {
      completed[fixtureId] = record;
      final file = File(path!);
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'schemaVersion': 1,
          'kind': 'fuzz-campaign-checkpoint',
          'completed': completed,
        })}\n',
        flush: true,
      );
      tmp.renameSync(file.path);
    });
    return _chain;
  }
}
