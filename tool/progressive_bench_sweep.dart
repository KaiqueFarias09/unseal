// Sweep driver for the progressive-reading opening probe. Runs
// tool/progressive_bench.dart ONE CHILD PROCESS PER MEASUREMENT —
// serially, so RSS numbers never compete — over a list of books x
// modes x repetitions, with the mode order ROTATED each repetition so
// every mode leads equally often (the A/B alternation rule from the
// baseline methodology). Aggregates min/median/p90/p95/max per
// (book, mode) into one JSON report; t_open_ms, t_first_content_ms,
// rss_delta_mb and rss_peak_mb are aggregated when the child reported
// them. The child self-samples its RSS series (`ps -o rss=` every
// ~10 ms from a sampling isolate — see progressive_bench.dart), so the
// sweep inherits rss_series_mb / rss_peak_mb through the child's JSON
// line while keeping one fresh process per measurement.
//
//     dart run tool/progressive_bench_sweep.dart \
//       --book=<path> [--book=<path> ...] \
//       [--mode=<m> ...] [--repetitions=<n>] \
//       [--password=x] [--timeout-seconds=<n>] \
//       [--library=<root>] [--out=<file>]
//
// Books come from `--book` arguments and/or a private library root:
// `--library=<root>` or the `ELIVRE_BENCH_LIBRARY` env var (with
// `UNSEAL_BENCH_LIBRARY` / `UNSEAL_CALIBRE_LIBRARY` accepted as
// fallbacks for operator convenience). The private corpus is strictly
// opt-in and scanned with the READ-ONLY scanLibrary helper from
// benchmark/library_sweep.dart; only book-candidate files run. Paths
// never reach the report — the children report opaque path-hash ids
// (see progressive_bench.dart for the id caveat).
//
// Default modes are the implemented full-parse modes; session modes
// can be requested explicitly. A child that exits nonzero but still
// printed its JSON record keeps its own typed status ("unsupported"
// for session modes over pdf/cbr until those waves land, "fail",
// "timeout") and aggregates in the failure cell for its (book, mode).
// Default repetitions: 5. Default report:
// build/progressive-open-sweep.json (git-ignored).
//
// MEASUREMENT HYGIENE: run this alone — no builds, no browsers, no
// other benchmarks on the same machine. One run = one envelope.

import 'dart:convert';
import 'dart:io';

import '../benchmark/json_report.dart' as contract;
import '../benchmark/library_sweep.dart' show scanLibrary;

/// Modes swept when none are given (order = rotation base order).
const List<String> defaultModes = ['parse-sync', 'read-isolate', 'read-file-isolate'];

