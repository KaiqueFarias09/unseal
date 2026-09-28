import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../../foundation/archive/archive_access.dart';
import '../../../foundation/archive/archive_random_access.dart';
import '../../../foundation/archive/bounded_output_stream.dart';
import '../../../foundation/archive/zip_byte_source.dart';
import '../../../foundation/exceptions/unseal_exception.dart';
import '../exceptions/comic_exception.dart';
import 'rar4_method29_decoder.dart';

/// One indexed RAR record: everything needed to decode a single entry
/// later without touching any other entry.
final class RarEntryRecord implements ArchiveEntry {
  const RarEntryRecord._({
    required this.name,
    required this.isFile,
    required this.isRar5,
    required this.dataStart,
    required this.packedSize,
    required this.uncompressedSize,
    required this.method,
    required this.version,
    required this.flags,
    required this.crc32,
  });

  /// Entry path as stored in the archive.
  @override
  final String name;

  /// Whether the record carries a payload (directories do not).
  @override
  final bool isFile;

  /// Whether the record follows the RAR 5 header grammar (methods 0-7)
  /// instead of the RAR 4 one (methods 0x30-0x35).
  final bool isRar5;

  /// File offset of the packed payload.
  final int dataStart;

  /// Declared packed payload size.
  final int packedSize;

  /// Declared uncompressed payload size.
  @override
  final int uncompressedSize;

  /// Compression method: RAR 4 `0x30` (stored) through `0x35`, RAR 5
  /// `0` (stored) through `7`.
  final int method;

  /// RAR 4 unpack version (29 = the supported 2.9/3.x stream) or the
  /// RAR 5 version field.
  final int version;

  /// Entry header flags as stored (solid/split/password/directory
  /// bits).
  final int flags;

  /// Declared CRC-32 of the uncompressed payload; 0 when the header
  /// carries none.
  final int crc32;

  /// Whether the payload is kept verbatim (RAR 4 `0x30`, RAR 5 `0`).
  bool get isStored => isRar5 ? method == 0 : method == 0x30;
}

/// Random access over a CBR container: one header-indexing pass at open
/// (the same RAR 4 / RAR 5 grammar the eager reader walks) and each
/// entry decoded on demand.
///
/// Support matrix mirrors the eager reader: RAR 4 stored (0x30) and
/// ordinary non-solid method-29 streams (via the shared method-29
/// decoder), RAR 5 stored only. Unsupported compressed entries stay
/// indexed; touching them is a typed [ComicException] naming the entry.
///
/// Security posture matches the zip random access: container-level
/// guards reject hostile declared sizes at open (total > 1 GiB,
/// largest entry > 512 MiB, expansion ratio > 200x above 32 MiB, the
/// same constants as the zip path) and per-entry output stays bounded
/// while it is produced. CRC delta, documented: the eager RAR reader
/// never verifies CRCs, while the session verifies declared non-zero
/// CRCs and rejects corruption typed — entries declared with CRC 0
/// never reject.
///
/// Sessions open only when the eager parse of the same bytes would too:
/// every entry the eager reader cannot produce data for (unsupported
/// compression, truncated stored payload it cannot keep verbatim) makes
/// the whole eager parse fail typed, and the session header build
/// touches every entry while sniffing pages, so the same typed failure
/// surfaces at open.
final class RarRandomAccess implements ArchiveRandomAccess {
  RarRandomAccess._(this._source, this._records) : _byLowerPath = _indexByLowerPath(_records);

  final ZipByteSource _source;
  final List<RarEntryRecord> _records;
  final Map<String, RarEntryRecord> _byLowerPath;

  /// Indexes the entry headers of [source] without decoding any
  /// payload, then validates the container-level guards. Costs no
  /// entry decode.
  factory RarRandomAccess.open(final ZipByteSource source) {
    if (source.length < 8) {
      throw const ComicException('File is too small to be a RAR archive.');
    }

    final signature = source.read(0, 8);
    final isRar4 = signature[6] == 0x00;
    final isRar5 = signature[6] == 0x01 && signature[7] == 0x00;
    if (!_isRarSignature(signature) || (!isRar4 && !isRar5)) {
      throw const ComicException('Not a RAR archive.');
    }

    final records = isRar4 ? _indexRar4(source) : _indexRar5(source);
    _assertExpansionBounded(source, records);

    return RarRandomAccess._(source, records);
  }

