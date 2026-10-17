import 'dart:typed_data';

import '../../../foundation/archive/zip_byte_source.dart';
import '../../../foundation/exceptions/unseal_exception.dart';
import '../../progressive/session_metrics.dart';
import '../compression/huff_cdic.dart';
import '../compression/palmdoc.dart';
import '../exceptions/mobi_exception.dart';
import '../header/mobi_header.dart';
import '../header/pdb_header.dart';
import 'mobi_trailing_data.dart';

/// Random-access Palm Database records over a bounded byte source.
///
/// Only the 78-byte header and the record table stay resident —
/// exactly what the eager `PdbHeader` keeps, minus the whole-file
/// bytes. Record contents read on demand in seek-and-slice reads, so
/// a file-backed session never materializes the container.
final class PdbRandomAccess implements PdbRecordAccess {
  PdbRandomAccess._(this.ident, this.name, this._source, this.recordCount, this.offsets);

  /// Opens [source] as a Palm Database, validating the header and the
  /// record table with the same rules the eager `PdbHeader.parse`
  /// applies.
  factory PdbRandomAccess.open(final ZipByteSource source) {
    if (source.length < 78) {
      throw const InvalidBookException('File is too small to be a Palm database.');
    }

    final head = source.read(0, 78);
    final nameBuffer = StringBuffer();
    for (final byte in head.sublist(0, 32)) {
      if (byte == 0) break;

      nameBuffer.writeCharCode(byte);
    }
    final ident = String.fromCharCodes(head.sublist(60, 68)).toUpperCase();
    if (ident != 'BOOKMOBI' && ident != 'TEXTREAD' && ident != 'PNRDPPRS' && ident != 'DATAPLKR') {
      throw InvalidBookException('Unknown book type: $ident');
    }

    final view = ByteData.sublistView(head);
    final recordCount = view.getUint16(76);
    if (recordCount == 0 || 78 + recordCount * 8 > source.length) {
      throw const InvalidBookException('Invalid PDB record table.');
    }

    final tableEnd = 78 + recordCount * 8;
    final table = source.read(78, recordCount * 8);
    final tableView = ByteData.sublistView(table);
    final offsets = List<int>.generate(recordCount, (final i) => tableView.getUint32(i * 8));
    if (offsets.any((final offset) => offset < tableEnd || offset > source.length)) {
      throw const InvalidBookException('Invalid PDB record offset.');
    }

    return PdbRandomAccess._(ident, nameBuffer.toString(), source, recordCount, offsets);
  }

  @override
  final String ident;

  /// The PDB database name (bytes 0..32).
  final String name;

  final ZipByteSource _source;

  /// Number of records declared by the PDB header.
  final int recordCount;

  /// Offset of each record, in record order.
  final List<int> offsets;

  @override
  int get count => recordCount;

  @override
  Uint8List record(final int index) {
    if (index < 0 || index >= recordCount) {
      throw InvalidBookException('Record $index out of range.');
    }

    final start = offsets[index];

    return _source.read(start, recordLength(index));
  }

  /// Reads at most [bytes] of record [index] — the bounded head the
  /// resource classification sniffs.
  @override
  Uint8List recordHead(final int index, final int bytes) {
    if (index < 0 || index >= recordCount) {
      throw InvalidBookException('Record $index out of range.');
    }

    final length = recordLength(index);
    final bounded = length < bytes ? length : bytes;

    return _source.read(offsets[index], bounded);
  }

  /// Computes the length of record [index], with the same
  /// out-of-order recovery the eager header applies.
  int recordLength(final int index) {
    if (index == recordCount - 1) return _source.length - offsets[index];

    final next = offsets[index + 1];
    if (next > offsets[index]) return next - offsets[index];
    // Records stored out of order: use the nearest greater offset.
    var end = _source.length;
    for (final offset in offsets) {
      if (offset > offsets[index] && offset < end) end = offset;
    }

    return end - offsets[index];
  }

  /// Releases the underlying source.
  void close() => _source.close();
}

/// The decompressed MOBI text stream, addressed by text record.
///
/// The open pass decompresses every text record once to learn its
/// length — decompressed sizes are not declared anywhere in the
/// format — and keeps only the (record → stream span) table. Record
/// bytes flow through and are dropped; that pass builds the reading
/// index, not the book's content. Later, [slice] decompresses only the
/// records covering the requested span, with a small LRU over decoded
/// records so adjacent sections share their boundary record.
final class MobiTextStore {
  MobiTextStore._(
    this._pdb,
    this._header,
    this._textOffset,
    this._counter,
    this._unpack,
    this._recordSpans,
    this.streamLength,
  );

  /// Byte budget of the decoded-record LRU. Working-set sized: one
  /// section materialization touches a handful of records.
  static const _recordCacheByteCap = 4 << 20;

