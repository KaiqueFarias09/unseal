import 'dart:convert' as convert;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../../foundation/archive/zip_byte_source.dart';
import '../exceptions/comic_exception.dart';

/// Shared RAR 5 container reader.
///
/// One implementation walks the block structure for both the eager comic
/// parser and the progressive session's random-access index: header
/// CRC-32 verification, bounded vints, UTF-8 entry names, and the typed
/// rejection of every variant outside the supported subset. Payloads are
/// not touched here — the walk only indexes where each packed data area
/// starts and what its header declares about it.
///
/// Supported subset (see the README matrix): single-volume, non-solid
/// entries, compression algorithm version 0, methods 0-5 (stored through
/// best), declared dictionaries from 128 KiB through 64 MiB. Solid,
/// split, encrypted, later-algorithm, unknown-size, and oversized-
/// dictionary entries stay indexed and name their reason so callers can
/// fail typed instead of routing them through the non-solid decoder.
final class Rar5Container {
  Rar5Container._(this.entries, this.archiveSolid, this.containerLength);

  /// File entries in container order, directories included.
  final List<Rar5EntryHeader> entries;

  /// Whether the main archive header declares the solid flag.
  final bool archiveSolid;

  /// Total container length, for truncation checks at decode time.
  final int containerLength;
}

/// Maximum RAR 5 header size per the format specification
/// (https://www.rarlab.com/technote.htm).
const int maxRar5HeaderSize = 0x200000;

/// Block types of the RAR 5 container grammar.
const int _blockMain = 1;
const int _blockFile = 2;
const int _blockService = 3;
const int _blockArchiveEncryption = 4;
const int _blockEnd = 5;

/// Common block header flags.
const int _blockFlagHasExtra = 0x0001;
const int _blockFlagHasData = 0x0002;
const int _blockFlagDataNotFirst = 0x0008;
const int _blockFlagDataNotLast = 0x0010;

/// Main archive header flags.
const int _archiveFlagVolume = 0x0001;
const int _archiveFlagVolumeNumber = 0x0002;
const int _archiveFlagSolid = 0x0004;

/// File header flags.
const int _fileFlagDirectory = 0x0001;
const int _fileFlagHasMtime = 0x0002;
const int _fileFlagHasCrc32 = 0x0004;
const int _fileFlagUnpackedSizeUnknown = 0x0008;

/// File header extra-area record types.
const int _extraCrypt = 1;
const int _extraHash = 2;
const int _extraRedirect = 5;

/// Compression-info fields of a file header.
const int _compressVersionMask = 0x3F;
const int _compressSolidFlag = 0x40;
const int _compressMethodShift = 7;
const int _compressMethodMask = 0x07;
const int _compressDictShift = 10;
const int _compressDictMask = 0x1F;

/// Maximum dictionary exponent of the supported subset: 0x20000 << 9 is
/// 64 MiB, the RAR 5 ceiling. Higher exponents are reserved values.
const int maxSupportedRar5DictExp = 9;

