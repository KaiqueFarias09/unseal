import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../exceptions/unseal_exception.dart';
import 'archive_access.dart';
import 'async_archive_random_access.dart';
import 'async_byte_reader.dart';
import 'bounded_output_stream.dart';
import 'zip_random_access.dart';

/// Random access over a book zip container served by an asynchronous
/// byte reader — the remote-source twin of [`ZipRandomAccess`], with
/// the same security posture and the same acceptance rules (both paths
/// share the central-directory record decoder).
///
/// Partial-reading shape: the open costs one end-of-central-directory
/// tail read plus bounded central-directory window reads; each entry
/// costs one local-header read and one payload read. A stored entry's
/// payload can be requested as an exact sub-slice; a Deflate entry's
/// real decompression unit is its whole compressed payload, and that
/// is exactly what gets requested — never a speculative download of
/// the container.
final class AsyncZipRandomAccess implements AsyncArchiveRandomAccess {
  AsyncZipRandomAccess._(this._reader, this._records) : _byLowerPath = _indexByLowerPath(_records);

  final AsyncByteReader _reader;
  final List<ZipEntryRecord> _records;
  final Map<String, ZipEntryRecord> _byLowerPath;

  /// Parses the central directory of [reader] and validates the
  /// container-level guards. Costs no entry inflation: one tail read
  /// plus bounded directory windows.
  static Future<AsyncZipRandomAccess> open(final AsyncByteReader reader) async {
    final records = await _readCentralDirectory(reader);
    _assertExpansionBounded(reader, records);

    return AsyncZipRandomAccess._(reader, records);
  }

  /// Every central-directory record in container order, directories
  /// included (with [ZipEntryRecord.isFile] false).
  @override
  List<ZipEntryRecord> get entries => List.unmodifiable(_records);

  /// Finds an entry by [entryPath] with the same matching preference as
  /// the synchronous reader: the first record with an exact or
  /// normalized case-insensitive path match wins.
  @override
  ZipEntryRecord? find(final String entryPath) {
    final normalized = normalizeZipPath(entryPath);
    if (normalized.isEmpty) return null;

    return _byLowerPath[normalized.toLowerCase()];
  }

  /// Inflates one entry, bounded by [maxBytes] (default: the entry's
  /// declared size capped at [maxZipEntryUncompressedBytes]), verifying
  /// the declared CRC. Missing entries surface through [find].
  @override
  Future<Uint8List> inflate(covariant final ZipEntryRecord entry, {final int? maxBytes}) async {
    final limit = math.min(maxBytes ?? maxZipEntryUncompressedBytes, maxZipEntryUncompressedBytes);
    final compressed = await _readCompressedSlice(entry);

    try {
      final output = BoundedOutputStream(math.min(limit, entry.uncompressedSize));
      if (entry.compressionMethod == _deflateMethod) {
        Inflate.stream(InputMemoryStream(compressed), output: output);
      } else {
        output.writeBytes(compressed);
      }
      final content = output.subset(0, output.length);
      if (getCrc32(content) != entry.crc32) {
        throw InvalidBookException('Zip entry ${entry.name} has an invalid checksum.');
      }

      return Uint8List.fromList(content);
    } on UnsealException {
      // Byte-source and policy failures are already typed; rethrow.
      rethrow;
    } on Object catch (error) {
      throw InvalidBookException(
        'Zip entry ${entry.name} could not be decoded (${error.runtimeType}).',
      );
    }
  }

  /// Returns the first [byteCount] uncompressed bytes of [entry], or as
  /// many as the entry yields — enough for content sniffing without
  /// materializing the payload. Never throws for truncated deflate
  /// input: a partial prefix is a valid answer.
  @override
  Future<Uint8List> head(covariant final ZipEntryRecord entry, final int byteCount) async {
    if (entry.compressionMethod != _deflateMethod) {
      final compressed = await _readCompressedSlice(entry, capBytes: byteCount);

      return Uint8List.sublistView(compressed, 0, math.min(byteCount, compressed.length));
    }

    final window = await _readCompressedSlice(entry, capBytes: _headCompressedWindow);
    final output = _HeadCaptureStream(byteCount);
    try {
      Inflate.stream(InputMemoryStream(window), output: output);
    } on _HeadComplete {
      // The prefix filled; that is the answer.
    } on Object {
      // Truncated window or malformed stream: the captured prefix (possibly
      // empty) is still the best-effort sniff input.
    }

    return output.captured();
  }

  /// Releases the underlying byte reader. Remote readers proxy a
  /// host-owned source, so the actual close belongs to the transport's
  /// gate; this only detaches.
  @override
  Future<void> close() async => _reader.close();