  /// Builds the store by running the one-pass decompression index
  /// build over the text records. [onRecord] observes each decoded
  /// record exactly once, in order, with its stream start — the
  /// session header's byte-level scans hook in here without a second
  /// decompression pass.
  factory MobiTextStore.build({
    required final PdbRecordAccess pdb,
    required final MobiHeader header,
    required final int textOffset,
    final int? huffOffsetOverride,
    final SessionMetricsCounter? counter,
    final void Function(int recordIndex, int streamStart, Uint8List decompressed)? onRecord,
  }) {
    final end = header.textRecordCount + textOffset < pdb.count
        ? header.textRecordCount + textOffset
        : pdb.count;
    final unpack = _unpackerFor(pdb, header, huffOffsetOverride, counter);

    final spans = <(int, int)>[];
    var streamStart = 0;
    for (var i = textOffset; i < end; i++) {
      final stripped = stripTrailingEntries(pdb.record(i), header.extraFlags);
      final decoded = unpack(stripped);
      counter?.addDecoded(decoded.length);
      spans.add((streamStart, streamStart + decoded.length));
      onRecord?.call(i, streamStart, decoded);
      streamStart += decoded.length;
    }

    return MobiTextStore._(pdb, header, textOffset, counter, unpack, spans, streamStart);
  }

  final PdbRecordAccess _pdb;
  final MobiHeader _header;
  final int _textOffset;
  final SessionMetricsCounter? _counter;
  final Uint8List Function(Uint8List) _unpack;

  /// (stream start, stream end) of each text record's decompressed
  /// bytes, in record order. The instrumentation expectations derive
  /// from this table.
  final List<(int, int)> _recordSpans;

  /// Total decompressed stream length in bytes.
  final int streamLength;

  final Map<int, Uint8List> _decodedCache = <int, Uint8List>{};
  var _decodedCacheBytes = 0;

  /// The record indexes whose spans intersect [start, end).
  (int, int) recordsCovering(final int start, final int end) {
    var first = -1;
    var last = -1;
    for (var i = 0; i < _recordSpans.length; i++) {
      final (recordStart, recordEnd) = _recordSpans[i];
      if (recordEnd <= start) continue;
      if (recordStart >= end) break;

      if (first == -1) first = i;
      last = i;
    }

    return (first, last);
  }

  /// The decompressed bytes of stream span [start, end). Reads only
  /// the covering records; decoded records cache under the LRU cap.
  Uint8List slice(final int start, final int end) {
    RangeError.checkValidRange(0, end, streamLength, 'start', 'end');
    if (start > end) throw RangeError.range(start, 0, end, 'start');
    if (start == end) return Uint8List(0);

    final (first, last) = recordsCovering(start, end);
    if (first == -1) return Uint8List(0);

    final out = BytesBuilder(copy: false);
    for (var i = first; i <= last; i++) {
      final decoded = _decodedRecord(i);
      final (recordStart, recordEnd) = _recordSpans[i];
      final from = start > recordStart ? start - recordStart : 0;
      final to = end < recordEnd ? end - recordStart : decoded.length;
      out.add(Uint8List.sublistView(decoded, from, to));
    }

    return out.takeBytes();
  }

  Uint8List _decodedRecord(final int index) {
    final cached = _decodedCache[index];
    if (cached != null) {
      // Refresh recency.
      _decodedCache.remove(index);
      _decodedCache[index] = cached;

      return cached;
    }

    final recordIndex = _textOffset + index;
    final stripped = stripTrailingEntries(_pdb.record(recordIndex), _header.extraFlags);
    final decoded = _unpack(stripped);
    _counter?.addDecoded(decoded.length);
    _storeDecoded(index, decoded);

    return decoded;
  }

  void _storeDecoded(final int index, final Uint8List decoded) {
    _decodedCache[index] = decoded;
    _decodedCacheBytes += decoded.length;
    while (_decodedCacheBytes > _recordCacheByteCap && _decodedCache.isNotEmpty) {
      final oldest = _decodedCache.keys.first;
      _decodedCacheBytes -= _decodedCache.remove(oldest)!.length;
    }
  }

  static Uint8List Function(Uint8List) _unpackerFor(
    final PdbRecordAccess pdb,
    final MobiHeader header,
    final int? huffOffsetOverride,
    final SessionMetricsCounter? counter,
  ) {
    if (header.compressionType == 0x4448) {
      final huffOffset = huffOffsetOverride ?? header.huffOffset;
      final sections = <Uint8List>[];
      for (var i = huffOffset; i < huffOffset + header.huffRecordCount; i++) {
        if (i >= pdb.count) break;

        sections.add(pdb.record(i));
      }

      final huff = HuffReader(sections);
      return huff.unpack;
    } else if (header.compressionType == 2) {
      return decompressPalmdoc;
    } else if (header.compressionType == 1) {
      return (final data) => data;
    }

    throw MobiException('Unknown compression algorithm: ${header.compressionType}');
  }
}
