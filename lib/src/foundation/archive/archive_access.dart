import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

import '../exceptions/unseal_exception.dart';

/// Hard cap on the TOTAL uncompressed size a book zip container may
/// declare (1 GiB) — the first zip-bomb guard, checked from the
/// central directory before any entry is inflated.
const int maxZipTotalUncompressedBytes = 1 << 30;

/// Hard cap on the uncompressed size a single zip entry may declare
/// (512 MiB).
const int maxZipEntryUncompressedBytes = 512 << 20;

/// Maximum aggregate expansion ratio (declared uncompressed bytes vs
/// container bytes) tolerated for books. Real-world books stay below
/// ~20x; hostile archives reach 1000x and beyond.
const int maxZipExpansionRatio = 200;

/// Declared totals below this size skip the ratio check so small
/// legitimate books are never rejected on ratio grounds.
const int minZipBytesForRatioCheck = 32 << 20;

/// Decodes a book zip container under the typed-error contract and
/// bounded-expansion guards.
///
/// Corrupt container bytes make package:archive throw untyped errors
/// (`ArchiveException`, `RangeError`, `FormatException`); those are
/// converted to [InvalidBookException] here, before they can escape a
/// parse entry point. Archive structures declaring more expansion
/// than [maxZipTotalUncompressedBytes] / [maxZipEntryUncompressedBytes]
/// / [maxZipExpansionRatio] are rejected the same way WITHOUT being
/// inflated. Actual output is bounded again while each supported
/// entry is materialized, so forged sizes cannot bypass the guard.
///
Archive decodeBookZip(final Uint8List bytes) {
  assertZipExpansionBounded(bytes);
  try {
    final decoded = ZipDecoder().decodeBytes(bytes);
    if (decoded.files.isEmpty) {
      // archive 4 silently yields an empty archive when the EOCD or the
      // central directory cannot be read; a book container never is.
      throw const InvalidBookException(
        'Zip container has a missing or unreadable central directory.',
      );
    }
    final archive = Archive()..comment = decoded.comment;
    final actualTotalLimit = math.min(
      maxZipTotalUncompressedBytes,
      math.max(minZipBytesForRatioCheck, bytes.length * maxZipExpansionRatio),
    );
    var actualTotal = 0;
    for (final file in decoded.files) {
      final compression = file.compression;
      if (compression != CompressionType.none && compression != CompressionType.deflate) {
        throw InvalidBookException(
          'Zip entry ${file.name} uses unsupported compression method '
          '$compression.',
        );
      }
      final remainingTotal = actualTotalLimit - actualTotal;
      if (remainingTotal <= 0) {
        throw InvalidBookException('Zip container exceeds the bounded expansion limit.');
      }
      final output = _BoundedOutputStream(math.min(maxZipEntryUncompressedBytes, remainingTotal));
      final rawContent = file.rawContent;
      if (rawContent == null) {
        if (file.isFile) {
          throw InvalidBookException('Zip entry ${file.name} has no readable payload.');
        }
        // Directory records carry no payload; keep them as empty entries so
        // containers that store them explicitly still parse.
        archive.addFile(ArchiveFile(file.name, 0, Uint8List(0))..isFile = false);
        continue;
      }
      final rawStream = rawContent.getStream(decompress: false);
      if (compression == CompressionType.deflate) {
        Inflate.stream(rawStream, output: output);
      } else {
        output.writeStream(rawStream);
      }
      final content = output.getBytes();
      if (file.crc32 != null && getCrc32(content) != file.crc32) {
        throw InvalidBookException('Zip entry ${file.name} has an invalid checksum.');
      }
      actualTotal += content.length;
      final materialized = ArchiveFile.bytes(file.name, content)
        ..mode = file.mode
        ..isFile = file.isFile
        ..symbolicLink = file.symbolicLink
        ..crc32 = file.crc32
        ..comment = file.comment
        ..lastModTime = file.lastModTime;
      archive.addFile(materialized);
    }

    return archive;
  } on UnsealException {
    rethrow;
  } on Object catch (error) {
    throw InvalidBookException('Zip container could not be decoded (${error.runtimeType}).');
  }
}

/// OutputStream that aborts, with a typed error, the moment a write would
/// push the entry past [maxBytes] — bounding zip-bomb expansion DURING
/// inflation instead of after it.
final class _BoundedOutputStream extends OutputStream {
  _BoundedOutputStream(this.maxBytes)
    : _buffer = Uint8List(math.min(maxBytes, 0x8000)),
      super(byteOrder: ByteOrder.littleEndian);

  Uint8List _buffer;
  final int maxBytes;

  @override
  int length = 0;

  void _ensureCapacity(final int additionalBytes) {
    if (additionalBytes < 0 || length + additionalBytes > maxBytes) {
      throw InvalidBookException('Zip entry exceeds the bounded expansion limit.');
    }
  }

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

  @override
  void writeByte(final int value) {
    _ensureCapacity(1);
    _grow(length + 1);
    _buffer[length++] = value;
  }

  @override
  void writeBytes(final List<int> bytes, {final int? length}) {
    final count = length ?? bytes.length;
    _ensureCapacity(count);
    _grow(this.length + count);
    _buffer.setRange(this.length, this.length + count, bytes);
    this.length += count;
  }

  @override
  void writeStream(final InputStream stream) {
    _ensureCapacity(stream.length);
    _grow(length + stream.length);
    _buffer.setRange(length, length + stream.length, stream.toUint8List());
    length += stream.length;
  }

