part of '../parse_comic_book.dart';

/// An entry extracted from a RAR archive.
class _RarEntry {
  /// Creates an entry extracted from a RAR archive.
  const _RarEntry({
    required this.name,
    required this.isDirectory,
    required this.isCompressed,
    required this.data,
  });

  /// Entry name (path inside the archive).
  final String name;

  /// Whether the entry is a directory.
  final bool isDirectory;

  /// Whether the payload uses archive compression.
  final bool isCompressed;

  /// The decoded payload bytes when the entry format is supported.
  ///
  /// Unsupported compressed entries have an empty payload and retain the compressed flag so callers
  /// can report a useful error.
  final Uint8List data;
}

/// Reads entries from RAR 4 and RAR 5 archives.
///
/// Stored entries and ordinary non-solid RAR 2.9/3.x entries carry decoded data. Other compressed
/// entries retain the compressed flag and have an empty payload so callers can explain the
/// limitation.
List<_RarEntry> _readRarEntries(final Uint8List bytes) {
  if (bytes.length < 8) throw const ComicException('File is too small to be a RAR archive.');

  final isRar4 =
      bytes[0] == 0x52 &&
      bytes[1] == 0x61 &&
      bytes[2] == 0x72 &&
      bytes[3] == 0x21 &&
      bytes[4] == 0x1A &&
      bytes[5] == 0x07 &&
      bytes[6] == 0x00;
  final isRar5 =
      bytes[0] == 0x52 &&
      bytes[1] == 0x61 &&
      bytes[2] == 0x72 &&
      bytes[3] == 0x21 &&
      bytes[4] == 0x1A &&
      bytes[5] == 0x07 &&
      bytes[6] == 0x01 &&
      bytes[7] == 0x00;
  if (!isRar4 && !isRar5) throw const ComicException('Not a RAR archive.');

  return isRar4 ? _readRar4(bytes) : _readRar5(bytes);
}

List<_RarEntry> _readRar4(final Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final entries = <_RarEntry>[];
  var offset = 7; // signature marker

  while (offset + 7 <= bytes.length) {
    final blockType = bytes[offset + 2];
    final flags = view.getUint16(offset + 3, Endian.little);
    final headSize = view.getUint16(offset + 5, Endian.little);
    if (headSize < 7) break;

    if (blockType == 0x74) {
      // File header.
      if (offset + 32 > bytes.length) break;

      var field = offset + 7;
      final packSize = view.getUint32(field, Endian.little);
      field += 4;
      final unpSize = view.getUint32(field, Endian.little);
      field += 4;
      field += 1; // host OS
      field += 4; // file CRC
      field += 4; // file time
      final unpackVersion = bytes[field];
      field += 1;
      final method = bytes[field];
      field += 1;
      final nameSize = view.getUint16(field, Endian.little);
      field += 2;
      field += 4; // attributes
      if (flags & 0x0100 != 0) {
        field += 8; // high pack/unp sizes
      }
      if (flags & 0x0400 != 0) {
        field += 8; // salt
      }
      final nameEnd = field + nameSize;
      if (nameEnd > bytes.length) break;

      final name = String.fromCharCodes(bytes.sublist(field, nameEnd));
      final isDirectory = (flags & 0xE0) == 0xE0;
      final dataStart = offset + headSize;
      final dataEnd = dataStart + packSize;
      final stored = method == 0x30;
      final packed = dataEnd <= bytes.length
          ? Uint8List.sublistView(bytes, dataStart, dataEnd)
          : Uint8List(0);
      final data = stored && dataEnd <= bytes.length && unpSize == packSize
          ? packed
          : !stored
          ? _decodeRar4Entry(packed, unpSize, method, unpackVersion, flags)
          : Uint8List(0);
      entries.add(
        _RarEntry(name: name, isDirectory: isDirectory, isCompressed: !stored, data: data),
      );
      if (!isDirectory && flags & 0x8000 != 0) {
        offset = dataEnd;
      } else {
        offset += headSize;
      }
    } else {
      // Skip marker/end/other blocks by header size.
      offset += headSize;

      if (blockType == 0x7B) {
        break; // end of archive
      }
    }
  }

  return entries;
}

