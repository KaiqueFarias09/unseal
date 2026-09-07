// Timing harness for the public eLivre benchmarks.
//
// Every benchmark runs with an auto-calibrated iteration count so the
// whole suite stays fast: cheap operations are batched (one batch is
// timed and divided by the inner count), expensive ones are timed per
// iteration and summarized with median / mean / p95.
//
// Benchmark bodies return their last result so the harness can fold it
// into a checksum — keeping the VM from ever discarding the work.

import 'dart:io';

/// The action a benchmark measures. Returns its last result so the
/// harness can consume it.
typedef BenchmarkAction = Object? Function();

/// An asynchronous benchmark action (isolates, futures, ...).
typedef AsyncBenchmarkAction = Future<Object?> Function();

/// A measured sample set of one benchmark (microseconds per run).
final class BenchmarkResult {
  /// Creates a result over the collected [samples].
  BenchmarkResult({
    required this.name,
    required this.iterations,
    required this.note,
    required final List<double> samples,
  }) : samples = _sortedCopy(samples);

  /// The display name of the benchmark.
  final String name;

  /// How many times the action ran in total (inner runs included for
  /// batched benchmarks).
  final int iterations;

  /// Optional trailing note shown in the extra column.
  final String? note;

  /// Sorted durations of every timed run, in microseconds.
  final List<double> samples;

  static List<double> _sortedCopy(final List<double> list) {
    final copy = list.toList()..sort();
    return copy;
  }

  /// Middle sample; robust against GC pauses.
  double get median => _percentile(50);

  /// Arithmetic mean of all samples.
  double get mean =>
      samples.isEmpty ? 0 : samples.fold<double>(0, _add) / samples.length;

  /// 95th percentile sample.
  double get p95 => _percentile(95);

  /// Fastest sample.
  double get min => samples.isEmpty ? 0 : samples.first;

  /// Slowest sample.
  double get max => samples.isEmpty ? 0 : samples.last;

  /// Operations per second derived from [mean].
  double get opsPerSecond => mean <= 0 ? 0 : 1e6 / mean;

  static double _add(final double a, final double b) => a + b;

  double _percentile(final int p) {
    if (samples.isEmpty) {
      return 0;
    }
    final index = ((p / 100) * (samples.length - 1)).round();
    return samples[index.clamp(0, samples.length - 1)];
  }
}

/// Substring filter applied to `<group> — <name>`; `null` runs all.
String? benchmarkFilter;

/// Shrinks budgets and sample counts for a fast smoke pass.
bool quickMode = false;

int _sink = 0;

/// Checksum over every consumed benchmark result; printed at the end
/// as proof the measured work was really performed.
int get sinkChecksum => _sink;

/// Whether [name] passes the active [benchmarkFilter].
bool matchesFilter(final String name) {
  final filter = benchmarkFilter;
  return filter == null || name.toLowerCase().contains(filter.toLowerCase());
}

/// Measures [action], auto-calibrating the iteration count against
/// [budget].
BenchmarkResult runBenchmark(
  final String name,
  final BenchmarkAction action, {
  final String? note,
  final Duration? budget,
}) {
  final effectiveBudget = budget ?? _defaultBudget();
  for (var i = 0; i < 3; i++) {
    _consume(action()); // Warm-up (JIT tiering).
  }
  // Calibrate on the fastest of a few probes: the first probes of a
  // run can still hit JIT/GC noise and would overestimate the cost.
  var probeMicros = double.infinity;
  final probe = Stopwatch();
  for (var i = 0; i < 3; i++) {
    probe
      ..reset()
      ..start();
    _consume(action());
    probe.stop();
    final elapsed = probe.elapsedMicroseconds;
    if (elapsed < probeMicros) {
      probeMicros = elapsed.toDouble();
    }
  }

  if (probeMicros < 200) {
    return _runBatched(name, action, effectiveBudget, probeMicros, note);
  }
  return _runPerIteration(name, action, effectiveBudget, probeMicros, note);
}