  @override
  void writeBackReference(final int distance, final int count) {
    _ensureCapacity(count);
    _grow(length + count);
    final source = length - distance;
    if (distance >= count) {
      _buffer.setRange(length, length + count, _buffer, source);
    } else {
      var from = source;
      var to = length;
      final end = length + count;
      while (to < end) {
        _buffer[to++] = _buffer[from++];
      }
    }
    length += count;
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

    return Uint8List.view(_buffer.buffer, _buffer.offsetInBytes + start, end - start);
  }
}

/// Reads the central directory header sizes without inflating
/// anything and rejects containers whose declared expansion breaks
/// the caps. Returns silently when the directory is unreadable —
/// [ZipDecoder] produces the typed failure for those.
void assertZipExpansionBounded(final Uint8List bytes) {
  final declared = _declaredUncompressed(bytes);
  if (declared == null) return;
  final (total, largest) = declared;
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
  if (total > minZipBytesForRatioCheck && bytes.isNotEmpty) {
    final ratio = total ~/ bytes.length;
    if (ratio > maxZipExpansionRatio) {
      throw InvalidBookException(
        'Zip container expansion ratio $ratio exceeds the '
        '$maxZipExpansionRatio zip-bomb safety cap.',
      );
    }
  }
}

/// Total and largest declared uncompressed sizes from the zip central
/// directory, or null when it cannot be located/parsed.
(int, int)? _declaredUncompressed(final Uint8List bytes) {
  const eocdSignature = 0x06054b50;
  const centralSignature = 0x02014b50;
  // ZIP compression methods: 0 = stored, 8 = deflate.
  const storeMethod = 0;
  const deflateMethod = 8;
  const maxComment = 65535 + 22;
  final eocdStart = bytes.length - maxComment < 0 ? 0 : bytes.length - maxComment;
  var eocd = -1;
  for (var pos = bytes.length - 4; pos >= eocdStart && pos >= 0; pos--) {
    if (_readUint32(bytes, pos) == eocdSignature) {
      eocd = pos;
      break;
    }
  }

  if (eocd < 0) return null;
  var entryCount = _readUint16(bytes, eocd + 10);
  var cursor = _readUint32(bytes, eocd + 16);
  final directoryEnd =
      cursor < bytes.length && cursor + _readUint32(bytes, eocd + 12) <= bytes.length
      ? cursor + _readUint32(bytes, eocd + 12)
      : bytes.length;
  var total = 0;
  var largest = 0;
  while (entryCount > 0 && cursor + 46 <= directoryEnd) {
    if (_readUint32(bytes, cursor) != centralSignature) return null;
    final flags = _readUint16(bytes, cursor + 8);
    final compressionMethod = _readUint16(bytes, cursor + 10);
    final externalAttributes = _readUint32(bytes, cursor + 38);
    final unixFileType = (externalAttributes >> 16) & 0xF000;
    if ((flags & 0x1) != 0) {
      throw InvalidBookException('Encrypted zip entries are not supported.');
    }
    if (compressionMethod != storeMethod && compressionMethod != deflateMethod) {
      throw InvalidBookException(
        'Zip entry uses unsupported compression method $compressionMethod.',
      );
    }
    if (unixFileType == 0xA000) {
      throw InvalidBookException('Symbolic links are not supported in book containers.');
    }
    final uncompressed = _readUint32(bytes, cursor + 24);
    total += uncompressed;
    if (uncompressed > largest) largest = uncompressed;
    final nameLength = _readUint16(bytes, cursor + 28);
    final extraLength = _readUint16(bytes, cursor + 30);
    final commentLength = _readUint16(bytes, cursor + 32);
    cursor += 46 + nameLength + extraLength + commentLength;
    entryCount--;
  }

  return (total, largest);
}

int _readUint16(final Uint8List bytes, final int offset) {
  if (offset < 0 || offset + 2 > bytes.length) return 0;

  return ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, Endian.little);
}

int _readUint32(final Uint8List bytes, final int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return 0;

  return ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.little);
}

/// Finds an archive entry by [entryPath] with exact, normalized and case-insensitive matching.
///
/// Manifest hrefs are relative to their manifest file, so callers should resolve them with
/// [resolveItemPath] first.
ArchiveFile? findArchiveFile(final Archive archive, final String entryPath) {
  final normalized = normalizeZipPath(entryPath);
  if (normalized.isEmpty) return null;

  for (final file in archive.files) {
    if (!file.isFile) continue;

    final normalizedFileName = normalizeZipPath(file.name).toLowerCase();
    if (file.name != normalized && normalizedFileName != normalized.toLowerCase()) continue;

    return file;
  }

  return null;
}

/// Resolves a manifest [href] against its [rootFilePath], handling fragments and `..` segments.
String resolveItemPath(final String? rootFilePath, final String href) {
  final hrefWithoutFragment = href.split('#').first;
  final directory = path.posix.dirname(rootFilePath ?? '');

  return normalizeZipPath(
    directory == '.' || directory.isEmpty ? hrefWithoutFragment : '$directory/$hrefWithoutFragment',
  );
}

/// Normalizes a zip entry path: forward slashes, resolved `.`/`..` segments, no leading slash.
String normalizeZipPath(final String zipPath) {
  final segments = <String>[];
  for (final segment in zipPath.split('/')) {
    if (segment.isEmpty || segment == '.') continue;

    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }

    segments.add(segment);
  }

  return segments.join('/');
}

/// Returns archive entry content as a [Uint8List] without copying; the
/// archive decodes entries into typed byte lists.
Uint8List contentBytes(final ArchiveFile entry) => Uint8List.sublistView(entry.content);