Future<void> main(final List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options.books.isEmpty && options.libraryRoot == null) {
    stderr.writeln(
      'no books: pass --book=<path> (repeatable) and/or --library=<root> '
      '(or set ELIVRE_BENCH_LIBRARY). The private corpus is opt-in only.',
    );
    exitCode = 64;
    return;
  }
  if (options.modes.isEmpty) {
    stderr.writeln('no modes: pass --mode=<m> from the probe tool\'s modes');
    exitCode = 64;
    return;
  }

  final bookPaths = List.of(options.books);
  if (options.libraryRoot != null) {
    final scan = scanLibrary(options.libraryRoot!, <String, String>{});
    final candidates =
        scan.files
            .where((final file) => file.isBookCandidate)
            .map((final file) => scan.pathFor[file.id]!)
            .toList()
          ..sort();
    stdout.writeln(
      'library ${options.libraryRoot}: ${scan.files.length} files scanned, '
      '${candidates.length} book candidates',
    );
    bookPaths.addAll(candidates);
  }
  if (bookPaths.isEmpty) {
    stderr.writeln('library yielded no book candidates; nothing to sweep');
    exitCode = 64;
    return;
  }

  stdout.writeln(
    'sweep: ${bookPaths.length} books x ${options.modes.length} modes x '
    '${options.repetitions} repetitions (mode order rotates per repetition)',
  );

  final samples = <String, _SampleSet>{};
  final failures = <String, _FailureSet>{};
  var runs = 0;
  for (var repetition = 0; repetition < options.repetitions; repetition++) {
    // Rotation: repetition 0 runs A,B,C — repetition 1 runs B,C,A — so
    // ambient drift (thermal, caches) cannot favor one mode.
    final rotated = [
      for (var i = 0; i < options.modes.length; i++)
        options.modes[(repetition + i) % options.modes.length],
    ];
    for (final book in bookPaths) {
      final absolute = File(book).absolute.path;
      if (!File(absolute).existsSync()) {
        stderr.writeln('skipping missing book: $book');
        continue;
      }
      for (final mode in rotated) {
        runs++;
        final record = await _spawnProbe(
          options.probeToolPath,
          mode,
          absolute,
          password: options.password,
          timeout: Duration(seconds: options.timeoutSeconds),
        );
        final key = '${record['bookId'] ?? 'unknown'}|$mode';
        final status = record['status'];
        if (status == 'ok') {
          samples.putIfAbsent(key, _SampleSet.new).add(record);
        } else {
          failures.putIfAbsent(key, _FailureSet.new).add(record);
          stderr.writeln(
            'run $repetition: $mode ${record['bookId']} -> $status '
            '${record['error']}',
          );
        }
        stdout.writeln(
          '[$runs] rep ${repetition + 1} $mode ${record['bookId']} '
          't_open=${record['t_open_ms']}ms '
          't_first=${record['t_first_content_ms']}ms '
          'rss_delta=${record['rss_delta_mb']}MB '
          'rss_peak=${record['rss_peak_mb']}MB $status',
        );
      }
    }
  }

  final report = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'progressive-open-sweep',
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'platform': contract.platformId,
    'sdk': contract.sdkVersion,
    'commit': contract.commitId,
    'repetitions': options.repetitions,
    'modeOrder': 'rotated by repetition so each mode leads equally often',
    'modes': options.modes,
    'runs': runs,
    'results': [
      for (final key in samples.keys.toList()..sort()) samples[key]!.toRecord(key, failures[key]),
      for (final key in failures.keys.toList()..sort())
        if (!samples.containsKey(key)) failures[key]!.toRecord(key),
    ],
  };
  final outPath = options.out;
  final file = File(outPath);
  file.parent.createSync(recursive: true);
  final tmp = File('$outPath.tmp');
  tmp.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n', flush: true);
  tmp.renameSync(outPath);
  stdout.writeln('sweep done: $runs runs -> $outPath');
}

Future<Map<String, Object?>> _spawnProbe(
  final String probeToolPath,
  final String mode,
  final String absoluteBookPath, {
  required final String password,
  required final Duration timeout,
}) async {
  final arguments = [
    probeToolPath,
    '--mode=$mode',
    '--book=$absoluteBookPath',
    if (password.isNotEmpty) '--password=$password',
  ];
  try {
    final process = await Process.start(Platform.resolvedExecutable, arguments);
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    // A wedged probe is killed so the sweep cannot stall; the timed-out
    // run aggregates as `timeout`, never silently as success.
    var timedOut = false;
    final exitCode = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    final probeStdout = await stdoutFuture;
    final probeStderr = await stderrFuture;
    if (timedOut) {
      return <String, Object?>{
        'status': 'timeout',
        'bookId': _bookIdFrom(probeStdout),
        'error': {'type': 'Timeout'},
      };
    }
    if (exitCode != 0) {
      // The probe prints its full JSON record even on failure, so the
      // typed status ("unsupported", "fail", error type/message) comes
      // straight from the child when available; the constructed record
      // below is only the fallback for a child that died without one.
      final typed = _recordFrom(probeStdout);
      if (typed != null) {
        return typed;
      }
      return <String, Object?>{
        'status': exitCode == 69 ? 'unimplemented' : 'fail',
        'bookId': _bookIdFrom(probeStdout),
        'error': _errorFrom(probeStderr),
      };
    }
    // The probe's stdout contract is ONE compact JSON line.
    final typed = _recordFrom(probeStdout);
    if (typed != null) {
      return typed;
    }
    return <String, Object?>{
      'status': 'fail',
      'bookId': null,
      'error': {'type': 'MissingJson', 'message': 'probe printed no JSON object'},
    };
  } on Object catch (error) {
    return <String, Object?>{
      'status': 'fail',
      'bookId': null,
      'error': {'type': error.runtimeType.toString(), 'message': '$error'},
    };
  }
}

