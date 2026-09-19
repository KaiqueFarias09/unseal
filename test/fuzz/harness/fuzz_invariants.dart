/// The fuzzing invariants engine shared by the deterministic suites
/// (`test/fuzz/`) and the campaign runner (`tool/fuzz_runner.dart`).
///
/// Every parse entry point must preserve these invariants over hostile input:
///
/// 1. terminates within a bounded wall-clock budget;
/// 2. returns a `Book`/`BookMetadata` or throws a typed
///    [UnsealException] — never a bare `RangeError`, `StateError`,
///    `FormatException`, `ArgumentError` or `TypeError` escaping;
/// 3. memory stays bounded for small inputs (gigabyte expansions are
///    classified as defects through the campaign runner);
/// 4. no unbounded recursion (deep nesting must not crash the
///    isolate with a stack overflow).
///
/// Every input is executed inside a dedicated worker isolate. The caller kills
/// the isolate on timeout so a wedged parser cannot hang the suite. This uses
/// the same pattern as `benchmark/library_sweep.dart`.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:unseal/unseal.dart';

/// Outcome of one bounded parse attempt.
enum FuzzStatus {
  /// The entry point returned a parsed book/metadata value.
  ok,

  /// The entry point threw a typed exception (contract-compliant).
  typed,

  /// The entry point threw an untyped exception or error (defect).
  untyped,

  /// The worker isolate died (uncaught error, e.g. stack overflow).
  crash,

  /// The worker isolate exceeded its deadline and was killed.
  timeout,

  /// The entry was not attempted (an earlier entry already failed).
  skipped,
}

/// A single entry point exercised by the invariants worker.
enum FuzzEntryPoint {
  /// `detectFormat` — the sniffing front door.
  detect,

  /// `Unseal.parse` — synchronous parse.
  parse,

  /// `Unseal.readMetadataSync` — synchronous metadata read.
  metadata,

  /// `Unseal.read` — the flagship async reader.
  open,
}

/// Verdict for one entry point.
final class FuzzEntryVerdict {
  FuzzEntryVerdict(this.status, {this.errorType, this.detail});

  /// Which status the entry ended in.
  final FuzzStatus status;

  /// Runtime type of the thrown object (or isolate error class).
  final String? errorType;

  /// Truncated human-readable detail (message/stack head).
  final String? detail;

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status.name,
    if (errorType != null) 'errorType': errorType,
    if (detail != null) 'detail': detail,
  };

  static FuzzEntryVerdict fromJson(final Map<String, Object?> json) => FuzzEntryVerdict(
    FuzzStatus.values.firstWhere((final s) => s.name == json['status']),
    errorType: json['errorType'] as String?,
    detail: json['detail'] as String?,
  );
}

/// Full invariants verdict for one input across all entry points.
final class FuzzVerdict {
  FuzzVerdict(this.entries);

  /// Verdict per entry point (only attempted entries present).
  final Map<FuzzEntryPoint, FuzzEntryVerdict> entries;

  /// The worst status across entries, ordered ok < typed < skipped <
  /// untyped < crash < timeout.
  FuzzStatus get status {
    var worst = FuzzStatus.ok;
    for (final verdict in entries.values) {
      if (verdict.status.index > worst.index) worst = verdict.status;
    }
    return worst;
  }

  /// True when the input violated an invariant (untyped, crash or
  /// timeout).
  bool get isDefect =>
      status == FuzzStatus.untyped || status == FuzzStatus.crash || status == FuzzStatus.timeout;

