import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../foundation/exceptions/unseal_exception.dart';
import 'byte_source.dart';
import 'session_policy.dart';

/// Authoritative host-side gate over a [UnsealByteSource].
///
/// Every range request an open session produces funnels through one
/// gate on the thread that owns the source — the main isolate's
/// transport for VM sessions, the main thread for worker sessions, or
/// the calling thread for the inline fallback. The gate enforces the
/// source contract (exact answers, bounds, revision identity), the
/// session's in-flight budgets, and the source lifecycle:
///
/// - Bounds violations throw RangeError; reads past [close] fail
///   with [ByteSourceClosedException].
/// - Requests above the per-request cap fail with
///   [ByteSourceLimitExceededException] instead of silently
///   downloading the container. In-flight caps queue requests FIFO —
///   backpressure, not failure.
/// - A source whose revision token changed under the open session
///   fails its reads with [ByteSourceRevisionChangedException]
///   (checked before and after the underlying read).
/// - A short or long answer fails typed; an exception escaping the
///   source surfaces as [ByteSourceReadException].
final class ByteSourceGate {
  /// Gates the given source with the policy's range budgets.
  ByteSourceGate(this._source, {final SessionPolicy policy = const SessionPolicy()})
    : _maxRequestsInFlight = policy.effectiveMaxRangeRequestsInFlight,
      _maxBytesInFlight = policy.effectiveMaxRangeBytesInFlight,
      _maxRequestBytes = math.min(
        policy.effectiveMaxRangeRequestBytes,
        policy.effectiveMaxRangeBytesInFlight,
      ),
      revisionAtOpen = _source.revision;

  final UnsealByteSource _source;
  final int _maxRequestsInFlight;
  final int _maxBytesInFlight;
  final int _maxRequestBytes;

  /// The source revision observed when the gate was created — the
  /// identity the session's reads are stamped with.
  final String? revisionAtOpen;

  var _closed = false;
  var _inFlightRequests = 0;
  var _inFlightBytes = 0;
  var _maxInFlightRequests = 0;
  var _maxInFlightBytes = 0;
  final List<_QueuedRead> _queue = <_QueuedRead>[];
  final Set<_ActiveRead> _active = <_ActiveRead>{};
  Future<void>? _sourceClosed;

  /// Total container length in bytes.
  int get length => _source.length;

  /// The source's current revision token, or null when unverified.
  String? get revision => _source.revision;

  /// Requests currently being served by the source.
  int get inFlightRequests => _inFlightRequests;

  /// Sum of the counts of the requests currently being served.
  int get inFlightBytes => _inFlightBytes;

  /// Peak of [inFlightRequests] since the gate was created — the
  /// observable proof that the concurrency cap held.
  int get maxObservedInFlightRequests => _maxInFlightRequests;

  /// Peak of [inFlightBytes] since the gate was created.
  int get maxObservedInFlightBytes => _maxInFlightBytes;

  /// Requests waiting for an in-flight slot (backpressure queue).
  int get queuedRequests => _queue.length;

  /// Whether the gate (and with it the source) is closed.
  bool get isClosed => _closed;

  /// Reads exactly [count] bytes at [offset] for the session opened
  /// against [expectedRevision] (the gate's [revisionAtOpen]).
  ///
  /// The returned future completes with exactly [count] bytes or a
  /// typed failure; the source's answer is never sliced or padded into
  /// a fake success.
  Future<Uint8List> read(final int offset, final int count, {final String? expectedRevision}) {
    RangeError.checkValidRange(offset, offset + count, length, 'offset', 'end');
    if (_closed) throw const ByteSourceClosedException();
    if (count > _maxRequestBytes) {
      throw ByteSourceLimitExceededException(
        'A $count-byte range request exceeds the session '
        '$_maxRequestBytes-byte per-request cap; raise SessionPolicy.rangeRequestBytes '
        'to serve entries this large.',
      );
    }

    final active = _ActiveRead(offset, count, expectedRevision);
    _queue.add(_QueuedRead(active));
    _pump();

    return active.completer.future;
  }

