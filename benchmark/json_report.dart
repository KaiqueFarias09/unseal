// Structured JSON output for the unseal benchmarks (schemaVersion 1).
//
// The harness keeps ONE measurement code path; this module is the JSON
// output MODE on top of it. Every recorded scenario emits the exact
// contract fields, in a stable key order:
//
//     schemaVersion, suite, scenario, platform, sdk, commit,
//     fixtureId, sizeBytes, iterations, warmupIterations,
//     medianMicros, p95Micros, throughputPerSecond, checksum, status
//
// Extra fields (mean/min/max micros, note, error) are appended after
// the contract fields. Values never contain private file paths: the
// scenario name and optional fixtureId are the caller's labels.
//
// Output modes:
//   (none)            human table on stdout (default)
//   --json=<path>     human table on stdout + JSON report at <path>
//   --json            JSON report only on stdout (machine mode)
//
// The report is a single envelope object; `results` holds one record
// per benchmark row in registration order.

import 'dart:convert';
import 'dart:io';

/// Which JSON output the run produces.
enum JsonMode {
  /// Human table only (default).
  off,

  /// Human table plus a JSON report written to a file
  /// (`--json=<path>`).
  file,

  /// JSON report only, on stdout (`--json`).
  stdout,
}

/// The JSON output mode selected on the command line.
JsonMode jsonMode = JsonMode.off;

/// Destination path for [JsonMode.file].
String? jsonOutputPath;

/// Records accumulated during the run, in registration order.
final List<Map<String, Object?>> _records = <Map<String, Object?>>[];

/// Whether any recorded scenario failed (drives the envelope status).
bool _anyScenarioFailed = false;

/// Number of scenarios whose registration was attempted; a crash can
/// leave this larger than the recorded count.
int attemptedScenarios = 0;

/// An error that aborted the run, folded into the envelope status.
String? runError;

/// Whether [argument] is the JSON output flag; configures the module.
bool parseJsonArgument(final String argument) {
  if (argument == '--json') {
    jsonMode = JsonMode.stdout;
    return true;
  }
  if (argument.startsWith('--json=')) {
    final path = argument.substring('--json='.length);
    if (path.isEmpty) {
      return false;
    }
    jsonMode = JsonMode.file;
    jsonOutputPath = path;
    return true;
  }
  return false;
}

/// True when JSON-only stdout mode must suppress the human table.
bool get jsonSuppression => jsonMode == JsonMode.stdout;

/// Records one completed benchmark row (the contract record).
///
/// [checksum] is the harness sink value captured after the scenario —
/// proof the measured work ran; [warmup] counts the untimed warm-up /
/// calibration runs that preceded the timed samples.
void recordResult({
  required final String suite,
  required final String scenario,
  required final int iterations,
  required final int warmup,
  required final double medianMicros,
  required final double p95Micros,
  required final int checksum,
  final String fixtureId = '',
  final int sizeBytes = 0,
  final int? processedBytes,
  final double? meanMicros,
  final double? minMicros,
  final double? maxMicros,
  final String? note,
  final Object? error,
}) {
  final failed = error != null;
  if (failed) {
    _anyScenarioFailed = true;
  }
  final median = _round(medianMicros);
  // Map insertion order IS the stable key order of the contract.
  // sizeBytes is the LOGICAL input size; processedBytes records how
  // many bytes the timed body actually traversed (absent for whole-
  // input work, 0 for O(1) cache hits — never report a throughput
  // that was not really earned).
  _records.add(<String, Object?>{
    'schemaVersion': 1,
    'suite': suite,
    'scenario': scenario,
    'platform': platformId,
    'sdk': sdkVersion,
    'commit': commitId,
    'fixtureId': fixtureId,
    'sizeBytes': sizeBytes,
    'iterations': iterations,
    'warmupIterations': warmup,
    'medianMicros': median,
    'p95Micros': _round(p95Micros),
    'throughputPerSecond': median > 0 ? _round(1e6 / median) : 0.0,
    'checksum': checksum,
    'status': failed ? 'fail' : 'ok',
    'processedBytes': ?processedBytes,
    if (meanMicros != null) 'meanMicros': _round(meanMicros),
    if (minMicros != null) 'minMicros': _round(minMicros),
    if (maxMicros != null) 'maxMicros': _round(maxMicros),
    'note': ?note,
    'error': ?error,
  });
}

