import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../pdf/exceptions/pdf_exception.dart';
import '../pdf/reader/pdf_byte_source.dart';
import 'byte_source.dart';
import 'session_metrics.dart';
import 'session_policy.dart';

/// A byte range the parser demanded that the resident store does not
/// hold yet. Pure control flow between [PdfResidentByteSource.read] and
/// the [PdfRangeLoader] resume loop — it never escapes a loader step.
final class PdfRangeDemand {
  /// Creates the demand for the missing `[offset, offset + count)` span.
  const PdfRangeDemand(this.offset, this.count);

  /// Absolute offset of the missing span.
  final int offset;

  /// Length of the missing span in bytes.
  final int count;

  @override
  String toString() => 'PdfRangeDemand($offset, +$count)';
}

/// One disjoint `[start, end)` interval and its bytes.
///
/// Byte lists are private copies: stream bodies materialized from a
/// range outlive later eviction of that range.
final class _Range {
  _Range(this.start, Uint8List bytes)
    : bytes = Uint8List.fromList(bytes),
      end = start + bytes.length;

  final int start;
  final int end;
  final Uint8List bytes;
}

/// Demand-driven resident range store over an asynchronous byte reader.
///
/// The synchronous PDF parser runs unchanged against a
/// [PdfResidentByteSource]. When that source is asked for bytes the
/// store does not hold, it raises [PdfRangeDemand]; [drive] turns the
/// demand into budget-checked reads and replays the step from its
/// start. Loaded ranges stay pinned until the step completes, so every
/// replay is cache-served CPU work and each retry fetches at least one
/// missing span — the explicit resume the campaign contract allows
/// instead of forking the parser into an async implementation.
///
/// Nothing is read ahead of demand: every stored byte was demanded by
/// a parser read first, and an overlapping demand fetches only its
/// missing sub-spans, so re-walks never multiply the wire bytes.
/// Between steps, unpinned ranges evict in offset order down to the cache
/// budget. A step exceeding the cache working-set budget fails before fetching
/// additional bytes. Output and host-response copies have the per-request cap.
final class PdfRangeLoader {
  /// Builds a loader over [readRange] with the policy's range budgets.
  ///
  /// [counter], when supplied, receives one `addContainerRead` per
  /// fetched span — the session metrics channel for remote reads.
  PdfRangeLoader({
    required final Future<Uint8List> Function(int offset, int count) readRange,
    required final int length,
    final SessionPolicy policy = const SessionPolicy(),
    final SessionMetricsCounter? counter,
  }) : _readRange = readRange,
       _length = length,
       _maxRequestBytes = math.min(
         policy.effectiveMaxRangeRequestBytes,
         policy.effectiveMaxRangeBytesInFlight,
       ),
       _workingSetBytes = policy.effectiveCacheBytes,
       _budgetBytes = _budgetFor(length, policy),
       _counter = counter {
    if (length < 0) throw RangeError.range(length, 0, null, 'length');
  }

  /// Half the source, clamped into [1 MiB, cache budget]: big enough
  /// that structural steps never evict mid-walk on normally shaped
  /// documents, small enough that no complete file stays resident.
  static int _budgetFor(final int length, final SessionPolicy policy) {
    final capped = math.min(length ~/ 2, policy.effectiveCacheBytes);

    return math.max(capped, 1 << 20);
  }

  final Future<Uint8List> Function(int offset, int count) _readRange;
  final int _length;
  final int _maxRequestBytes;
  final int _budgetBytes;
  final int _workingSetBytes;
  final SessionMetricsCounter? _counter;

  /// Resident ranges, sorted by start, pairwise disjoint.
  final List<_Range> _ranges = <_Range>[];

  /// Every range ever fetched, sorted by start, pairwise disjoint.
  final List<(int, int)> _coverage = <(int, int)>[];
  final Set<_Range> _pinned = <_Range>{};
  int _generation = 0;
  Completer<void>? _stepCancellation;

  var _residentBytes = 0;
  var _maxResidentBytes = 0;
  var _fetchCount = 0;
  var _fetchedBytes = 0;
  var _fetchedUniqueBytes = 0;
  var _resumeCount = 0;
  var _evictedBytes = 0;
  var _queuedStepsPeak = 0;
  var _closed = false;
  Future<void> _stepQueue = Future<void>.value();

  /// Total bytes currently resident (merged coverage).
  int get residentBytes => _residentBytes;

  /// Peak of [residentBytes] since the loader was created — the
  /// no-complete-buffer evidence channel.
  int get maxResidentBytes => _maxResidentBytes;

  /// Fetch calls issued to the byte reader.
  int get fetchCount => _fetchCount;

  /// Sum of fetched span lengths — the wire total (re-reads included).
  int get fetchedBytes => _fetchedBytes;