/// Parses the probe's ONE compact JSON stdout line into its record, or
/// null when the child printed no parseable record (so callers can
/// fall back to a constructed one).
Map<String, Object?>? _recordFrom(final String probeStdout) {
  final line = probeStdout.trim();
  if (!line.startsWith('{')) {
    return null;
  }
  try {
    final record = jsonDecode(line);
    if (record is Map<String, Object?> && record['status'] is String) {
      return record;
    }
    return null;
  } on Object {
    return null;
  }
}

String? _bookIdFrom(final String probeStdout) {
  final line = probeStdout.trim();
  if (!line.startsWith('{')) {
    return null;
  }
  try {
    return (jsonDecode(line) as Map<String, Object?>)['bookId'] as String?;
  } on Object {
    return null;
  }
}

Map<String, Object?> _errorFrom(final String probeStderr) {
  final lines = probeStderr.trim().split('\n');
  return {'type': 'ProbeExit', 'message': lines.last};
}

/// One (book, mode) cell: the timed samples collected across
/// repetitions, kept raw for the report and summarized on demand.
final class _SampleSet {
  final List<double> tOpenMs = [];
  final List<double> tFirstContentMs = [];
  final List<double> rssDeltaMb = [];
  final List<double> rssPeakMb = [];
  final List<double> tWarmMs = [];
  final List<double> rssWarmDeltaMb = [];
  final List<int> bytesValues = [];
  final List<String> bookFormats = [];

  void add(final Map<String, Object?> record) {
    _addDouble(tOpenMs, record['t_open_ms']);
    _addDouble(tFirstContentMs, record['t_first_content_ms']);
    _addDouble(rssDeltaMb, record['rss_delta_mb']);
    _addDouble(rssPeakMb, record['rss_peak_mb']);
    _addDouble(tWarmMs, record['t_warm_ms']);
    _addDouble(rssWarmDeltaMb, record['rss_warm_delta_mb']);
    final bytes = record['bytes'];
    if (bytes is int) {
      bytesValues.add(bytes);
    }
    final format = record['bookFormat'];
    if (format is String && !bookFormats.contains(format)) {
      bookFormats.add(format);
    }
  }

  void _addDouble(final List<double> sink, final Object? value) {
    if (value is num) {
      sink.add(value.toDouble());
    }
  }

  Map<String, Object?> toRecord(final String key, final _FailureSet? failures) {
    final parts = key.split('|');
    tOpenMs.sort();
    return <String, Object?>{
      'bookId': parts[0],
      'mode': parts[1],
      if (bookFormats.isNotEmpty) 'bookFormat': bookFormats.first,
      if (bytesValues.isNotEmpty) 'bytes': bytesValues.first,
      'ok': tOpenMs.length,
      'fail': failures?.count ?? 0,
      't_open_ms': _summary(tOpenMs),
      if (tFirstContentMs.isNotEmpty) 't_first_content_ms': _summary(tFirstContentMs..sort()),
      'rss_delta_mb': _summary(rssDeltaMb..sort()),
      // Peak of the child's whole-run RSS series, per repetition; the
      // campaign's peak-memory A/B reads this (not rss_delta_mb).
      if (rssPeakMb.isNotEmpty) 'rss_peak_mb': _summary(rssPeakMb..sort()),
      if (tWarmMs.isNotEmpty) 't_warm_ms': _summary(tWarmMs..sort()),
      if (rssWarmDeltaMb.isNotEmpty) 'rss_warm_delta_mb': _summary(rssWarmDeltaMb..sort()),
    };
  }
}