  Future<Uint8List> _readCompressedSlice(final ZipEntryRecord entry, {final int? capBytes}) async {
    final sourceLength = _reader.length;
    final headerLength = math.min(
      _localHeaderFixedBytes,
      math.max(0, sourceLength - entry.localHeaderOffset),
    );
    final localHeader = await _reader.read(entry.localHeaderOffset, headerLength);
    if (localHeader.length < _localHeaderFixedBytes ||
        zipReadUint32(localHeader, 0) != _localHeaderSignature) {
      throw InvalidBookException('Zip entry ${entry.name} has an unreadable local header.');
    }

    final nameLength = zipReadUint16(localHeader, 26);
    final extraLength = zipReadUint16(localHeader, 28);
    final dataStart = entry.localHeaderOffset + _localHeaderFixedBytes + nameLength + extraLength;
    var sliceLength = entry.compressedSize;
    if (capBytes != null) sliceLength = math.min(sliceLength, capBytes);
    if (dataStart + sliceLength > sourceLength) {
      throw InvalidBookException('Zip entry ${entry.name} overruns the container.');
    }

    return _reader.read(dataStart, sliceLength);
  }
}

Map<String, ZipEntryRecord> _indexByLowerPath(final List<ZipEntryRecord> records) {
  final index = <String, ZipEntryRecord>{};
  for (final record in records) {
    if (!record.isFile) continue;

    final normalized = normalizeZipPath(record.name);
    if (normalized.isNotEmpty) index.putIfAbsent(normalized.toLowerCase(), () => record);
  }

  return index;
}

const _localHeaderSignature = 0x04034b50;
const _endOfCentralDirectorySignature = 0x06054b50;
const _localHeaderFixedBytes = 30;
const _deflateMethod = 8;
const _maxEndRecordSearch = 65535 + 22;
const _zip32Marker = 0xFFFFFFFF;

/// Compressed bytes fed to the sniffer's inflate: enough for the first
/// output bytes of real image payloads at any practical compression
/// ratio.
const _headCompressedWindow = 8 << 10;

/// Central-directory bytes fetched per windowed read. Records larger
/// than one window trigger a single exact re-fetch, so hostile
/// declarations cannot inflate the transfer beyond the record's real
/// size.
const _directoryWindowBytes = 64 << 10;

/// Reads and validates every central-directory record, first to last,
/// through windowed range reads: the reader never asks for more than
/// one window (or one oversized record) at a time.
Future<List<ZipEntryRecord>> _readCentralDirectory(final AsyncByteReader reader) async {
  final sourceLength = reader.length;
  final tailLength = math.min(sourceLength, _maxEndRecordSearch);
  final tail = await reader.read(sourceLength - tailLength, tailLength);
  final end = _locateEndOfCentralDirectoryInTail(tail);
  if (end < 0) {
    throw const InvalidBookException(
      'Zip container has a missing or unreadable central directory.',
    );
  }

  final tailRecord = Uint8List.sublistView(tail, end, math.min(end + 22, tail.length));
  final diskNumber = zipReadUint16(tailRecord, 4);
  final directoryDisk = zipReadUint16(tailRecord, 6);
  if (diskNumber != 0 || directoryDisk != 0) {
    throw const InvalidBookException('Multi-disk zip containers are not supported.');
  }

  var entryCount = zipReadUint16(tailRecord, 10);
  final directoryOffset = zipReadUint32(tailRecord, 16);
  final directorySize = zipReadUint32(tailRecord, 12);
  if (entryCount == 0xFFFF || directoryOffset == _zip32Marker || directorySize == _zip32Marker) {
    throw const Zip64NotSupportedException(
      'Zip container declares zip64 records, which random access does not support.',
    );
  }
  if (directoryOffset + directorySize > sourceLength) {
    throw const InvalidBookException('Zip central directory overruns the container.');
  }

  final records = <ZipEntryRecord>[];
  var cursor = directoryOffset;
  final directoryEnd = directoryOffset + directorySize;
  while (entryCount > 0 && cursor + 46 <= directoryEnd) {
    final windowLength = math.min(_directoryWindowBytes, directoryEnd - cursor);
    var window = await reader.read(cursor, windowLength);
    var pos = 0;
    var consumed = 0;
    while (entryCount > 0 && cursor + 46 <= directoryEnd && pos + 46 <= window.length) {
      final header = Uint8List.sublistView(window, pos, pos + 46);
      // Signature first, so a corrupt directory fails typed even when
      // the record's declared name would overrun the window.
      if (zipReadUint32(header, 0) != 0x02014b50) {
        throw const InvalidBookException('Zip central directory is corrupt.');
      }

      final nameLength = zipReadUint16(header, 28);
      final extraLength = zipReadUint16(header, 30);
      final commentLength = zipReadUint16(header, 32);
      final recordEnd = pos + 46 + nameLength + extraLength + commentLength;
      if (recordEnd > window.length) {
        // One exact re-fetch covering the record — the synchronous
        // reader serves names straight from the source, so a record
        // bigger than the window must still decode, bounded by the
        // record's real size.
        final recordLength = recordEnd - pos;
        final fetchLength = math.min(recordLength, reader.length - cursor);
        if (fetchLength < recordLength) {
          // The record claims more bytes than the container has.
          throw const InvalidBookException('Zip central directory record overruns the container.');
        }
        window = await reader.read(cursor, fetchLength);
        continue;
      }

      final nameBytes = Uint8List.sublistView(window, pos + 46, pos + 46 + nameLength);
      records.add(decodeZipCentralDirectoryRecord(header: header, nameBytes: nameBytes));
      final recordLength = recordEnd - pos;
      pos = recordEnd;
      cursor += recordLength;
      consumed += recordLength;
      entryCount--;
    }

    if (consumed == 0) break;
  }

  return records;
}