  /// Merged coverage of every fetch — the unique wire bytes.
  int get fetchedUniqueBytes => _fetchedUniqueBytes;

  /// Resume replays the loop has run.
  int get resumeCount => _resumeCount;

  /// Resident bytes dropped by between-step eviction.
  int get evictedBytes => _evictedBytes;

  /// Peak of steps admitted but not finished — the backpressure
  /// channel when several session ops race for the shared parser.
  int get queuedStepsPeak => _queuedStepsPeak;

  /// Whether the loader (and with it the resident store) is closed.
  bool get isClosed => _closed;

  /// Total source length in bytes.
  int get sourceLength => _length;

  /// The merged all-time fetch coverage as `[start, end)` pairs — the
  /// per-document read map the acceptance evidence records.
  List<(int, int)> coverage() => List<(int, int)>.unmodifiable(_coverage);

  /// Copies [count] bytes at [offset] out of the resident store, or
  /// throws [PdfRangeDemand] for the first missing span of the request.
  /// Out-of-bounds arguments throw [RangeError], like the memory source.
  Uint8List read(final int offset, final int count) {
    if (_closed) throw const ByteSourceClosedException();
    RangeError.checkValidRange(offset, offset + count, _length, 'offset', 'end');
    if (count == 0) return Uint8List(0);

    _checkReadBudget(count);
    var cursor = offset;
    final end = offset + count;
    while (cursor < end) {
      final index = _rangeIndexAt(cursor);
      if (index < 0) throw PdfRangeDemand(cursor, end - cursor);
      final range = _ranges[index];
      _pinned.add(range);
      cursor = math.min(range.end, end);
    }
    // No speculative output is allocated on a cache miss. At this point
    // resident bytes are bounded by cacheBytes and this copy by rangeRequestBytes.
    final out = Uint8List(count);
    cursor = offset;
    while (cursor < end) {
      final range = _ranges[_rangeIndexAt(cursor)];
      final take = math.min(range.end, end) - cursor;
      out.setRange(cursor - offset, cursor - offset + take, range.bytes, cursor - range.start);
      cursor += take;
    }

    return out;
  }

  /// Index of the resident range covering [offset], or -1.
  int _rangeIndexAt(final int offset) {
    var low = 0;
    var high = _ranges.length - 1;
    while (low <= high) {
      final mid = (low + high) ~/ 2;
      final range = _ranges[mid];
      if (offset < range.start) {
        high = mid - 1;
      } else if (offset >= range.end) {
        low = mid + 1;
      } else {
        return mid;
      }
    }

    return -1;
  }

  /// Runs one synchronous parser step, serialized through the step
  /// queue and resumed on demand.
  ///
  /// Concurrent session ops queue instead of failing: the parser and
  /// the shared extractor hold mutable state, so two steps may never
  /// interleave. Inside a step, demands raised by [step] fetch their
  /// missing spans through the reader and replay the step from its
  /// start; the working set stays pinned, so the loop converges and
  /// the hard resume cap converts a demand cycle that cannot converge
  /// into a typed [PdfException]. Every other failure propagates to
  /// the step's caller and lets the next queued step run.
  Future<T> drive<T>(final T Function() step) {
    if (_closed) throw const ByteSourceClosedException();

    _outstandingSteps++;
    if (_outstandingSteps > _queuedStepsPeak) _queuedStepsPeak = _outstandingSteps;

    final generation = _generation;
    final run = _stepQueue.then((final _) => _runStep(step, generation));
    _stepQueue = run.then((final _) {}, onError: (final Object _) {});

    return run.whenComplete(() => _outstandingSteps--);
  }

  var _outstandingSteps = 0;