/// Walks the RAR 5 blocks of [source] — which must start with the
/// 8-byte RAR 5 signature — verifying every header CRC and indexing the
/// file entries. Structural corruption and out-of-subset containers fail
/// typed; no payload is decoded.
Rar5Container readRar5Structure(final ZipByteSource source) {
  final length = source.length;
  final entries = <Rar5EntryHeader>[];
  var archiveSolid = false;
  var sawMainHeader = false;
  var offset = 8; // signature

  while (offset + 4 <= length) {
    final blockStart = offset;
    final lead = source.read(offset, math.min(13, length - offset));
    final headerCrc = readRar5Uint32(lead, 0);

    final (headerSize, consumedSize) = readRar5Vint(lead, 4);
    final bodyStart = offset + 4 + consumedSize;
    if (headerSize < 2 || headerSize > maxRar5HeaderSize) {
      throw ComicException('RAR 5 header at offset $blockStart declares an invalid size.');
    }
    final headerEnd = bodyStart + headerSize;
    if (headerEnd > length) {
      throw ComicException('RAR 5 header at offset $blockStart runs past the end of the file.');
    }

    // The header CRC covers the size field and everything after it,
    // through the end of the optional area — the coverage real
    // archivers write (verified against rardecode and libarchive).
    final crcWindow = source.read(offset + 4, consumedSize + headerSize);
    if (getCrc32(crcWindow) != headerCrc) {
      throw ComicException('RAR 5 header at offset $blockStart fails its CRC-32 check.');
    }
    final body = source.read(bodyStart, headerSize);

    final reader = _Rar5Cursor(body);
    final headerType = reader.vint();
    final headerFlags = reader.vint();
    var extraAreaSize = 0;
    if (headerFlags & _blockFlagHasExtra != 0) {
      extraAreaSize = reader.vint();
    }
    var dataSize = 0;
    if (headerFlags & _blockFlagHasData != 0) {
      dataSize = reader.vint();
    }
    if (headerEnd + dataSize > length) {
      throw ComicException(
        'RAR 5 block at offset $blockStart declares a data area past the end of the file.',
      );
    }

    switch (headerType) {
      case _blockMain:
        if (sawMainHeader) {
          throw const ComicException('RAR 5 archive repeats its main archive header.');
        }
        sawMainHeader = true;
        final archiveFlags = reader.vint();
        if (archiveFlags & _archiveFlagVolume != 0) {
          throw const ComicException('RAR 5 split (multi-volume) archives are not supported.');
        }
        if (archiveFlags & _archiveFlagVolumeNumber != 0) {
          reader.vint(); // volume number, bounds-checked
        }
        archiveSolid = archiveFlags & _archiveFlagSolid != 0;
      case _blockArchiveEncryption:
        throw const ComicException('RAR 5 archive-level encryption is not supported.');
      case _blockFile:
        if (!sawMainHeader) {
          throw const ComicException('RAR 5 file header appears before the main archive header.');
        }
        entries.add(
          _parseRar5FileHeader(
            reader: reader,
            blockFlags: headerFlags,
            extraAreaSize: extraAreaSize,
            dataStart: headerEnd,
            dataSize: dataSize,
          ),
        );
      case _blockService:
        break; // comments, quick-open and recovery data: skipped by size
      case _blockEnd:
        final endFlags = reader.vint();
        if (endFlags & 0x0001 != 0) {
          throw const ComicException('RAR 5 split (multi-volume) archives are not supported.');
        }
        return Rar5Container._(entries, archiveSolid, length);
      default:
        throw ComicException(
          'RAR 5 archive has an unknown block type $headerType at offset $blockStart.',
        );
    }

    offset = headerEnd + dataSize;
    if (offset <= blockStart) {
      throw ComicException('RAR 5 block at offset $blockStart does not advance the archive.');
    }
  }

  if (!sawMainHeader) {
    throw const ComicException('RAR 5 archive has no main archive header.');
  }

  return Rar5Container._(entries, archiveSolid, length);
}

/// One indexed RAR 5 file entry.
final class Rar5EntryHeader {
  Rar5EntryHeader._({
    required this.name,
    required this.isDirectory,
    required this.unpackedSize,
    required this.packedSize,
    required this.dataStart,
    required this.hasDataCrc,
    required this.dataCrc32,
    required this.version,
    required this.solid,
    required this.method,
    required this.dictExp,
    required this.isSplit,
    required this.unpackedSizeUnknown,
    required this.hasBlake2Hash,
    required this.isRedirect,
  });

  /// Entry path as stored, decoded as UTF-8 (malformed bytes become
  /// replacement characters instead of failing the archive).
  final String name;

  /// Whether the entry is a directory.
  final bool isDirectory;

  /// Declared uncompressed payload size.
  final int unpackedSize;

  /// Declared packed (data area) size.
  final int packedSize;

  /// Absolute container offset of the packed data area.
  final int dataStart;