  /// Every indexed record in container order, directories included
  /// (with [RarEntryRecord.isFile] false).
  @override
  List<RarEntryRecord> get entries => List.unmodifiable(_records);

  /// Declared uncompressed total across all records.
  int get declaredUncompressedBytes =>
      _records.fold(0, (final total, final record) => total + record.uncompressedSize);

  /// Finds an entry by [entryPath] with the same matching preference as
  /// the zip reader: the first record with an exact or normalized
  /// case-insensitive path match wins.
  @override
  RarEntryRecord? find(final String entryPath) {
    final normalized = normalizeZipPath(entryPath);
    if (normalized.isEmpty) return null;

    return _byLowerPath[normalized.toLowerCase()];
  }

  /// Decodes one entry, bounded by [maxBytes] (default: the declared
  /// size capped at the shared entry cap), verifying the declared CRC
  /// when it is non-zero.
  @override
  Uint8List inflate(covariant final RarEntryRecord entry, {final int? maxBytes}) {
    final limit = math.min(maxBytes ?? maxZipEntryUncompressedBytes, maxZipEntryUncompressedBytes);
    switch (_modeOf(entry)) {
      case _PayloadMode.stored:
        final bounded = BoundedOutputStream(math.min(limit, entry.uncompressedSize));
        bounded.writeBytes(_source.read(entry.dataStart, entry.packedSize));
        final content = Uint8List.fromList(bounded.subset(0, bounded.length));
        _verifyCrc(entry, content);

        return content;
      case _PayloadMode.method29:
        final packed = _source.read(entry.dataStart, entry.packedSize);
        try {
          // The declared target doubles as the output bound: the decoder
          // refuses matches that would run past it.
          final decoded = decodeRar4Method29(packed, math.min(entry.uncompressedSize, limit));
          _verifyCrc(entry, decoded);

          return decoded;
        } on UnsealException {
          rethrow;
        } on Object catch (error) {
          throw ComicException(
            'RAR entry "${entry.name}" could not be decoded (${error.runtimeType}).',
          );
        }
      case _PayloadMode.dropped:
        throw ComicException(
          'RAR entry "${entry.name}" has a truncated or mismatched stored payload.',
        );
      case _PayloadMode.unsupported:
        throw _unsupportedCompression(entry);
    }
  }

  /// Returns the first [byteCount] payload bytes of [entry] — the
  /// prefix the eager reader would pair with the record: stored slices
  /// verbatim, method-29 streams decoded (so page sniffing at open
  /// matches the eager parse), dropped entries empty, unsupported
  /// compressed entries a typed rejection.
  @override
  Uint8List head(covariant final RarEntryRecord entry, final int byteCount) {
    switch (_modeOf(entry)) {
      case _PayloadMode.stored:
        final available = math.min(entry.packedSize, _availableAt(entry.dataStart));
        if (available <= 0 || byteCount <= 0) return Uint8List(0);

        return _source.read(entry.dataStart, math.min(byteCount, available));
      case _PayloadMode.method29:
        final decoded = inflate(entry);

        return Uint8List.sublistView(decoded, 0, math.min(byteCount, decoded.length));
      case _PayloadMode.dropped:
        return Uint8List(0);
      case _PayloadMode.unsupported:
        throw _unsupportedCompression(entry);
    }
  }

  /// Releases the underlying byte source.
  @override
  void close() => _source.close();

  /// How the eager reader's payload grammar classifies [entry] — the
  /// parity contract every payload access goes through.
  _PayloadMode _modeOf(final RarEntryRecord entry) {
    if (!entry.isFile) return _PayloadMode.dropped;

    if (entry.isStored) {
      final intact =
          entry.uncompressedSize == entry.packedSize &&
          entry.dataStart + entry.packedSize <= _source.length;

      return intact ? _PayloadMode.stored : _PayloadMode.dropped;
    }

    // Ordinary non-solid RAR 2.9/3.x stream, the only compression the
    // eager reader decodes; everything else (solid, password-protected,
    // split, other methods/versions, RAR 5 compression) yields empty
    // data there and fails the whole parse typed.
    if (!entry.isRar5 &&
        entry.method >= 0x31 &&
        entry.method <= 0x35 &&
        entry.version == 29 &&
        entry.flags & 0x0017 == 0 &&
        entry.packedSize > 0 &&
        entry.uncompressedSize > 0 &&
        entry.dataStart + entry.packedSize <= _source.length) {
      return _PayloadMode.method29;
    }

    return _PayloadMode.unsupported;
  }