/// One (book, mode) cell that never produced an ok sample.
final class _FailureSet {
  final List<Map<String, Object?>> records = [];

  int get count => records.length;

  void add(final Map<String, Object?> record) {
    records.add(record);
  }

  Map<String, Object?> toRecord(final String key) {
    final parts = key.split('|');
    final statuses = <String, int>{};
    for (final record in records) {
      final status = '${record['status']}';
      statuses[status] = (statuses[status] ?? 0) + 1;
    }
    return <String, Object?>{
      'bookId': parts[0],
      'mode': parts[1],
      'ok': 0,
      'fail': count,
      'statuses': statuses,
    };
  }
}

Map<String, Object?> _summary(final List<double> sorted) {
  if (sorted.isEmpty) {
    return <String, Object?>{'min': 0.0, 'median': 0.0, 'p90': 0.0, 'p95': 0.0, 'max': 0.0};
  }
  return <String, Object?>{
    'min': sorted.first,
    'median': sorted[sorted.length ~/ 2],
    'p90': _percentile(sorted, 0.90),
    'p95': _percentile(sorted, 0.95),
    'max': sorted.last,
    'samples': List.of(sorted),
  };
}

/// Nearest-rank-ish percentile over a sorted list (same convention the
/// p90 used before: closest index, clamped to the list).
double _percentile(final List<double> sorted, final double fraction) =>
    sorted[((sorted.length - 1) * fraction).round().clamp(0, sorted.length - 1)];

final class _Options {
  List<String> books = [];
  List<String> modes = [];
  String? libraryRoot;
  String password = '';
  int repetitions = 5;
  int timeoutSeconds = 300;
  String out = 'build/progressive-open-sweep.json';

  static _Options parse(final List<String> arguments) {
    final options = _Options();
    for (final argument in arguments) {
      final value = argument.contains('=') ? argument.split('=').skip(1).join('=') : null;
      if (argument.startsWith('--book=') && value != null) {
        options.books.add(value);
      } else if (argument.startsWith('--mode=') && value != null) {
        options.modes.add(value);
      } else if (argument.startsWith('--library=') && value != null) {
        options.libraryRoot = value;
      } else if (argument.startsWith('--password=') && value != null) {
        options.password = value;
      } else if (argument.startsWith('--repetitions=')) {
        options.repetitions = int.tryParse(value ?? '') ?? 5;
      } else if (argument.startsWith('--timeout-seconds=')) {
        options.timeoutSeconds = int.tryParse(value ?? '') ?? 300;
      } else if (argument.startsWith('--out=') && value != null) {
        options.out = value;
      }
    }
    if (options.modes.isEmpty) {
      options.modes = List.of(defaultModes);
    }
    options.libraryRoot ??= _libraryFromEnvironment();
    return options;
  }

  static String? _libraryFromEnvironment() {
    final candidate =
        Platform.environment['ELIVRE_BENCH_LIBRARY'] ??
        Platform.environment['UNSEAL_BENCH_LIBRARY'] ??
        Platform.environment['UNSEAL_CALIBRE_LIBRARY'];
    if (candidate == null || !Directory(candidate).existsSync()) {
      return null;
    }
    return candidate;
  }

  /// The probe script next to this file, resolved to an absolute path so
  /// the child's working directory never matters. Children run on the
  /// same VM binary (`Platform.resolvedExecutable`) which picks up this
  /// package's `.dart_tool/package_config.json` — no `dart run`
  /// re-resolution cost per spawn.
  String get probeToolPath {
    final script = Platform.script.toFilePath();
    if (script.endsWith('progressive_bench_sweep.dart')) {
      final sibling = File('${File(script).parent.path}/progressive_bench.dart');
      if (sibling.existsSync()) {
        return sibling.absolute.path;
      }
    }
    return File('tool/progressive_bench.dart').absolute.path;
  }
}