  /// Cancels queued parser work without closing the source or dropping
  /// completed parsed objects. The transport separately cancels its range futures.
  void cancelPending() {
    _generation++;
    final pending = _stepCancellation;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  void _checkGeneration(final int generation) {
    if (_closed) throw const ByteSourceClosedException();
    if (generation != _generation) throw const SessionCancelledException();
  }

  void _checkReadBudget(final int count) {
    if (count > _maxRequestBytes || count > _workingSetBytes) {
      throw ByteSourceLimitExceededException(
        'A $count-byte PDF read exceeds the per-request or cache working-set budget.',
      );
    }
  }

  Future<T> _runStep<T>(final T Function() step, final int generation) async {
    const resumeCap = 65536;
    final signal = Completer<void>();
    _stepCancellation = signal;
    Future<void>? cancelled;
    try {
      for (var resume = 0; ; resume++) {
        _checkGeneration(generation);
        try {
          return step();
        } on PdfRangeDemand catch (demand) {
          _resumeCount++;
          if (resume >= resumeCap) {
            throw PdfException(
              'The PDF session demanded more than $resumeCap range resumes in one '
              'step; the document structure does not converge over a byte source.',
            );
          }
          await Future.any<void>([
            _fetch(demand.offset, demand.count, generation),
            cancelled ??= signal.future.then((final _) => _checkGeneration(generation)),
          ]);
        }
      }
    } finally {
      _stepCancellation = null;
      if (!signal.isCompleted) signal.complete();
      _pinned.clear();
      _evictToBudget();
    }
  }

  Future<void> _fetch(final int offset, final int count, final int generation) async {
    // Bounds were validated by read(); fetch only what is missing so
    // overlapping windows never re-request covered bytes.
    var cursor = offset;
    final end = offset + count;
    while (cursor < end) {
      final index = _rangeIndexAt(cursor);
      if (index >= 0) {
        cursor = _ranges[index].end;

        continue;
      }

      final spanEnd = math.min(_nextResidentStart(cursor), end);
      await _fetchSpan(cursor, spanEnd - cursor, generation);
      cursor = spanEnd;
    }
  }

  /// The start of the first resident range after [offset], or the
  /// source length.
  int _nextResidentStart(final int offset) {
    var low = 0;
    var high = _ranges.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_ranges[mid].start <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }

    return low < _ranges.length ? _ranges[low].start : _length;
  }

  Future<void> _fetchSpan(final int offset, final int count, final int generation) async {
    _checkGeneration(generation);
    _checkReadBudget(count);
    // Previous steps' ranges may evict; this step's pinned ranges may not.
    // Refuse an oversized working set before requesting or copying more bytes.
    while (_residentBytes + count > _workingSetBytes) {
      final index = _ranges.indexWhere((final range) => !_pinned.contains(range));
      if (index < 0) {
        throw const ByteSourceLimitExceededException(
          'The PDF parser step exceeds SessionPolicy.cacheBytes; raise the cache '
          'budget for this document structure.',
        );
      }
      final removed = _ranges.removeAt(index);
      _residentBytes -= removed.bytes.length;
      _evictedBytes += removed.bytes.length;
    }
    _fetchCount++;
    final bytes = await _readRange(offset, count);
    if (bytes.length != count) {
      throw ByteSourceShortReadException(offset: offset, count: count, received: bytes.length);
    }
    _fetchedBytes += count;
    _counter?.addContainerRead(count);
    if (!_closed) _recordCoverage(offset, offset + count);
    _checkGeneration(generation);
    final range = _Range(offset, bytes);
    final index = _ranges.indexWhere((final other) => other.start > offset);
    _ranges.insert(index < 0 ? _ranges.length : index, range);
    _pinned.add(range);
    _residentBytes += count;
    _maxResidentBytes = math.max(_maxResidentBytes, _residentBytes);
  }

  void _recordCoverage(final int start, final int end) {
    var index = 0;
    while (index < _coverage.length && _coverage[index].$2 < start) {
      index++;
    }
    var mergedStart = start;
    var mergedEnd = end;
    var last = index;
    var absorbed = 0;
    while (last < _coverage.length && _coverage[last].$1 <= mergedEnd) {
      final interval = _coverage[last++];
      mergedStart = math.min(mergedStart, interval.$1);
      mergedEnd = math.max(mergedEnd, interval.$2);
      absorbed += interval.$2 - interval.$1;
    }
    _coverage.replaceRange(index, last, [(mergedStart, mergedEnd)]);
    _fetchedUniqueBytes += mergedEnd - mergedStart - absorbed;
  }

  /// Drops the lowest-offset resident ranges until the store fits the budget.
  /// Only called between steps, so pinned working sets never shrink.
  void _evictToBudget() {
    while (_residentBytes > _budgetBytes && _ranges.isNotEmpty) {
      final range = _ranges.removeAt(0);
      _residentBytes -= range.end - range.start;
      _evictedBytes += range.end - range.start;
    }
  }

  /// Drops resident ranges and the interval ledger. Scalar statistics stay.
  Future<void> close() async {
    _closed = true;
    cancelPending();
    _pinned.clear();
    _coverage.clear();
    _ranges.clear();
    _residentBytes = 0;
  }
}

/// A [PdfByteSource] over a [PdfRangeLoader]: reads are resident-store
/// copies, and a miss raises the demand the loader's resume loop acts
/// on. Closing the loader fails further reads typed.
final class PdfResidentByteSource implements PdfByteSource {
  /// Binds the source to [loader].
  PdfResidentByteSource(this.loader);

  /// The owning loader.
  final PdfRangeLoader loader;

  @override
  int get length => loader.sourceLength;

  @override
  Uint8List read(final int offset, final int count) => loader.read(offset, count);

  @override
  void close() {
    // The loader closes with the session; the parser never closes the
    // source underneath a running step.
  }
}