  /// Whether the file header carries a data CRC-32.
  ///
  /// RAR 5 distinguishes an absent checksum from a declared one, and a
  /// declared CRC of zero is a valid checksum that still verifies.
  final bool hasDataCrc;

  /// Declared data CRC-32 (meaningful only with [hasDataCrc]).
  final int dataCrc32;

  /// Compression algorithm version (0 = the RAR 5.0 stream).
  final int version;

  /// Whether the entry continues a solid compression stream.
  final bool solid;

  /// Compression method: 0 stored, 1-5 compressed, 6-7 reserved.
  final int method;

  /// Dictionary exponent; size is 0x20000 << [dictExp] (128 KiB base).
  final int dictExp;

  /// Whether the entry is split across volumes (not-first/not-last
  /// block flags).
  final bool isSplit;

  /// Whether the header declares the unpacked size as unknown.
  final bool unpackedSizeUnknown;

  /// Whether a redirect extra record marks the entry as a link.
  ///
  /// Links never carry page payload; they are typed rejections.
  final bool isRedirect;

  /// Whether a hash extra record declares a BLAKE2sp digest.
  ///
  /// The digest is parsed but not verified; payload verification uses
  /// the header CRC-32 when present.
  final bool hasBlake2Hash;

  /// Declared dictionary size in bytes (128 KiB through 64 MiB inside
  /// the supported subset).
  int get dictSize => 0x20000 << dictExp;

  /// Whether the payload is kept verbatim (method 0).
  bool get isStored => method == 0;

  /// Why the entry is outside the supported RAR 5 subset, or null when
  /// the payload can be produced from a container of [sourceLength]
  /// bytes. The [archiveSolid] argument marks archives whose compressed
  /// streams depend on earlier entries even without the per-entry solid
  /// bit.
  String? unsupportedReason({required final bool archiveSolid, required final int sourceLength}) {
    if (isDirectory) return null;
    if (isSplit) return 'it is split across volumes';
    if (version != 0) return 'it uses compression algorithm version $version';
    if (method > 5) return 'it uses reserved compression method $method';
    if (dictExp > maxSupportedRar5DictExp) {
      return 'it declares a dictionary of ${dictSize >> 20} MiB, above the 64 MiB subset limit';
    }
    if (isRedirect) return 'it is a link or redirect';
    if (solid || (archiveSolid && !isStored)) return 'it is a solid stream';
    if (unpackedSizeUnknown) return 'it does not declare its unpacked size';
    if (packedSize > 0 && dataStart + packedSize > sourceLength) {
      return 'its packed payload is truncated';
    }
    return null;
  }
}