  /// Short description of the first defect found (entry + type).
  String? get defectSummary {
    for (final entry in FuzzEntryPoint.values) {
      final verdict = entries[entry];
      if (verdict != null && verdict.status.index >= FuzzStatus.untyped.index) {
        return '${entry.name}:${verdict.errorType ?? verdict.status.name}';
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status.name,
    'entries': <String, Object?>{
      for (final entry in entries.entries) entry.key.name: entry.value.toJson(),
    },
  };
}

/// Exception types that count as TYPED (contract-compliant) failures.
///
/// [UnsealException] is the contract; `EmptyBytesException` currently
/// sits outside it (tracked finding F-001) and is provisionally
/// accepted here so suites surface NEW deviations instead of the
/// known one.
bool isTypedFailure(final Object error) => error is UnsealException || _isEmptyBytes(error);

bool _isEmptyBytes(final Object error) => error.runtimeType.toString() == 'EmptyBytesException';

/// Classifies an error thrown by one entry point.
FuzzEntryVerdict classifyError(final Object error) {
  if (isTypedFailure(error)) {
    return FuzzEntryVerdict(FuzzStatus.typed, errorType: error.runtimeType.toString());
  }
  return FuzzEntryVerdict(
    FuzzStatus.untyped,
    errorType: error.runtimeType.toString(),
    detail: _truncate('$error'),
  );
}

/// Runs every parse entry point over [bytes] inside a killable worker
/// isolate with a total wall-clock budget of [timeout].
Future<FuzzVerdict> runBoundedParse(
  final Uint8List bytes, {
  final Duration timeout = const Duration(seconds: 20),
}) async {
  final port = ReceivePort();
  final errorPort = ReceivePort();
  final entries = <FuzzEntryPoint, FuzzEntryVerdict>{};
  final done = Completer<void>();
  var inFlight = FuzzEntryPoint.detect;

  errorPort.listen((final message) {
    entries[inFlight] = FuzzEntryVerdict(
      FuzzStatus.crash,
      errorType: 'IsolateError',
      detail: _truncate('$message'),
    );
    if (!done.isCompleted) done.complete();
  });
  port.listen((final message) {
    final payload = message as Map;
    switch (payload['event']) {
      case 'enter':
        inFlight = FuzzEntryPoint.values.firstWhere((final e) => e.name == payload['entry']);
      case 'verdict':
        final entry = FuzzEntryPoint.values.firstWhere((final e) => e.name == payload['entry']);
        entries[entry] = FuzzEntryVerdict.fromJson(
          (payload['verdict'] as Map).cast<String, Object?>(),
        );
      case 'done':
        if (!done.isCompleted) done.complete();
    }
  });

  final Isolate isolate;
  try {
    isolate = await Isolate.spawn(_worker, _FuzzJob(port.sendPort, bytes), errorsAreFatal: true);
  } on Object {
    port.close();
    errorPort.close();
    return FuzzVerdict(<FuzzEntryPoint, FuzzEntryVerdict>{
      inFlight: FuzzEntryVerdict(FuzzStatus.crash, errorType: 'IsolateSpawnError'),
    });
  }

  try {
    await done.future.timeout(
      timeout,
      onTimeout: () {
        entries.putIfAbsent(
          inFlight,
          () => FuzzEntryVerdict(FuzzStatus.timeout, errorType: 'TimeoutException'),
        );
        isolate.kill(priority: Isolate.immediate);
      },
    );
  } on Object {
    entries.putIfAbsent(
      inFlight,
      () => FuzzEntryVerdict(FuzzStatus.crash, errorType: 'HarnessError'),
    );
  }
  port.close();
  errorPort.close();

  return FuzzVerdict(entries);
}

/// Wire message for the invariants worker isolate.
final class _FuzzJob {
  _FuzzJob(this.sendPort, this.bytes);

  final SendPort sendPort;
  final Uint8List bytes;
}

/// Worker entry: exercises every entry point sequentially, reporting a
/// verdict per entry so the killer can attribute timeouts.
Future<void> _worker(final _FuzzJob job) async {
  final port = job.sendPort;

  Future<void> attempt(final FuzzEntryPoint entry, final Future<Object?> Function() action) async {
    port.send(<String, Object?>{'event': 'enter', 'entry': entry.name});
    try {
      await action();
      port.send(<String, Object?>{
        'event': 'verdict',
        'entry': entry.name,
        'verdict': FuzzEntryVerdict(FuzzStatus.ok).toJson(),
      });
    } on Object catch (error) {
      port.send(<String, Object?>{
        'event': 'verdict',
        'entry': entry.name,
        'verdict': classifyError(error).toJson(),
      });
    }
  }

  try {
    await attempt(FuzzEntryPoint.detect, () async {
      detectFormat(job.bytes);
      return null;
    });
    await attempt(FuzzEntryPoint.parse, () async {
      Unseal.parse(job.bytes);
      return null;
    });
    await attempt(FuzzEntryPoint.metadata, () async {
      Unseal.readMetadataSync(job.bytes);
      return null;
    });
    await attempt(FuzzEntryPoint.open, () async => Unseal.read(job.bytes));
  } on Object catch (error) {
    // Anything escaping here is an isolate-level failure (worker bug,
    // not parser behavior): surface it as a crash verdict.
    port.send(<String, Object?>{
      'event': 'verdict',
      'entry': FuzzEntryPoint.open.name,
      'verdict': FuzzEntryVerdict(
        FuzzStatus.crash,
        errorType: error.runtimeType.toString(),
        detail: _truncate('$error'),
      ).toJson(),
    });
  }
  port.send(<String, Object?>{'event': 'done'});
}

String _truncate(final String value) => value.length <= 400 ? value : '${value.substring(0, 400)}…';
