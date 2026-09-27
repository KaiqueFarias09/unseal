import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../exceptions/unseal_exception.dart';
import 'archive_access.dart';
import 'bounded_output_stream.dart';
import 'zip_byte_source.dart';

/// Thrown when a container declares zip64 records. Random access over
/// zip64 needs 64-bit offset handling the reader does not implement;
/// callers open those books through the eager path instead.
final class Zip64NotSupportedException extends UnsealException {
  /// Creates the typed zip64 rejection.
  const Zip64NotSupportedException(super.message);
}

/// One central-directory record: everything needed to inflate a single
/// entry later without touching any other entry.
final class ZipEntryRecord {
  const ZipEntryRecord._({
    required this.name,
    required this.isFile,
    required this.compressionMethod,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  /// Archive path as stored in the container.
  final String name;

  /// Whether the record carries a payload (directories do not).
  final bool isFile;

  /// 0 = stored, 8 = deflate; other methods are rejected at open.
  final int compressionMethod;

  /// Declared CRC-32 of the uncompressed content; verified on every
  /// inflate.
  final int crc32;

  /// Declared compressed size from the central directory.
  final int compressedSize;

  /// Declared uncompressed size from the central directory.
  final int uncompressedSize;

  /// File offset of the entry's local header.
  final int localHeaderOffset;
}

/// Random access over a book zip container: the central directory is
/// parsed once at open and each entry is inflated on demand.
///
/// Security posture matches [decodeBookZip]: encrypted entries, symlink
/// entries and unsupported compression methods are typed rejections at
/// open; declared totals are gated by the zip-bomb caps BEFORE any
/// inflation; per-entry output is bounded while it is produced; and
/// declared CRCs are verified per entry. Zip64 containers are a typed
/// rejection so callers can fall back to the eager path without losing
/// the book.
///
/// Entries are inflated one at a time from freshly read compressed
/// slices, so implementations of [ZipByteSource] never need more than
/// one entry's worth of resident payload.
final class ZipRandomAccess {
  ZipRandomAccess._(this._source, this._records)
    : _byLowerPath = <String, ZipEntryRecord>{
        for (final record in _records)
          if (record.isFile) normalizeZipPath(record.name).toLowerCase(): record,
      };

  final ZipByteSource _source;
  final List<ZipEntryRecord> _records;
  final Map<String, ZipEntryRecord> _byLowerPath;

  /// Parses the central directory of [source] and validates the
  /// container-level guards. Costs no entry inflation.
  factory ZipRandomAccess.open(final ZipByteSource source) {
    final records = _readCentralDirectory(source);
    _assertExpansionBounded(source, records);

    return ZipRandomAccess._(source, records);
  }

  /// Every central-directory record in container order, directories
  /// included (with [ZipEntryRecord.isFile] false).
  List<ZipEntryRecord> get entries => List.unmodifiable(_records);

  /// Declared uncompressed total across all records.
  int get declaredUncompressedBytes =>
      _records.fold(0, (final total, final record) => total + record.uncompressedSize);

  /// Finds an entry by [entryPath] with the same matching preference as
  /// `findArchiveFile`: exact name first, then normalized
  /// case-insensitive; the first record in container order wins.
  ZipEntryRecord? find(final String entryPath) {
    final normalized = normalizeZipPath(entryPath);
    if (normalized.isEmpty) return null;

    for (final record in _records) {
      if (!record.isFile) continue;
      if (record.name == normalized) return record;
    }

    return _byLowerPath[normalized.toLowerCase()];
  }

  /// Whether [entryPath] resolves to a file entry.
  bool containsFile(final String entryPath) => find(entryPath) != null;

  /// Inflates one entry, bounded by [maxBytes] (default: the entry's
  /// declared size capped at [maxZipEntryUncompressedBytes]), verifying
  /// the declared CRC. Missing entries surface through [find].
  Uint8List inflate(final ZipEntryRecord entry, {final int? maxBytes}) {
    final limit = math.min(maxBytes ?? maxZipEntryUncompressedBytes, maxZipEntryUncompressedBytes);
    final compressed = _readCompressedSlice(entry);

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
  Uint8List head(final ZipEntryRecord entry, final int byteCount) {
    if (entry.compressionMethod != _deflateMethod) {
      final compressed = _readCompressedSlice(entry);

      return Uint8List.sublistView(compressed, 0, math.min(byteCount, compressed.length));
    }

    final window = _readCompressedSlice(entry, capBytes: _headCompressedWindow);
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

  /// Releases the underlying byte source.
  void close() => _source.close();

  Uint8List _readCompressedSlice(final ZipEntryRecord entry, {final int? capBytes}) {
    final localHeader = _source.read(
      entry.localHeaderOffset,
      math.min(_localHeaderFixedBytes, math.max(0, _source.length - entry.localHeaderOffset)),
    );
    if (localHeader.length < _localHeaderFixedBytes ||
        _readUint32(localHeader, 0) != _localHeaderSignature) {
      throw InvalidBookException('Zip entry ${entry.name} has an unreadable local header.');
    }

    final nameLength = _readUint16(localHeader, 26);
    final extraLength = _readUint16(localHeader, 28);
    final dataStart = entry.localHeaderOffset + _localHeaderFixedBytes + nameLength + extraLength;
    var sliceLength = entry.compressedSize;
    if (capBytes != null) sliceLength = math.min(sliceLength, capBytes);
    if (dataStart + sliceLength > _source.length) {
      throw InvalidBookException('Zip entry ${entry.name} overruns the container.');
    }

    return _source.read(dataStart, sliceLength);
  }
}

const _localHeaderSignature = 0x04034b50;
const _centralDirectorySignature = 0x02014b50;
const _endOfCentralDirectorySignature = 0x06054b50;
const _localHeaderFixedBytes = 30;
const _storedMethod = 0;
const _deflateMethod = 8;
const _maxEndRecordSearch = 65535 + 22;
const _zip32Marker = 0xFFFFFFFF;

/// Compressed bytes fed to the sniffer's inflate: enough for the first
/// output bytes of real image payloads at any practical compression
/// ratio.
const _headCompressedWindow = 8 << 10;

/// Reads and validates every central-directory record, first to last.
List<ZipEntryRecord> _readCentralDirectory(final ZipByteSource source) {
  final end = _locateEndOfCentralDirectory(source);
  if (end < 0) {
    throw const InvalidBookException(
      'Zip container has a missing or unreadable central directory.',
    );
  }

  final tail = source.read(end, math.min(22, source.length - end));
  final diskNumber = _readUint16(tail, 4);
  final directoryDisk = _readUint16(tail, 6);
  if (diskNumber != 0 || directoryDisk != 0) {
    throw const InvalidBookException('Multi-disk zip containers are not supported.');
  }

  var entryCount = _readUint16(tail, 10);
  final directoryOffset = _readUint32(tail, 16);
  final directorySize = _readUint32(tail, 12);
  if (entryCount == 0xFFFF || directoryOffset == _zip32Marker || directorySize == _zip32Marker) {
    throw const Zip64NotSupportedException(
      'Zip container declares zip64 records, which random access does not support.',
    );
  }
  if (directoryOffset + directorySize > source.length) {
    throw const InvalidBookException('Zip central directory overruns the container.');
  }

  final records = <ZipEntryRecord>[];
  var cursor = directoryOffset;
  final directoryEnd = directoryOffset + directorySize;
  while (entryCount > 0 && cursor + 46 <= directoryEnd) {
    final header = source.read(cursor, 46);
    if (_readUint32(header, 0) != _centralDirectorySignature) {
      throw const InvalidBookException('Zip central directory is corrupt.');
    }

    final flags = _readUint16(header, 8);
    if ((flags & 0x1) != 0) {
      throw InvalidBookException('Encrypted zip entries are not supported.');
    }

    final externalAttributes = _readUint32(header, 38);
    final unixFileType = (externalAttributes >> 16) & 0xF000;
    if (unixFileType == 0xA000) {
      throw const InvalidBookException('Symbolic links are not supported in book containers.');
    }

    final compressionMethod = _readUint16(header, 10);
    if (compressionMethod != _storedMethod && compressionMethod != _deflateMethod) {
      throw InvalidBookException(
        'Zip entry uses unsupported compression method $compressionMethod.',
      );
    }

    final nameLength = _readUint16(header, 28);
    final extraLength = _readUint16(header, 30);
    final commentLength = _readUint16(header, 32);
    final nameBytes = source.read(cursor + 46, nameLength);
    final name = String.fromCharCodes(nameBytes, 0, nameBytes.length);

    final crc = _readUint32(header, 16);
    final compressedSize = _readUint32(header, 20);
    final uncompressedSize = _readUint32(header, 24);
    final localHeaderOffset = _readUint32(header, 42);
    if (compressedSize == _zip32Marker ||
        uncompressedSize == _zip32Marker ||
        localHeaderOffset == _zip32Marker) {
      throw const Zip64NotSupportedException(
        'Zip container declares zip64 records, which random access does not support.',
      );
    }

    records.add(
      ZipEntryRecord._(
        name: name,
        isFile: !name.endsWith('/') && !name.endsWith('\\'),
        compressionMethod: compressionMethod,
        crc32: crc,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localHeaderOffset: localHeaderOffset,
      ),
    );

    cursor += 46 + nameLength + extraLength + commentLength;
    entryCount--;
  }

  return records;
}

/// Offset of the end-of-central-directory record, or -1.
int _locateEndOfCentralDirectory(final ZipByteSource source) {
  final searchStart = math.max(0, source.length - _maxEndRecordSearch);
  const recordLength = 22;
  var cursor = source.length - recordLength;
  while (cursor >= searchStart) {
    final window = source.read(cursor, recordLength);
    if (_readUint32(window, 0) == _endOfCentralDirectorySignature) return cursor;

    cursor--;
  }

  return -1;
}

/// Container-level zip-bomb guards, applied to declared sizes before any
/// inflation, with the same caps as the eager decode path.
void _assertExpansionBounded(final ZipByteSource source, final List<ZipEntryRecord> records) {
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
  if (total > minZipBytesForRatioCheck && source.length > 0) {
    final ratio = total ~/ source.length;
    if (ratio > maxZipExpansionRatio) {
      throw InvalidBookException(
        'Zip container expansion ratio $ratio exceeds the '
        '$maxZipExpansionRatio zip-bomb safety cap.',
      );
    }
  }
}

int _readUint16(final Uint8List bytes, final int offset) {
  if (offset < 0 || offset + 2 > bytes.length) return 0;

  return ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, Endian.little);
}

int _readUint32(final Uint8List bytes, final int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return 0;

  return ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.little);
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
