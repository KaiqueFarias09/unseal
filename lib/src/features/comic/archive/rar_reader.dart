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
    return decodeRar4Method29(packed, unpackedSize);
  } on FormatException {
    return Uint8List(0);
  }
}

List<_RarEntry> _readRar5(final Uint8List bytes) {
  final container = readRar5Structure(MemoryZipByteSource(bytes));
  final entries = <_RarEntry>[];

  // One decoder drives the whole container in order: solid chains
  // continue the carried dictionary, non-solid entries reset it — the
  // exact sequencing the session path uses.
  final decoder = Rar5SolidDecoder();
  for (final header in container.entries) {
    final reason = header.unsupportedReason(sourceLength: bytes.length);
    if (reason != null && !header.isDirectory) {
      throw ComicException('RAR entry "${header.name}" is not supported: $reason.');
    }

    // Stored payloads stay verbatim; supported compressed payloads
    // decode through the shared RAR 5 decoder. Every path verifies the
    // declared data CRC-32 (zero included) and the declared BLAKE2sp
    // digest (zero digest included) — one correct checksum never
    // excuses the other.
    Uint8List data;
    if (header.isStored) {
      final intact =
          !header.isDirectory &&
          header.unpackedSize == header.packedSize &&
          header.dataStart + header.packedSize <= bytes.length;
      data = intact
          ? Uint8List.sublistView(bytes, header.dataStart, header.dataStart + header.packedSize)
          : Uint8List(0);
    } else if (header.isDirectory) {
      data = Uint8List(0);
    } else {
      final packed = Uint8List.sublistView(
        bytes,
        header.dataStart,
        header.dataStart + header.packedSize,
      );
      try {
        data = decoder.decodeEntry(
          packed: packed,
          uncompressedSize: header.unpackedSize,
          windowSize: header.dictSize,
          solid: header.solid,
        );
      } on FormatException catch (error) {
        throw ComicException('RAR entry "${header.name}" could not be decoded ($error).');
      }
    }
    if (header.hasDataCrc && data.isNotEmpty && getCrc32(data) != header.dataCrc32) {
      throw ComicException('RAR entry "${header.name}" has an invalid checksum.');
    }
    final digest = header.blake2spDigest;
    if (digest != null) {
      verifyRar5Blake2sp(name: header.name, content: data, digest: digest);
    }
    entries.add(
      _RarEntry(
        name: header.name,
        isDirectory: header.isDirectory,
        isCompressed: !header.isDirectory && !header.isStored,
        data: data,
      ),
    );
  }

  return entries;
}