Uint8List _decodeRar4Entry(
  final Uint8List packed,
  final int unpackedSize,
  final int method,
  final int unpackVersion,
  final int flags,
) {
  if (packed.isEmpty ||
      unpackedSize == 0 ||
      method < 0x31 ||
      method > 0x35 ||
      unpackVersion != 29) {
    return Uint8List(0);
  }

  // The synchronous reader supports ordinary non-solid RAR 2.9/3.x streams. Password-protected,
  // split, and solid entries need state that cannot be reconstructed one entry at a time here.
  if (flags & 0x0017 != 0) return Uint8List(0);

  try {
    return _decodeRar4Method29(packed, unpackedSize);
  } on FormatException {
    return Uint8List(0);
  }
}

List<_RarEntry> _readRar5(final Uint8List bytes) {
  final entries = <_RarEntry>[];
  var offset = 8; // signature

  while (offset + 8 <= bytes.length) {
    final blockStart = offset;
    offset += 4; // header CRC32 (unverified)
    final (headerSize, consumedH) = _vint(bytes, offset);
    offset += consumedH;
    // Header size counts from the type field to the end of the header, excluding the CRC and the
    // size vint itself.
    final headerEnd = offset + headerSize;
    if (headerEnd > bytes.length) break;

    final (headerType, consumedT) = _vint(bytes, offset);
    offset += consumedT;
    final (headerFlags, consumedF) = _vint(bytes, offset);
    offset += consumedF;
    var extraAreaSize = 0;
    if (headerFlags & 0x0001 != 0) {
      // RAR 5 stores EXTRA_AREA_SIZE before DATA_SIZE in the common header.
      final (size, consumedE) = _vint(bytes, offset);
      extraAreaSize = size;
      offset += consumedE;
    }
    var dataSize = 0;
    if (headerFlags & 0x0002 != 0) {
      final (size, consumedD) = _vint(bytes, offset);
      dataSize = size;
      offset += consumedD;
    }

    if (headerType == 2) {
      // File header.
      final (fileFlags, consumedFF) = _vint(bytes, offset);
      offset += consumedFF;
      final (unpackedSize, consumedU) = _vint(bytes, offset);
      offset += consumedU;
      final (_, consumedA) = _vint(bytes, offset);
      offset += consumedA; // attributes
      if (fileFlags & 0x0002 != 0) {
        offset += 4; // mtime
      }
      if (fileFlags & 0x0004 != 0) {
        offset += 4; // data CRC
      }
      final (compressionInfo, consumedC) = _vint(bytes, offset);
      offset += consumedC;
      offset += 1; // host OS
      final (nameLength, consumedN) = _vint(bytes, offset);
      offset += consumedN;
      final nameEnd = offset + nameLength;
      if (nameEnd > headerEnd) break;

      final name = String.fromCharCodes(bytes.sublist(offset, nameEnd));
      final extraAreaEnd = nameEnd + extraAreaSize;
      if (extraAreaEnd > headerEnd) break;

      final isDirectory = fileFlags & 0x0001 != 0;
      final method = (compressionInfo >> 7) & 0x07;
      final stored = method == 0;
      final dataStart = headerEnd;
      final dataEnd = dataStart + dataSize;
      final hasData = stored && !isDirectory && dataEnd <= bytes.length && unpackedSize == dataSize;
      entries.add(
        _RarEntry(
          name: name,
          isDirectory: isDirectory,
          isCompressed: !stored,
          data: hasData ? Uint8List.sublistView(bytes, dataStart, dataEnd) : Uint8List(0),
        ),
      );
    }
    offset = headerEnd + dataSize;

    if (headerType == 5) {
      break; // end of archive (1 = main header, skipped above)
    }
    if (offset <= blockStart) {
      break; // guard against malformed headers
    }
  }

  return entries;
}

/// Reads a RAR 5 vint (LEB128, 7 bits per byte).
(int, int) _vint(final Uint8List bytes, final int offset) {
  var value = 0;
  var shift = 0;
  var consumed = 0;
  while (offset + consumed < bytes.length) {
    final byte = bytes[offset + consumed];
    consumed++;
    value |= (byte & 0x7F) << shift;
    if (byte & 0x80 == 0) break;

    shift += 7;
    if (shift > 63) break;
  }

  return (value, consumed);
}
