import 'dart:typed_data';

import '../../foundation/archive/zip_byte_source.dart';

/// A byte-budgeted counter the session engine shares with its sources.
///
/// The counters answer "what did this session actually touch": raw
/// source reads, container units decoded (PDB records, ZIP entries),
/// decompressed bytes, and content bytes handed to consumers. Tests
/// verify them against analytically derived expectations, which is
/// what makes the progressivity claims checkable rather than asserted.
final class SessionMetricsCounter {
  int _containerReads = 0;
  int _sourceBytesRead = 0;
  int _unitsDecoded = 0;
  int _bytesDecoded = 0;
  int _contentBytesMaterialized = 0;

  /// One raw read served by the container byte source.
  void addContainerRead(final int bytes) {
    _containerReads++;
    _sourceBytesRead += bytes;
  }

  /// One container unit decoded (a decompressed record, an inflated
  /// entry) producing [bytes].
  void addDecoded(final int bytes) {
    _unitsDecoded++;
    _bytesDecoded += bytes;
  }

  /// Content bytes handed to a consumer (text code units or resource
  /// bytes).
  void addMaterialized(final int bytes) {
    _contentBytesMaterialized += bytes;
  }

  /// The wire-ready snapshot; integer values only, structured-clone
  /// safe.
  Map<String, int> toWire() => <String, int>{
    'containerReads': _containerReads,
    'sourceBytesRead': _sourceBytesRead,
    'unitsDecoded': _unitsDecoded,
    'bytesDecoded': _bytesDecoded,
    'contentBytesMaterialized': _contentBytesMaterialized,
  };
}

/// A [ZipByteSource] that counts every read for session metrics.
final class CountingZipByteSource implements ZipByteSource {
  /// Wraps [source] and increments [counter].
  CountingZipByteSource(this.source, this.counter);

  /// The wrapped source; `close` forwards here.
  final ZipByteSource source;

  /// The shared session counter.
  final SessionMetricsCounter counter;

  @override
  int get length => source.length;

  @override
  Uint8List read(final int offset, final int count) {
    counter.addContainerRead(count);

    return source.read(offset, count);
  }

  @override
  void close() => source.close();
}

/// A point-in-time snapshot of what a session has touched, from
/// `BookSession.metrics`.
///
/// The values are the delivery layer's evidence, not a content
/// measure: `bytesDecoded` counts decompression work (which a cold
/// open legitimately does for the reading index), while
/// `contentBytesMaterialized` counts what consumers actually received.
final class SessionMetrics {
  /// Creates a snapshot from raw counts.
  const SessionMetrics({
    required this.containerReads,
    required this.sourceBytesRead,
    required this.unitsDecoded,
    required this.bytesDecoded,
    required this.contentBytesMaterialized,
    required this.cacheBytesResident,
    this.pdfRangeFetches,
    this.pdfRangeFetchBytes,
    this.pdfRangeUniqueBytes,
    this.pdfRangeResidentPeak,
    this.pdfRangeResumes,
    this.pdfRangeEvicted,
    this.pdfRangeQueuedStepsPeak,
  });

  /// Decodes a snapshot from the transport wire.
  SessionMetrics.fromWire(final Map<String, Object?> wire)
    : this(
        containerReads: wire['containerReads'] as int? ?? 0,
        sourceBytesRead: wire['sourceBytesRead'] as int? ?? 0,
        unitsDecoded: wire['unitsDecoded'] as int? ?? 0,
        bytesDecoded: wire['bytesDecoded'] as int? ?? 0,
        contentBytesMaterialized: wire['contentBytesMaterialized'] as int? ?? 0,
        cacheBytesResident: wire['cacheBytesResident'] as int? ?? 0,
        pdfRangeFetches: wire['pdfRangeFetches'] as int?,
        pdfRangeFetchBytes: wire['pdfRangeFetchBytes'] as int?,
        pdfRangeUniqueBytes: wire['pdfRangeUniqueBytes'] as int?,
        pdfRangeResidentPeak: wire['pdfRangeResidentPeak'] as int?,
        pdfRangeResumes: wire['pdfRangeResumes'] as int?,
        pdfRangeEvicted: wire['pdfRangeEvicted'] as int?,
        pdfRangeQueuedStepsPeak: wire['pdfRangeQueuedStepsPeak'] as int?,
      );

  /// Raw reads the container byte source served.
  final int containerReads;

  /// Total raw source bytes those reads carried.
  final int sourceBytesRead;

  /// Container units decoded (inflated entries, decompressed records).
  final int unitsDecoded;

  /// Bytes the container layer decompressed.
  final int bytesDecoded;

  /// Content bytes handed to consumers (text code units and resource
  /// bytes).
  final int contentBytesMaterialized;

  /// Current resident cache weight in bytes.
  final int cacheBytesResident;

  /// Byte-source PDF sessions only: read attempts issued through the source gate.
  final int? pdfRangeFetches;

  /// Bytes returned to the PDF range loader (re-demands included).
  /// Physical host reads discarded by a canceled transport are not included.
  final int? pdfRangeFetchBytes;

  /// Unique offsets returned to the PDF range loader.
  /// Hosts must separately measure traffic discarded by canceled reads.
  final int? pdfRangeUniqueBytes;

  /// Peak resident range bytes — the no-complete-buffer channel.
  final int? pdfRangeResidentPeak;

  /// Resume replays the range loop has run.
  final int? pdfRangeResumes;

  /// Resident bytes dropped by between-step eviction.
  final int? pdfRangeEvicted;

  /// Peak of parser steps admitted but not finished — the
  /// backpressure channel for concurrent session ops.
  final int? pdfRangeQueuedStepsPeak;

  /// The wire-ready map, symmetric with [SessionMetrics.fromWire].
  Map<String, Object?> toWire() => <String, Object?>{
    'containerReads': containerReads,
    'sourceBytesRead': sourceBytesRead,
    'unitsDecoded': unitsDecoded,
    'bytesDecoded': bytesDecoded,
    'contentBytesMaterialized': contentBytesMaterialized,
    'cacheBytesResident': cacheBytesResident,
    if (pdfRangeFetches != null) 'pdfRangeFetches': pdfRangeFetches,
    if (pdfRangeFetchBytes != null) 'pdfRangeFetchBytes': pdfRangeFetchBytes,
    if (pdfRangeUniqueBytes != null) 'pdfRangeUniqueBytes': pdfRangeUniqueBytes,
    if (pdfRangeResidentPeak != null) 'pdfRangeResidentPeak': pdfRangeResidentPeak,
    if (pdfRangeResumes != null) 'pdfRangeResumes': pdfRangeResumes,
    if (pdfRangeEvicted != null) 'pdfRangeEvicted': pdfRangeEvicted,
    if (pdfRangeQueuedStepsPeak != null) 'pdfRangeQueuedStepsPeak': pdfRangeQueuedStepsPeak,
  };

  @override
  String toString() =>
      'SessionMetrics(reads: $containerReads, sourceBytes: $sourceBytesRead, '
      'decoded: $unitsDecoded units/$bytesDecoded bytes, '
      'materialized: $contentBytesMaterialized bytes, cache: $cacheBytesResident bytes)';
}
