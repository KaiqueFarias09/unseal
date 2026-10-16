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
import 'rar5_archive.dart';

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
    this.hasCrc32 = false,
    this.solid = false,
    this.isSplit = false,
    this.dictExp = 0,
    this.unpackedSizeUnknown = false,
    this.rar5Header,
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

  /// RAR 5 only: whether the header declares a data CRC-32. RAR 5
  /// distinguishes an absent checksum from a declared one, and a
  /// declared CRC of zero is valid and still verifies.
  final bool hasCrc32;

  /// RAR 5 only: whether the entry continues a solid stream.
  final bool solid;

  /// RAR 5 only: whether the entry is split across volumes.
  final bool isSplit;

  /// RAR 5 only: dictionary exponent (size is 0x20000 << [dictExp]).
  final int dictExp;

  /// RAR 5 only: whether the header declares the unpacked size unknown.
  final bool unpackedSizeUnknown;

  /// Whether the payload is kept verbatim (RAR 4 `0x30`, RAR 5 `0`).
  bool get isStored => isRar5 ? method == 0 : method == 0x30;

  /// Declared RAR 5 dictionary size (128 KiB base, meaningful only for
  /// compressed entries).
  int get rar5DictSize => 0x20000 << dictExp;

  /// Whether payload verification applies: RAR 5 verifies whenever the
  /// header declares a CRC (zero included); RAR 4 keeps its legacy rule
  /// of verifying only non-zero declared CRCs.
  bool get verifiesCrc => isRar5 ? hasCrc32 : crc32 != 0;

  /// The parsed RAR 5 header behind this record; null for RAR 4.
  final Rar5EntryHeader? rar5Header;

  /// Why this record's payload is outside the supported subset, or null
  /// when it can be produced from a container of [sourceLength] bytes.
  String? unsupportedReason({required final bool archiveSolid, required final int sourceLength}) {
    if (!isFile) return 'it is a directory';
    final rar5 = rar5Header;
    if (rar5 != null) {
      return rar5.unsupportedReason(archiveSolid: archiveSolid, sourceLength: sourceLength);
    }
    if (isStored) {
      if (packedSize > 0 && dataStart + packedSize > sourceLength) {
        return 'its stored payload is truncated';
      }

      return null;
    }
    // RAR 4: ordinary non-solid method-29 is the only compressed stream.
    final ordinaryMethod29 =
        method >= 0x31 &&
        method <= 0x35 &&
        version == 29 &&
        flags & 0x0017 == 0 &&
        packedSize > 0 &&
        uncompressedSize > 0;
    if (!ordinaryMethod29) {
      return 'only stored (uncompressed) and ordinary RAR 2.9/3.x payloads are supported';
    }
    if (dataStart + packedSize > sourceLength) return 'its packed payload is truncated';

    return null;
  }
}

/// Random access over a CBR container: one header-indexing pass at open
/// (the shared RAR 4 / RAR 5 container walk) and each entry decoded on
/// demand.
///
/// Support matrix mirrors the eager reader: RAR 4 stored (0x30) and
/// ordinary non-solid method-29 streams (via the shared method-29
/// decoder), RAR 5 stored entries. Unsupported compressed entries stay
/// indexed; touching them is a typed [ComicException] naming the entry
/// and the reason.
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
  RarRandomAccess._(this._source, this._records, this._archiveSolid)
    : _byLowerPath = _indexByLowerPath(_records);

  final ZipByteSource _source;
  final List<RarEntryRecord> _records;
  final Map<String, RarEntryRecord> _byLowerPath;

  /// Whether the RAR 5 main archive header declares the solid flag
  /// (false for RAR 4 archives; RAR 4 solidity rides per entry).
  final bool _archiveSolid;

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

    final (records, archiveSolid) = isRar4 ? (_indexRar4(source), false) : _indexRar5(source);
    _assertExpansionBounded(source, records);

    return RarRandomAccess._(source, records, archiveSolid);
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

    if (entry.isRar5) {
      // Out-of-subset RAR 5 records (split, solid, encrypted, later
      // algorithms, hostile dictionaries) never reach a payload path.
      if (entry.unsupportedReason(archiveSolid: _archiveSolid, sourceLength: _source.length) !=
          null) {
        return _PayloadMode.unsupported;
      }
      if (entry.isStored) {
        final intact =
            entry.uncompressedSize == entry.packedSize &&
            entry.dataStart + entry.packedSize <= _source.length;

        return intact ? _PayloadMode.stored : _PayloadMode.dropped;
      }

      // Compressed RAR 5 decoding arrives with the shared decoder;
      // until then every compressed record stays a typed rejection.
      return _PayloadMode.unsupported;
    }

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
    if (entry.method >= 0x31 &&
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
    final String reason;
    if (entry.isRar5) {
      reason =
          entry.unsupportedReason(archiveSolid: _archiveSolid, sourceLength: _source.length) ??
          'it is compressed';
    } else {
      reason = 'only stored (uncompressed) and ordinary RAR 2.9/3.x payloads are supported';
    }

    return ComicException('RAR entry "${entry.name}" is not supported: $reason.');
  }

  /// Session CRC verification: RAR 5 verifies declared CRCs (zero
  /// included); RAR 4 verifies non-zero declared CRCs only.
  void _verifyCrc(final RarEntryRecord entry, final Uint8List content) {
    if (entry.verifiesCrc && getCrc32(content) != entry.crc32) {
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

/// Indexes the RAR 5 entry headers through the shared container walk —
/// the same header grammar, CRC verification, and typed rejections the
/// eager reader uses — and maps the result onto [RarEntryRecord].
(List<RarEntryRecord>, bool) _indexRar5(final ZipByteSource source) {
  final container = readRar5Structure(source);
  final records = <RarEntryRecord>[];
  for (final header in container.entries) {
    records.add(
      RarEntryRecord._(
        name: header.name,
        isFile: !header.isDirectory,
        isRar5: true,
        dataStart: header.dataStart,
        packedSize: header.packedSize,
        uncompressedSize: header.unpackedSize,
        method: header.method,
        version: header.version,
        flags: header.isDirectory ? 0x0001 : 0,
        crc32: header.dataCrc32,
        hasCrc32: header.hasDataCrc,
        solid: header.solid,
        isSplit: header.isSplit,
        dictExp: header.dictExp,
        unpackedSizeUnknown: header.unpackedSizeUnknown,
        rar5Header: header,
      ),
    );
  }

  return (records, container.archiveSolid);
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