  ComicException _unsupportedCompression(final RarEntryRecord entry) {
    return ComicException(
      'RAR entry "${entry.name}" is compressed; only stored (uncompressed) '
      'and ordinary RAR 2.9/3.x CBR archives are supported.',
    );
  }

  /// Session-only CRC delta (see the class docs): declared non-zero
  /// CRCs are verified, CRC 0 never rejects.
  void _verifyCrc(final RarEntryRecord entry, final Uint8List content) {
    if (entry.crc32 != 0 && getCrc32(content) != entry.crc32) {
      throw ComicException('RAR entry "${entry.name}" has an invalid checksum.');
    }
  }

  int _availableAt(final int offset) => math.max(0, _source.length - offset);
}

/// How the eager reader's payload grammar classifies a record.
enum _PayloadMode {
  /// Stored payload kept verbatim (size-matched and inside the
  /// container).
  stored,

  /// RAR 4 method-29 non-solid stream the eager reader decodes.
  method29,

  /// Stored entry the eager reader cannot keep verbatim (truncated or
  /// size-mismatched): it drops the entry with empty data.
  dropped,

  /// Undecodable compressed entry: the eager parse fails typed and so
  /// does every session payload access.
  unsupported,
}

Map<String, RarEntryRecord> _indexByLowerPath(final List<RarEntryRecord> records) {
  final index = <String, RarEntryRecord>{};
  for (final record in records) {
    if (!record.isFile) continue;

    final normalized = normalizeZipPath(record.name);
    if (normalized.isNotEmpty) index.putIfAbsent(normalized.toLowerCase(), () => record);
  }

  return index;
}

bool _isRarSignature(final Uint8List signature) {
  const marker = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07];
  for (var i = 0; i < marker.length; i++) {
    if (signature[i] != marker[i]) return false;
  }

  return true;
}

/// Indexes the RAR 4 entry headers, starting after the 7-byte
/// signature — the same walk the eager reader does, minus the
/// decoding.
List<RarEntryRecord> _indexRar4(final ZipByteSource source) {
  final length = source.length;
  final records = <RarEntryRecord>[];
  var offset = 7; // signature marker

  while (offset + 7 <= length) {
    final lead = source.read(offset, 7);
    final blockType = lead[2];
    final flags = _readUint16(lead, 3);
    final headSize = _readUint16(lead, 5);
    if (headSize < 7) break;

    if (blockType == 0x74) {
      // File header.
      if (offset + 32 > length) break;

      final header = source.read(offset, 32);
      var field = 7;
      final packSize = _readUint32(header, field);
      field += 4;
      final unpSize = _readUint32(header, field);
      field += 4;
      field += 1; // host OS
      final crc = _readUint32(header, field);
      field += 4; // file CRC
      field += 4; // file time
      final unpackVersion = header[field];
      field += 1;
      final method = header[field];
      field += 1;
      final nameSize = _readUint16(header, field);
      field += 2;
      field += 4; // attributes
      if (flags & 0x0100 != 0) {
        field += 8; // high pack/unp sizes
      }
      if (flags & 0x0400 != 0) {
        field += 8; // salt
      }
      final nameStart = offset + field;
      if (nameStart + nameSize > length) break;

      final name = String.fromCharCodes(source.read(nameStart, nameSize));
      final isDirectory = (flags & 0xE0) == 0xE0;
      records.add(
        RarEntryRecord._(
          name: name,
          isFile: !isDirectory,
          isRar5: false,
          dataStart: offset + headSize,
          packedSize: packSize,
          uncompressedSize: unpSize,
          method: method,
          version: unpackVersion,
          flags: flags,
          crc32: crc,
        ),
      );
      if (!isDirectory && flags & 0x8000 != 0) {
        offset += headSize + packSize;
      } else {
        offset += headSize;
      }
    } else {
      // Skip marker/main/end/other blocks by header size.
      offset += headSize;

      if (blockType == 0x7B) {
        break; // end of archive
      }
    }
  }

  return records;
}