BenchmarkResult _runBatched(
  final String name,
  final BenchmarkAction action,
  final Duration budget,
  final double probeMicros,
  final String? note,
) {
  final inner = (2000 / (probeMicros < 0.5 ? 0.5 : probeMicros)).ceil();
  final samples = <double>[];
  var runs = 0;
  final total = Stopwatch()..start();
  final batch = Stopwatch();
  do {
    batch
      ..reset()
      ..start();
    for (var i = 0; i < inner; i++) {
      _consume(action());
    }
    batch.stop();
    samples.add(batch.elapsedMicroseconds / inner);
    runs += inner;
  } while (total.elapsed < budget && samples.length < 500);
  return BenchmarkResult(
    name: name,
    iterations: runs,
    note: note,
    samples: samples,
  );
}

BenchmarkResult _runPerIteration(
  final String name,
  final BenchmarkAction action,
  final Duration budget,
  final double probeMicros,
  final String? note,
) {
  final minimum = probeMicros > 1e6 ? 3 : 5;
  final iterations =
      (budget.inMicroseconds / (probeMicros < 1 ? 1 : probeMicros))
          .round()
          .clamp(minimum, 100000);
  final samples = <double>[];
  final watch = Stopwatch();
  for (var i = 0; i < iterations; i++) {
    watch
      ..reset()
      ..start();
    _consume(action());
    watch.stop();
    samples.add(watch.elapsedMicroseconds.toDouble());
  }
  return BenchmarkResult(
    name: name,
    iterations: iterations,
    note: note,
    samples: samples,
  );
}

/// Measures an asynchronous [action] a fixed number of times — used
/// for isolate-based entry points where each run is expensive.
Future<BenchmarkResult> runAsyncBenchmark(
  final String name,
  final AsyncBenchmarkAction action, {
  final int? iterations,
  final String? note,
}) async {
  final count = iterations ?? (quickMode ? 3 : 5);
  _consume(await action()); // Warm-up.
  final samples = <double>[];
  final watch = Stopwatch();
  for (var i = 0; i < count; i++) {
    watch
      ..reset()
      ..start();
    _consume(await action());
    watch.stop();
    samples.add(watch.elapsedMicroseconds.toDouble());
  }
  return BenchmarkResult(
    name: name,
    iterations: count,
    note: note,
    samples: samples,
  );
}

/// Measures the *first* access to a lazy member (e.g. `Book.statistics`
/// or `MobiBook.chapters`).
///
/// A fresh instance is created before every timed access (untimed), so
/// the samples isolate the memoized computation from the parse cost.
BenchmarkResult runFirstAccessBenchmark<T>(
  final String name,
  final int count,
  final T Function() createInstance,
  final Object? Function(T instance) access, {
  final String? note,
}) {
  final instances = quickMode ? (count / 2).ceil() : count;
  access(createInstance()); // Warm-up on a throw-away instance.
  final samples = <double>[];
  final watch = Stopwatch();
  for (var i = 0; i < instances; i++) {
    final instance = createInstance();
    watch
      ..reset()
      ..start();
    final result = access(instance);
    watch.stop();
    _consume(result);
    samples.add(watch.elapsedMicroseconds.toDouble());
  }
  return BenchmarkResult(
    name: name,
    iterations: instances,
    note: note,
    samples: samples,
  );
}

void _consume(final Object? value) => _sink = Object.hash(_sink, value);

Duration _defaultBudget() => quickMode
    ? const Duration(milliseconds: 300)
    : const Duration(milliseconds: 1500);

/// Collects the benchmarks of one group, printing the group header
/// lazily before the first benchmark that matches the filter.
final class BenchmarkGroup {
  /// Creates a group titled [title].
  BenchmarkGroup(this.title);

  /// The group title; part of the name used for [benchmarkFilter].
  final String title;

  bool _headerPrinted = false;

  /// Adds a synchronous benchmark to the group.
  void add(
    final String name,
    final BenchmarkAction action, {
    final int? inputBytes,
    final String? note,
  }) {
    if (!matchesFilter('$title — $name')) {
      return;
    }
    _printHeaderOnce();
    final result = runBenchmark(name, action, note: note);
    printResult(result, inputBytes: inputBytes);
  }

  /// Adds an asynchronous benchmark to the group.
  Future<void> addAsync(
    final String name,
    final AsyncBenchmarkAction action, {
    final int? inputBytes,
    final String? note,
  }) async {
    if (!matchesFilter('$title — $name')) {
      return;
    }
    _printHeaderOnce();
    final result = await runAsyncBenchmark(name, action, note: note);
    printResult(result, inputBytes: inputBytes);
  }

