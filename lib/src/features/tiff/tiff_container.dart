import 'dart:typed_data';

import 'tiff_exception.dart';
import 'tiff_limits.dart';

/// One TIFF IFD entry: tag, field type, value count, and the resolved
/// absolute position of the value bytes (inline or out-of-line).
final class TiffIfdEntry {
  /// Creates the entry view.
  const TiffIfdEntry(this.tag, this.type, this.count, this.valueOffset);

  /// The field tag (e.g. 256 = ImageWidth).
  final int tag;

  /// The TIFF field type id (1 BYTE .. 18 IFD8).
  final int type;

  /// The number of values of [type] in the field.
  final int count;

  /// Absolute file offset of the first value byte.
  final int valueOffset;
}

/// One image file directory: the tags of a single TIFF page.
final class TiffIfd {
  TiffIfd._(this.offset, this.entries);

  /// The file offset of this directory.
  final int offset;

  final Map<int, TiffIfdEntry> _byTag = {};

  /// Every entry of this directory, in file order.
  final List<TiffIfdEntry> entries;

  /// The entry for [tag], when present.
  TiffIfdEntry? operator [](final int tag) => _byTag[tag];

  /// Every entry of this directory, in file order.

  void _index() {
    for (final entry in entries) {
      // Duplicate tags: the first occurrence wins, matching libtiff.
      _byTag.putIfAbsent(entry.tag, () => entry);
    }
  }
}

/// The typed TIFF value readers over one container.
///
/// Every read validates the byte range against the file bounds before
/// touching data, and every list read validates its count before
/// allocating — the limits-before-allocation house posture.
extension TiffValueReader on TiffContainer {
  /// Reads one unsigned integer value of [entry] at [index].
  ///
  /// Supports BYTE, SHORT, LONG, LONG8, IFD8 (and their signed
  /// re-interpretations, which untrusted files use interchangeably).
  int readUint(final TiffIfdEntry entry, [final int index = 0]) {
    if (index < 0 || index >= entry.count) {
      throw TiffException('TIFF tag ${entry.tag} value index $index is out of range.');
    }
    switch (entry.type) {
      case 1: // BYTE
      case 6: // SBYTE
      case 7: // UNDEFINED
        return bytes[entry.valueOffset + index];
      case 3: // SHORT
      case 8: // SSHORT
        return _u16(entry.valueOffset + index * 2);
      case 4: // LONG
      case 9: // SLONG
        return _u32(entry.valueOffset + index * 4);
      case 16: // LONG8
      case 17: // SLONG8
      case 18: // IFD8
        return _u64InAddressableRange(entry.valueOffset + index * 8, 'TIFF tag ${entry.tag}');
      default:
        throw TiffException('TIFF tag ${entry.tag} has unsupported value type ${entry.type}.');
    }
  }

  /// Reads the full unsigned-integer list of [entry].
  List<int> readUintList(final TiffIfdEntry entry) {
    if (entry.count > tiffMaxValueCount) {
      throw TiffException('TIFF tag ${entry.tag} value count exceeds the array cap.');
    }
    return <int>[for (var index = 0; index < entry.count; index++) readUint(entry, index)];
  }

  /// Reads one rational value of [entry] at [index] as a double
  /// (0 when the denominator is zero).
  double readRational(final TiffIfdEntry entry, [final int index = 0]) {
    if (index < 0 || index >= entry.count) {
      throw TiffException('TIFF tag ${entry.tag} value index $index is out of range.');
    }
    if (entry.type != 5 && entry.type != 10) {
      throw TiffException('TIFF tag ${entry.tag} has unsupported value type ${entry.type}.');
    }
    final base = entry.valueOffset + index * 8;
    final numerator = _u32(base);
    final denominator = _u32(base + 4);
    if (denominator == 0) return 0;
    return numerator / denominator;
  }

  /// Reads an ASCII (or UNDEFINED byte-run) value of [entry] as text,
  /// trimming trailing NUL padding.
  String readAscii(final TiffIfdEntry entry) {
    if (entry.type != 2 && entry.type != 7) {
      throw TiffException('TIFF tag ${entry.tag} has unsupported value type ${entry.type}.');
    }
    if (entry.count > tiffMaxAsciiBytes) {
      throw TiffException('TIFF tag ${entry.tag} text exceeds the 1 MiB string cap.');
    }
    requireTiffRange(bytes, entry.valueOffset, entry.count);
    var end = entry.count;
    while (end > 0 && bytes[entry.valueOffset + end - 1] == 0) {
      end--;
    }
    return String.fromCharCodes(bytes, entry.valueOffset, entry.valueOffset + end);
  }

  /// Reads a 64-bit value that must still be addressable: anything at
  /// or beyond 4 GiB cannot point into an in-memory file, so the high
  /// word is rejected before any arithmetic (no int wrap).
  int _u64InAddressableRange(final int offset, final String label) {
    requireTiffRange(bytes, offset, 8);
    final (high, low) = endian == Endian.little
        ? (_u32(offset + 4), _u32(offset))
        : (_u32(offset), _u32(offset + 4));
    if (high != 0) {
      throw TiffException('$label exceeds the 32-bit addressable range.');
    }
    return low;
  }
}