Rar5EntryHeader _parseRar5FileHeader({
  required final _Rar5Cursor reader,
  required final int blockFlags,
  required final int extraAreaSize,
  required final int dataStart,
  required final int dataSize,
}) {
  final fileFlags = reader.vint();
  final unpackedSize = reader.vint();
  reader.vint(); // attributes
  if (fileFlags & _fileFlagHasMtime != 0) {
    reader.uint32(); // mtime
  }
  var hasDataCrc = false;
  var dataCrc32 = 0;
  if (fileFlags & _fileFlagHasCrc32 != 0) {
    hasDataCrc = true;
    dataCrc32 = reader.uint32();
  }
  final compressionInfo = reader.vint();
  reader.vint(); // host OS
  final nameLength = reader.vint();
  final name = convert.utf8.decode(reader.bytes(nameLength), allowMalformed: true);

  // Extra-area records: each is (size, type, payload) and the record
  // size bounds its own payload.
  var hasBlake2Hash = false;
  var isRedirect = false;
  final extraEnd = reader.position + extraAreaSize;
  if (extraEnd > reader.length) {
    throw const ComicException('RAR 5 file header extra area runs past the header.');
  }
  while (reader.position < extraEnd) {
    final recordSize = reader.vint();
    final recordEnd = reader.position + recordSize;
    if (recordSize < 1 || recordEnd > extraEnd) {
      throw const ComicException('RAR 5 file header has a malformed extra-area record.');
    }
    final recordType = reader.vint();
    if (recordType == _extraCrypt) {
      throw const ComicException('RAR 5 encrypted entries are not supported.');
    }
    if (recordType == _extraHash) {
      final hashFlags = reader.vint();
      // Bit 0: CRC-32 (already carried by the file header field when
      // present), bit 1: BLAKE2sp.
      hasBlake2Hash = hashFlags & 0x0002 != 0;
    }
    if (recordType == _extraRedirect) {
      isRedirect = true;
    }
    reader.seek(recordEnd);
  }

  return Rar5EntryHeader._(
    name: name,
    isDirectory: fileFlags & _fileFlagDirectory != 0,
    unpackedSize: unpackedSize,
    packedSize: dataSize,
    dataStart: dataStart,
    hasDataCrc: hasDataCrc,
    dataCrc32: dataCrc32,
    version: compressionInfo & _compressVersionMask,
    solid: compressionInfo & _compressSolidFlag != 0,
    method: (compressionInfo >> _compressMethodShift) & _compressMethodMask,
    dictExp: (compressionInfo >> _compressDictShift) & _compressDictMask,
    isSplit: blockFlags & _blockFlagDataNotFirst != 0 || blockFlags & _blockFlagDataNotLast != 0,
    unpackedSizeUnknown: fileFlags & _fileFlagUnpackedSizeUnknown != 0,
    hasBlake2Hash: hasBlake2Hash,
    isRedirect: isRedirect,
  );
}

/// Bounds-checked cursor over one RAR 5 header body.
final class _Rar5Cursor {
  _Rar5Cursor(this._bytes);

  final Uint8List _bytes;
  int _position = 0;

  int get position => _position;
  int get length => _bytes.length;

  void seek(final int target) {
    if (target < _position || target > _bytes.length) {
      throw const ComicException('RAR 5 header cursor moved out of bounds.');
    }
    _position = target;
  }

  /// Reads a LEB128 vint: at most 8 value bytes (63 bits) and a
  /// terminator inside the buffer.
  int vint() {
    var value = 0;
    var shift = 0;
    while (true) {
      if (_position >= _bytes.length) {
        throw const ComicException('RAR 5 header ends inside a vint value.');
      }
      final byte = _bytes[_position++];
      if (shift == 63 && byte & 0x7F != 0) {
        throw const ComicException('RAR 5 vint value overflows 64 bits.');
      }
      value |= (byte & 0x7F) << shift;
      if (byte & 0x80 == 0) return value;
      shift += 7;
      if (shift > 63) {
        throw const ComicException('RAR 5 vint value overflows 64 bits.');
      }
    }
  }

  int uint32() {
    if (_position + 4 > _bytes.length) {
      throw const ComicException('RAR 5 header ends inside a fixed-size field.');
    }
    final value = readRar5Uint32(_bytes, _position);
    _position += 4;

    return value;
  }

  Uint8List bytes(final int count) {
    if (count < 0 || _position + count > _bytes.length) {
      throw const ComicException('RAR 5 header field runs past the end of the header.');
    }
    final result = Uint8List.sublistView(_bytes, _position, _position + count);
    _position += count;

    return result;
  }
}

/// Reads a little-endian uint32 used by RAR 5 header fields.
int readRar5Uint32(final Uint8List bytes, final int offset) =>
    ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.little);

/// Reads a RAR 5 vint (LEB128, 7 bits per byte) at [offset], returning
/// the value and bytes consumed; the same bounded grammar the container
/// walk uses.
(int, int) readRar5Vint(final Uint8List bytes, final int offset) {
  var value = 0;
  var shift = 0;
  var consumed = 0;
  while (offset + consumed < bytes.length) {
    final byte = bytes[offset + consumed];
    consumed++;
    value |= (byte & 0x7F) << shift;
    if (byte & 0x80 == 0) return (value, consumed);
    shift += 7;
    if (shift > 63) break;
  }

  return (value, consumed);
}