  /// Adds a lazy first-access benchmark to the group.
  void addFirstAccess<T>(
    final String name,
    final int count,
    final T Function() createInstance,
    final Object? Function(T instance) access, {
    final String? note,
  }) {
    if (!matchesFilter('$title — $name')) {
      return;
    }
    _printHeaderOnce();
    final result = runFirstAccessBenchmark<T>(
      name,
      count,
      createInstance,
      access,
      note: note,
    );
    printResult(result);
  }

  void _printHeaderOnce() {
    if (_headerPrinted) {
      return;
    }
    _headerPrinted = true;
    printGroupHeader(title);
  }
}

/// Prints the banner shown once at the start of a run.
void printBanner() {
  stdout
    ..writeln('eLivre public API benchmarks')
    ..writeln(
      'Dart ${Platform.version.split(' ').first} · '
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    )
    ..writeln(
      'Usage: dart run benchmark/e_livre_benchmarks.dart '
      '[--filter=<text>] [--quick]',
    );
}

/// Prints the header line of a benchmark group.
void printGroupHeader(final String title) {
  final pad = '─' * (66 - title.length - 3).clamp(3, 60);
  stdout
    ..writeln()
    ..writeln('── $title $pad')
    ..writeln(
      '${'benchmark'.padRight(56)}${'runs'.padLeft(7)}'
      '${'median'.padLeft(11)}${'mean'.padLeft(11)}${'p95'.padLeft(11)}'
      '${'ops/s'.padLeft(9)}  extra',
    );
}

/// Prints one benchmark row.
void printResult(final BenchmarkResult result, {final int? inputBytes}) {
  final extras = <String>[
    if (result.note != null) result.note!,
    if (inputBytes != null && result.median > 0)
      _formatRate(inputBytes / result.median),
  ];
  stdout.writeln(
    '${result.name.padRight(56)}'
    '${compactCount(result.iterations).padLeft(7)}'
    '${formatMicros(result.median).padLeft(11)}'
    '${formatMicros(result.mean).padLeft(11)}'
    '${formatMicros(result.p95).padLeft(11)}'
    '${compactRate(result.opsPerSecond).padLeft(9)}'
    '${extras.isEmpty ? '' : '  ${extras.join(' · ')}'}',
  );
}

/// Prints the run summary shown after every group has run.
void printFooter(final Duration total) {
  stdout
    ..writeln()
    ..writeln(
      'Done in ${total.inSeconds}s · sink checksum $sinkChecksum '
      '(results are machine-dependent; compare runs on the same machine '
      'only).',
    );
}

/// Formats a byte count for display (188 KB, 6.4 MB, ...).
String formatBytes(final int bytes) {
  if (bytes >= 1000000) {
    return '${_trimBytes(bytes / 1000000)} MB';
  }
  if (bytes >= 1000) {
    return '${_trimBytes(bytes / 1000)} KB';
  }
  return '$bytes B';
}

String _trimBytes(final double value) =>
    value >= 100 ? value.round().toString() : value.toStringAsFixed(1);

/// Formats a duration given in microseconds adaptively.
String formatMicros(final double micros) {
  if (micros < 1) {
    return '${(micros * 1000).toStringAsFixed(0)} ns';
  }
  if (micros < 1000) {
    return '${micros.toStringAsFixed(micros < 10 ? 2 : 1)} µs';
  }
  if (micros < 1e6) {
    return '${(micros / 1000).toStringAsFixed(2)} ms';
  }
  return '${(micros / 1e6).toStringAsFixed(2)} s';
}

/// Formats a count compactly (865k, 1.2M, ...).
String compactCount(final int count) {
  if (count < 1000) {
    return count.toString();
  }
  if (count < 1e6) {
    return '${(count / 1e3).toStringAsFixed(count < 1e4 ? 1 : 0)}k';
  }
  return '${(count / 1e6).toStringAsFixed(1)}M';
}

/// Formats an operations-per-second rate compactly.
String compactRate(final double rate) {
  if (rate < 1000) {
    return rate.toStringAsFixed(0);
  }
  if (rate < 1e6) {
    return '${(rate / 1e3).toStringAsFixed(rate < 1e4 ? 1 : 0)}k';
  }
  return '${(rate / 1e6).toStringAsFixed(1)}M';
}

String _formatRate(final double megaBytesPerSecond) =>
    '${megaBytesPerSecond.toStringAsFixed(megaBytesPerSecond < 10 ? 1 : 0)} MB/s';