/// A parsed TIFF (classic) or BigTIFF container: header, byte order,
/// and the walked IFD chain.
final class TiffContainer {
  /// Parses and validates the header and walks the IFD chain.
  ///
  /// The walk enforces the page cap and cycle detection before any
  /// page data is touched. Every IFD on the chain is one page, in
  /// chain order (page 1 first).
  TiffContainer(this.bytes) : data = ByteData.sublistView(bytes) {
    if (bytes.length < 8) {
      throw const TiffException('TIFF header is truncated.');
    }
    final order = bytes[0] == 0x49 && bytes[1] == 0x49
        ? Endian.little
        : bytes[0] == 0x4D && bytes[1] == 0x4D
        ? Endian.big
        : null;
    if (order == null) {
      throw const TiffException('TIFF byte-order mark is invalid.');
    }
    endian = order;
    final version = _u16(2);
    if (version == 42) {
      isBigTiff = false;
      firstIfdOffset = _u32(4);
    } else if (version == 43) {
      isBigTiff = true;
      if (_u16(4) != 8 || _u16(6) != 0) {
        throw const TiffException('BigTIFF header is invalid.');
      }
      firstIfdOffset = _u64InAddressableRange(8, 'BigTIFF first IFD offset');
    } else {
      throw TiffException('Unsupported TIFF version $version.');
    }
    _walkIfdChain();
  }

  /// The source bytes.
  final Uint8List bytes;

  /// A [ByteData] view for endian-aware scalar reads.
  final ByteData data;

  /// The byte order declared by the header.
  late Endian endian;

  /// Whether the file uses 64-bit BigTIFF offsets.
  late bool isBigTiff;

  /// The offset of the first IFD.
  late int firstIfdOffset;

  /// The IFD chain, in order; every directory is one page.
  late final List<TiffIfd> pageDirectories;

  int _u16(final int offset) {
    requireTiffRange(bytes, offset, 2);
    return data.getUint16(offset, endian);
  }

  int _u32(final int offset) {
    requireTiffRange(bytes, offset, 4);
    return data.getUint32(offset, endian);
  }

  /// Reads a 64-bit offset/count, rejecting anything at or beyond 4
  /// GiB before arithmetic (an in-memory file can never address it).
  int _u64InAddressableRange(final int offset, final String label) {
    requireTiffRange(bytes, offset, 8);
    final (high, low) = endian == Endian.little
        ? (data.getUint32(offset + 4, endian), data.getUint32(offset, endian))
        : (data.getUint32(offset, endian), data.getUint32(offset + 4, endian));
    if (high != 0) {
      throw TiffException('$label exceeds the 32-bit addressable range.');
    }
    return low;
  }

  void _walkIfdChain() {
    final directories = <TiffIfd>[];
    final visited = <int>{};
    var offset = firstIfdOffset;
    while (offset != 0) {
      if (!visited.add(offset)) {
        throw const TiffException('TIFF IFD chain contains a cycle.');
      }
      if (directories.length >= tiffMaxPages) {
        throw const TiffException('TIFF exceeds the 1024-page limit.');
      }
      requireTiffRange(bytes, offset, isBigTiff ? 8 : 2);
      final count = isBigTiff
          ? _u64InAddressableRange(offset, 'BigTIFF entry count')
          : _u16(offset);
      if (count > tiffMaxIfdEntries) {
        throw const TiffException('TIFF IFD entry count exceeds the sanity cap.');
      }
      final headerBytes = isBigTiff ? 8 : 2;
      final entryBytes = isBigTiff ? 20 : 12;
      requireTiffRange(bytes, offset, headerBytes + count * entryBytes);
      final entries = <TiffIfdEntry>[
        for (var index = 0; index < count; index++)
          _readEntry(offset + headerBytes + index * entryBytes),
      ];
      final ifd = TiffIfd._(offset, entries).._index();
      directories.add(ifd);
      final nextPosition = offset + headerBytes + count * entryBytes;
      offset = isBigTiff
          ? _u64InAddressableRange(nextPosition, 'BigTIFF next IFD offset')
          : _u32(nextPosition);
      if (offset != 0 && offset > bytes.length) {
        throw const TiffException('TIFF next IFD offset lies beyond the file bounds.');
      }
    }
    pageDirectories = directories;
  }

  TiffIfdEntry _readEntry(final int position) {
    final tag = _u16(position);
    final type = _u16(position + 2);
    final count = isBigTiff
        ? _u64InAddressableRange(position + 4, 'BigTIFF tag $tag value count')
        : _u32(position + 4);
    if (count > tiffMaxValueCount) {
      throw TiffException('TIFF tag $tag value count exceeds the array cap.');
    }
    final valueSize = _typeSize(type);
    if (valueSize == null) {
      // Unknown types stay representable (so the walker can continue)
      // but every value read on them fails typed.
      return TiffIfdEntry(tag, type, count, -1);
    }
    final byteLength = count * valueSize;
    if (isBigTiff) {
      if (byteLength <= 8) {
        requireTiffRange(bytes, position + 12, byteLength);
        return TiffIfdEntry(tag, type, count, position + 12);
      }
      final valueOffset = _u64InAddressableRange(position + 12, 'BigTIFF tag $tag value offset');
      requireTiffRange(bytes, valueOffset, byteLength);
      return TiffIfdEntry(tag, type, count, valueOffset);
    }
    if (byteLength <= 4) {
      requireTiffRange(bytes, position + 8, byteLength);
      return TiffIfdEntry(tag, type, count, position + 8);
    }
    final valueOffset = _u32(position + 8);
    requireTiffRange(bytes, valueOffset, byteLength);
    return TiffIfdEntry(tag, type, count, valueOffset);
  }

  int? _typeSize(final int type) => switch (type) {
    1 || 2 || 6 || 7 => 1, // BYTE, ASCII, SBYTE, UNDEFINED
    3 || 8 => 2, // SHORT, SSHORT
    4 || 9 || 11 => 4, // LONG, SLONG, FLOAT
    5 || 10 || 12 => 8, // RATIONAL, SRATIONAL, DOUBLE
    16 || 17 || 18 => 8, // LONG8, SLONG8, IFD8
    _ => null,
  };
}