  /// Fails queued and active range futures while keeping the source open.
  /// Physical host reads retain their slots/bytes until they settle: a host
  /// without an abort primitive cannot bypass the in-flight budget by cancelling.
  void cancelPending() {
    for (final queued in _queue) {
      queued.active.completer.completeError(const SessionCancelledException());
    }
    _queue.clear();
    for (final active in _active) {
      if (!active.cancelled) {
        active.cancelled = true;
        active.completer.completeError(const SessionCancelledException());
      }
    }
  }

  /// Closes the gate: queued and in-flight reads fail with
  /// [ByteSourceClosedException], no further reads are accepted, and
  /// the underlying source's [UnsealByteSource.close] completes before
  /// the returned future does. Closing twice is a no-op.
  Future<void> close() {
    if (_closed) return _sourceClosed ?? Future<void>.value();

    _closed = true;
    for (final queued in _queue) {
      queued.active.completer.completeError(const ByteSourceClosedException());
    }
    _queue.clear();
    for (final active in _active) {
      if (!active.cancelled) active.completer.completeError(const ByteSourceClosedException());
      active.cancelled = true;
    }
    _active.clear();
    _inFlightRequests = 0;
    _inFlightBytes = 0;
    _sourceClosed = _source.close();

    return _sourceClosed!;
  }

  void _pump() {
    while (!_closed && _queue.isNotEmpty) {
      final next = _queue.first;
      final fitsSlot = _inFlightRequests < _maxRequestsInFlight;
      final fitsBytes = _inFlightBytes + next.active.count <= _maxBytesInFlight;
      if (!fitsSlot || !fitsBytes) return;

      _queue.removeAt(0);
      _inFlightRequests++;
      _inFlightBytes += next.active.count;
      if (_inFlightRequests > _maxInFlightRequests) _maxInFlightRequests = _inFlightRequests;
      if (_inFlightBytes > _maxInFlightBytes) _maxInFlightBytes = _inFlightBytes;
      _active.add(next.active);
      unawaited(_serve(next.active));
    }
  }

  Future<void> _serve(final _ActiveRead active) async {
    Uint8List? answer;
    Object? failure;
    try {
      _assertRevision(active.expectedRevision);
      answer = await _source.readRange(active.offset, active.count);
      _assertRevision(active.expectedRevision);
    } on Object catch (error) {
      failure = _normalizeFailure(active, error);
    }

    if (_closed) return;
    _active.remove(active);
    _inFlightRequests = math.max(0, _inFlightRequests - 1);
    _inFlightBytes = math.max(0, _inFlightBytes - active.count);
    if (active.cancelled) {
      _pump();
      return;
    }

    if (failure != null) {
      active.completer.completeError(failure);
    } else if (answer!.length < active.count) {
      active.completer.completeError(
        ByteSourceShortReadException(
          offset: active.offset,
          count: active.count,
          received: answer.length,
        ),
      );
    } else if (answer.length > active.count) {
      active.completer.completeError(
        ByteSourceLongReadException(
          offset: active.offset,
          count: active.count,
          received: answer.length,
        ),
      );
    } else {
      active.completer.complete(answer);
    }

    _pump();
  }

  void _assertRevision(final String? expectedRevision) {
    if (expectedRevision == null) return;
    final current = _source.revision;
    if (current != expectedRevision) {
      throw ByteSourceRevisionChangedException(expected: expectedRevision, actual: current);
    }
  }

  Object _normalizeFailure(final _ActiveRead active, final Object error) {
    if (error is ByteSourceException || error is UnsealException) return error;

    return ByteSourceReadException(error);
  }
}

final class _QueuedRead {
  _QueuedRead(this.active);

  final _ActiveRead active;
}

final class _ActiveRead {
  _ActiveRead(this.offset, this.count, this.expectedRevision);

  final int offset;
  final int count;
  final String? expectedRevision;
  final Completer<Uint8List> completer = Completer<Uint8List>();
  bool cancelled = false;
}