/// Builds the run envelope; key order is stable.
Map<String, Object?> _envelope() {
  final ok = !_anyScenarioFailed && runError == null;
  return <String, Object?>{
    'schemaVersion': 1,
    'suite': suiteName,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'platform': platformId,
    'sdk': sdkVersion,
    'commit': commitId,
    'quickMode': quickModeEnabled,
    'status': ok ? 'ok' : 'fail',
    if (runError != null) 'error': {'type': runError},
    'results': _records,
  };
}

/// Read access to the records collected so far (for tools that embed
/// the contract records into their own envelopes).
List<Map<String, Object?>> collectedRecords() => List.of(_records);

/// Clears all run state (records, failure flags, output mode). Test
/// support only: production entry points run one report per process.
void resetForTest() {
  _records.clear();
  _anyScenarioFailed = false;
  attemptedScenarios = 0;
  runError = null;
  jsonMode = JsonMode.off;
  jsonOutputPath = null;
}

/// Writes the accumulated report to the configured destination.
///
/// Call exactly once, at the end of the run (including crash paths via
/// `try`/`finally`), and only when [jsonMode] is enabled.
void writeJsonReport() {
  if (jsonMode == JsonMode.off) {
    return;
  }
  final payload = const JsonEncoder.withIndent('  ').convert(_envelope());
  switch (jsonMode) {
    case JsonMode.off:
      break;
    case JsonMode.stdout:
      stdout.writeln(payload);
    case JsonMode.file:
      final path = jsonOutputPath;
      if (path == null) {
        return;
      }
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('$payload\n', flush: true);
  }
}

// --- run identity, resolved lazily once per process ---

String? _suite;
String? _platform;
String? _sdk;
String? _commit;

/// The suite name: the `name:` of the pubspec.yaml at the working
/// directory; `unknown` when it cannot be read.
String get suiteName => _suite ??= _readPubspecName() ?? 'unknown';

/// Platform identifier, e.g. `macos-arm64` (never a hostname).
String get platformId => _platform ??= _computePlatform();

/// Dart (and, when driven through `flutter test`, Flutter) version.
String get sdkVersion => _sdk ??= _computeSdk();

/// HEAD commit of the working directory, or `unknown`.
String get commitId => _commit ??= _computeCommit();

/// Whether the suite runs in the quick mode (kept in the envelope so a
/// quick pass is never mistaken for a baseline).
bool quickModeEnabled = false;

String? _readPubspecName() {
  try {
    final file = File('pubspec.yaml');
    if (!file.existsSync()) {
      return null;
    }
    for (final line in file.readAsLinesSync()) {
      if (line.startsWith('name:')) {
        return line.substring('name:'.length).trim();
      }
    }
  } on Object {
    // Fall through to `unknown`.
  }
  return null;
}

String _computePlatform() {
  final operatingSystem = Platform.operatingSystem; // macos, linux, ...
  final version = Platform.version;
  final abiMatch = RegExp(r'on "([a-z0-9_]+)"').firstMatch(version);
  final abi = abiMatch?.group(1) ?? '';
  final arch = abi.contains('arm64')
      ? 'arm64'
      : abi.contains('x64')
      ? 'x64'
      : abi.replaceAll('_', '-');
  return arch.isEmpty ? operatingSystem : '$operatingSystem-$arch';
}

String _computeSdk() {
  final dart = 'Dart ${Platform.version.split(' ').first}';
  // `flutter test` drives the suite through the flutter_tester VM.
  final flutterTester = Platform.executable.contains('flutter_tester');
  return flutterTester ? '$dart (flutter test runner)' : dart;
}

String _computeCommit() {
  try {
    final result = Process.runSync('git', <String>[
      'rev-parse',
      'HEAD',
    ], workingDirectory: Directory.current.path);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
  } on Object {
    // Fall through to `unknown`.
  }
  return 'unknown';
}

double _round(final double value) => double.parse(value.toStringAsFixed(value.abs() < 100 ? 3 : 1));