/// Relative offset of the end-of-central-directory record inside the
/// fetched tail, or -1.
int _locateEndOfCentralDirectoryInTail(final Uint8List tail) {
  const recordLength = 22;
  var cursor = tail.length - recordLength;
  while (cursor >= 0) {
    if (zipReadUint32(tail, cursor) == _endOfCentralDirectorySignature) return cursor;

    cursor--;
  }

  return -1;
}

/// Container-level zip-bomb guards over declared sizes, applied before
/// any inflation, with the same caps as the synchronous path.
void _assertExpansionBounded(final AsyncByteReader reader, final List<ZipEntryRecord> records) {
  var total = 0;
  var largest = 0;
  for (final record in records) {
    total += record.uncompressedSize;
    if (record.uncompressedSize > largest) largest = record.uncompressedSize;
  }

  if (total > maxZipTotalUncompressedBytes) {
    throw InvalidBookException(
      'Zip container declares $total uncompressed bytes, above the '
      '$maxZipTotalUncompressedBytes-byte safety cap.',
    );
  }
  if (largest > maxZipEntryUncompressedBytes) {
    throw InvalidBookException(
      'Zip entry declares $largest uncompressed bytes, above the '
      '$maxZipEntryUncompressedBytes-byte safety cap.',
    );
  }
  if (total > minZipBytesForRatioCheck && reader.length > 0) {
    final ratio = total ~/ reader.length;
    if (ratio > maxZipExpansionRatio) {
      throw InvalidBookException(
        'Zip container expansion ratio $ratio exceeds the '
        '$maxZipExpansionRatio zip-bomb safety cap.',
      );
    }
  }
}

/// Output stream that captures the first [maxBytes] bytes and then
/// aborts the inflater with [_HeadComplete] — the caller treats that as
/// success.
final class _HeadCaptureStream extends OutputStream {
  _HeadCaptureStream(this.maxBytes)
    : _buffer = Uint8List(math.min(maxBytes, 0x10000)),
      super(byteOrder: ByteOrder.littleEndian);

  final int maxBytes;
  Uint8List _buffer;

  @override
  int length = 0;

  @override
  void writeByte(final int value) {
    if (length >= maxBytes) throw const _HeadComplete();
    _grow(length + 1);
    _buffer[length++] = value;
  }

  @override
  void writeBytes(final List<int> bytes, {final int? length}) {
    final count = length ?? bytes.length;
    var offset = 0;
    while (offset < count) {
      if (this.length >= maxBytes) throw const _HeadComplete();
      _grow(this.length + 1);
      final chunk = math.min(count - offset, maxBytes - this.length);
      _buffer.setRange(this.length, this.length + chunk, bytes, offset);
      this.length += chunk;
      offset += chunk;
    }
  }

  @override
  void writeStream(final InputStream stream) => writeBytes(stream.toUint8List());

  @override
  void writeBackReference(final int distance, final int count) {
    final source = length - distance;
    for (var i = 0; i < count; i++) {
      if (length >= maxBytes) throw const _HeadComplete();
      writeByte(_buffer[source + i]);
    }
  }

  @override
  void clear() => length = 0;

  @override
  void flush() {}

  @override
  Uint8List subset(int start, [int? end]) {
    if (start < 0) start = length + start;
    end ??= length;
    if (end < 0) end = length + end;

    return Uint8List.sublistView(_buffer, start, end);
  }

  Uint8List captured() => Uint8List.sublistView(_buffer, 0, length);

  void _grow(final int required) {
    if (required <= _buffer.length) return;
    var capacity = _buffer.length;
    while (capacity < required) {
      capacity = math.min(maxBytes, capacity * 2);
    }
    final grown = Uint8List(capacity);
    grown.setRange(0, length, _buffer);
    _buffer = grown;
  }
}

final class _HeadComplete {
  const _HeadComplete();
}
