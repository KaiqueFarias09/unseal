import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:unseal/unseal.dart';

/// How a parse attempt ended.
enum ProbeStatus {
  /// The parser returned a book.
  ok,

  /// The parser threw a typed exception (expected for corrupt inputs).
  threw,

  /// The parser exceeded the deadline and its isolate was killed.
  timeout,

  /// The worker isolate died without a typed result (hard crash).
  crash,
}

/// The outcome of one parse probe.
final class ProbeResult {
  const ProbeResult(this.status, this.detail, this.durationMs, {this.graceful = false});

  /// Classification of the outcome.
  final ProbeStatus status;

  /// Exception type name for `threw`/`crash`, empty for `ok`/`timeout`.
  ///
  /// Only the runtime TYPE is captured, never the message, so details
  /// stay free of fixture-internal or private content.
  final String detail;

  /// Wall time of the probe in milliseconds.
  final int durationMs;

  /// Whether a `threw` outcome was a typed [UnsealException] — the
  /// library's own graceful rejection — rather than a foreign crash.
  final bool graceful;

  /// Stable failure signature: `ok`, `timeout`, `crash`, `reject:<Type>`
  /// for graceful typed rejections, or `throw:<Type>` for foreign errors.
  ///
  /// The minimizer uses this to check that a reduced input still fails
  /// the SAME way as the original.
  String get signature => switch (status) {
    ProbeStatus.ok => 'ok',
    ProbeStatus.timeout => 'timeout',
    ProbeStatus.crash => 'crash',
    ProbeStatus.threw => graceful ? 'reject:$detail' : 'throw:$detail',
  };
}

/// Parses [bytes] through [parse] in a fresh isolate, killing the worker
/// on [timeout] so a wedged parser cannot outlive the deadline.
///
/// The same primitive backs the corpus inventory smoke check and the
/// private-corpus minimizer; harnesses can reuse it for their own
/// probe loops.
Future<ProbeResult> probeParse(
  final Uint8List bytes,
  final Future<void> Function(Uint8List) parse, {
  final Duration timeout = const Duration(seconds: 30),
}) async {
  final watch = Stopwatch()..start();
  final port = ReceivePort();
  final done = Completer<ProbeResult>();
  late final Isolate isolate;

  void completeCrash(final String detail) {
    if (!done.isCompleted) {
      done.complete(ProbeResult(ProbeStatus.crash, detail, watch.elapsedMilliseconds));
    }
  }

  port.listen((final message) {
    if (done.isCompleted) {
      return;
    }
    if (message == null) {
      // `onExit` uses this same port. Normal results are sent before the
      // isolate exits, so they arrive first without relying on a timer race.
      completeCrash('UnexpectedIsolateExit');
      return;
    }
    if (message is! Map) {
      // Uncaught isolate errors are also sent to this port by `onError`.
      completeCrash('IsolateError');
      return;
    }
    try {
      final payload = message;
      final status = ProbeStatus.values.byName(payload['status'] as String);
      done.complete(
        ProbeResult(
          status,
          (payload['detail'] as String?) ?? '',
          watch.elapsedMilliseconds,
          graceful: payload['graceful'] as bool? ?? false,
        ),
      );
    } on Object {
      completeCrash('InvalidProbeResult');
    }
  });

  try {
    isolate = await Isolate.spawn(
      _probeEntry,
      _ProbeJob(port.sendPort, bytes, parse),
      errorsAreFatal: true,
      onError: port.sendPort,
      onExit: port.sendPort,
    );
  } on Object {
    port.close();
    return ProbeResult(ProbeStatus.crash, 'SpawnFailed', watch.elapsedMilliseconds);
  }

  final result = await done.future.timeout(
    timeout,
    onTimeout: () {
      isolate.kill(priority: Isolate.immediate);
      return ProbeResult(ProbeStatus.timeout, '', watch.elapsedMilliseconds);
    },
  );
  port.close();
  return result;
}

final class _ProbeJob {
  const _ProbeJob(this.sendPort, this.bytes, this.parse);

  final SendPort sendPort;
  final Uint8List bytes;
  final Future<void> Function(Uint8List) parse;
}

Future<void> _probeEntry(final _ProbeJob job) async {
  try {
    await job.parse(job.bytes);
    job.sendPort.send({'status': ProbeStatus.ok.name});
  } on UnsealException catch (error) {
    job.sendPort.send({
      'status': ProbeStatus.threw.name,
      'detail': error.runtimeType.toString(),
      'graceful': true,
    });
  } on Object catch (error) {
    job.sendPort.send({'status': ProbeStatus.threw.name, 'detail': error.runtimeType.toString()});
  }
}