/// Indexes the RAR 5 entry headers, starting after the 8-byte
/// signature — the same walk the eager reader does, minus the
/// decoding.
List<RarEntryRecord> _indexRar5(final ZipByteSource source) {
  final length = source.length;
  final records = <RarEntryRecord>[];
  var offset = 8; // signature

  while (offset + 8 <= length) {
    final blockStart = offset;
    final sizeWindow = source.read(offset + 4, math.min(20, length - offset - 4));
    final (headerSize, consumedSize) = _vint(sizeWindow, 0);
    if (consumedSize == 0) break;

    // Header size counts from the type field to the end of the header,
    // excluding the CRC and the size vint itself.
    final headerStart = offset + 4 + consumedSize;
    final headerEnd = headerStart + headerSize;
    if (headerEnd > length) break;

    final header = source.read(headerStart, headerEnd - headerStart);
    final (headerType, consumedType) = _vint(header, 0);
    var h = consumedType;
    final (headerFlags, consumedFlags) = _vint(header, h);
    h += consumedFlags;
    var extraAreaSize = 0;
    if (headerFlags & 0x0001 != 0) {
      // RAR 5 stores EXTRA_AREA_SIZE before DATA_SIZE in the common header.
      final (size, consumedExtra) = _vint(header, h);
      extraAreaSize = size;
      h += consumedExtra;
    }
    var dataSize = 0;
    if (headerFlags & 0x0002 != 0) {
      final (size, consumedData) = _vint(header, h);
      dataSize = size;
      h += consumedData;
    }

    if (headerType == 2) {
      // File header.
      final (fileFlags, consumedFileFlags) = _vint(header, h);
      h += consumedFileFlags;
      final (unpackedSize, consumedUnpacked) = _vint(header, h);
      h += consumedUnpacked;
      final (_, consumedAttributes) = _vint(header, h);
      h += consumedAttributes; // attributes
      if (fileFlags & 0x0002 != 0) {
        h += 4; // mtime
      }
      var crc = 0;
      if (fileFlags & 0x0004 != 0) {
        if (h + 4 <= header.length) crc = _readUint32(header, h);
        h += 4; // data CRC
      }
      final (compressionInfo, consumedCompression) = _vint(header, h);
      h += consumedCompression;
      h += 1; // host OS
      final (nameLength, consumedName) = _vint(header, h);
      h += consumedName;
      final nameEnd = h + nameLength;
      if (nameEnd > header.length) break;

      final name = String.fromCharCodes(header.sublist(h, nameEnd));
      final extraAreaEnd = nameEnd + extraAreaSize;
      if (extraAreaEnd > header.length) break;

      records.add(
        RarEntryRecord._(
          name: name,
          isFile: fileFlags & 0x0001 == 0,
          isRar5: true,
          dataStart: headerEnd,
          packedSize: dataSize,
          uncompressedSize: unpackedSize,
          method: (compressionInfo >> 7) & 0x07,
          version: compressionInfo & 0x3F,
          flags: fileFlags,
          crc32: crc,
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

  return records;
}

/// Reads a RAR 5 vint (LEB128, 7 bits per byte) from [bytes] at
/// [offset]; the same grammar the eager reader uses.
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

/// Container-level RAR bomb guards, applied to declared sizes before
/// any payload is decoded, with the same caps as the zip path.
void _assertExpansionBounded(final ZipByteSource source, final List<RarEntryRecord> records) {
  var total = 0;
  var largest = 0;
  for (final record in records) {
    total += record.uncompressedSize;
    if (record.uncompressedSize > largest) largest = record.uncompressedSize;
  }

  if (total > maxZipTotalUncompressedBytes) {
    throw InvalidBookException(
      'RAR container declares $total uncompressed bytes, above the '
      '$maxZipTotalUncompressedBytes-byte safety cap.',
    );
  }
  if (largest > maxZipEntryUncompressedBytes) {
    throw InvalidBookException(
      'RAR entry declares $largest uncompressed bytes, above the '
      '$maxZipEntryUncompressedBytes-byte safety cap.',
    );
  }
  if (total > minZipBytesForRatioCheck && source.length > 0) {
    final ratio = total ~/ source.length;
    if (ratio > maxZipExpansionRatio) {
      throw InvalidBookException(
        'RAR container expansion ratio $ratio exceeds the '
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
