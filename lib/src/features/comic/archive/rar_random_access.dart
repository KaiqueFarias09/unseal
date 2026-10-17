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
import 'rar5_decoder.dart';

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
    required this.recordIndex,
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

  /// Position of this record in container order — the solid chain's
  /// decode order.
  final int recordIndex;

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
  String? unsupportedReason({required final int sourceLength}) {
    if (!isFile) return 'it is a directory';
    final rar5 = rar5Header;
    if (rar5 != null) {
      return rar5.unsupportedReason(sourceLength: sourceLength);
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

/// Cumulative solid-chain limits of one session. The per-file decode
/// limits bound a single entry; these bound the session's accumulated
/// work, so replaying history in a hostile access pattern cannot grow
/// without a ceiling. Reopening the archive resets them.
///
/// - [maxRar5SolidReplayBytes]: total uncompressed bytes re-decoded to
///   serve backward accesses across the whole session.
/// - [maxRar5SolidCheckpoints] / [maxRar5SolidCheckpointBytes]: how many
///   dictionary snapshots the session keeps, and the total window bytes
///   they may occupy.
const int maxRar5SolidReplayBytes = 512 * 1024 * 1024;

/// Dictionary snapshots one session keeps. Together with
/// [maxRar5SolidCheckpointBytes] this bounds checkpoint memory; the
/// oldest snapshots are evicted first.
const int maxRar5SolidCheckpoints = 16;

/// Total window bytes the live checkpoints of one session may occupy.
const int maxRar5SolidCheckpointBytes = 96 * 1024 * 1024;

/// Random access over a CBR container: one header-indexing pass at open
/// (the shared RAR 4 / RAR 5 container walk) and each entry decoded on
/// demand.
///
/// Support matrix mirrors the eager reader: RAR 4 stored (0x30) and
/// ordinary non-solid method-29 streams (via the shared method-29
/// decoder), RAR 5 stored entries and version-0 compressed streams —
/// solid chains included (methods 1-5, filters 0-3, dictionaries
/// through 64 MiB) via the shared [Rar5SolidDecoder]. Out-of-subset
/// records stay indexed; touching them is a typed [ComicException]
/// naming the entry and the reason.
///
/// Solid state is per session: one decoder, one dictionary, one
/// checkpoint set. Requests decode forward in container order; a
/// backward request replays from the nearest checkpoint at or before
/// the target (or the chain start) under the cumulative
/// [maxRar5SolidReplayBytes] budget, charged before the work happens.
/// A failed decode poisons the chain — forward requests fail typed
/// until a checkpoint restore rebuilds the dictionary — and reopening
/// the archive starts fresh.
///
/// Security posture matches the zip random access: container-level
/// guards reject hostile declared sizes at open (total > 1 GiB,
/// largest entry > 512 MiB, expansion ratio > 200x above 32 MiB, the
/// same constants as the zip path) and per-entry output stays bounded
/// while it is produced. CRC delta, documented: the eager RAR reader
/// never verifies CRCs, while the session verifies declared CRCs and
/// rejects corruption typed — a declared CRC of zero is a real
/// checksum and still verifies.
///
/// Sessions open only when the eager parse of the same bytes would too:
/// every entry the eager reader cannot produce data for (unsupported
/// compression, truncated stored payload it cannot keep verbatim) makes
/// the whole eager parse fail typed, and the session header build
/// touches every entry while sniffing pages, so the same typed failure
/// surfaces at open. Page sniffing decodes solid entries sequentially
/// at open — the documented open cost of a solid CBR.
final class RarRandomAccess implements ArchiveRandomAccess {
  RarRandomAccess._(this._source, this._records) : _byLowerPath = _indexByLowerPath(_records);

  final ZipByteSource _source;
  final List<RarEntryRecord> _records;
  final Map<String, RarEntryRecord> _byLowerPath;

  // Solid-chain session state. Each RarRandomAccess owns its decoder,
  // checkpoints, and budgets — two sessions on the same bytes never
  // share a mutable dictionary.
  Rar5SolidDecoder? _solid;

  /// Container position of the next entry the chain can decode.
  int _cursor = 0;

  /// Container position of the farthest entry ever decoded. Chain work
  /// at or below this mark is a re-decode and charges the replay
  /// budget — whichever direction it decodes in.
  int _highWater = -1;

  /// Whether a decode failure broke the chain: forward continuation is
  /// impossible until a checkpoint restore rebuilds the dictionary.
  bool _poisoned = false;

  /// Dictionary snapshots keyed by the container position they decode.
  final Map<int, _SolidCheckpoint> _checkpoints = {};
  int _checkpointBytes = 0;
  int _replayBudgetBytes = maxRar5SolidReplayBytes;

  /// Cumulative uncompressed bytes re-decoded for backward accesses so
  /// far — the consumed share of [maxRar5SolidReplayBytes].
  int get solidReplayBytesUsed => maxRar5SolidReplayBytes - _replayBudgetBytes;

  /// Total window bytes held by live checkpoints.
  int get solidCheckpointBytes => _checkpointBytes;

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
  /// when it is present (zero included).
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
      case _PayloadMode.rar5:
        final reason = entry.unsupportedReason(sourceLength: _source.length);
        if (reason != null) {
          throw ComicException('RAR entry "${entry.name}" is not supported: $reason.');
        }
        // The RAR 5 decoder allocates exactly the declared output, so
        // the bound applies before any decode work happens.
        if (entry.uncompressedSize > limit) {
          throw InvalidBookException(
            'RAR entry "${entry.name}" declares ${entry.uncompressedSize} uncompressed '
            'bytes, above the $limit-byte expansion limit.',
          );
        }
        if (entry.uncompressedSize == 0) {
          _verifyCrc(entry, Uint8List(0));

          return Uint8List(0);
        }
        return _decodeSolidEntry(entry);
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
  /// verbatim, compressed streams decoded (so page sniffing at open
  /// matches the eager parse), dropped entries empty, unsupported
  /// records a typed rejection.
  @override
  Uint8List head(covariant final RarEntryRecord entry, final int byteCount) {
    switch (_modeOf(entry)) {
      case _PayloadMode.stored:
        final available = math.min(entry.packedSize, _availableAt(entry.dataStart));
        if (available <= 0 || byteCount <= 0) return Uint8List(0);

        return _source.read(entry.dataStart, math.min(byteCount, available));
      case _PayloadMode.method29:
      case _PayloadMode.rar5:
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
      // Out-of-subset RAR 5 records (split, broken solid chains,
      // encrypted, later algorithms, hostile dictionaries) never reach
      // a payload path.
      if (entry.unsupportedReason(sourceLength: _source.length) != null) {
        return _PayloadMode.unsupported;
      }
      if (entry.isStored) {
        final intact =
            entry.uncompressedSize == entry.packedSize &&
            entry.dataStart + entry.packedSize <= _source.length;

        return intact ? _PayloadMode.stored : _PayloadMode.dropped;
      }

      return _PayloadMode.rar5;
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
      reason = entry.unsupportedReason(sourceLength: _source.length) ?? 'it is compressed';
    } else {
      reason = 'only stored (uncompressed) and ordinary RAR 2.9/3.x payloads are supported';
    }

    return ComicException('RAR entry "${entry.name}" is not supported: $reason.');
  }

  // Decodes one compressed RAR 5 entry through the session's solid
  // chain — the same decoder instance the eager parse drives, sequenced
  // in container order.
  //
  // Forward requests decode the entries between the cursor and the
  // target (their output builds the dictionary; only the target's bytes
  // are served). Backward requests replay from the nearest checkpoint
  // at or before the target — or the chain start — and charge every
  // replayed entry against the cumulative replay budget before the
  // work happens. Each served boundary is checkpointed, bounded by
  // count and total window bytes.
  Uint8List _decodeSolidEntry(final RarEntryRecord entry) {
    final index = entry.recordIndex;
    _solid ??= Rar5SolidDecoder();
    try {
      if (_poisoned) {
        throw ComicException(
          'RAR entry "${entry.name}" cannot be decoded because an earlier solid '
          'entry failed; reopen the archive.',
        );
      }
      final Uint8List decoded;
      if (index >= _cursor) {
        // Forward walk: intermediate entries build the dictionary.
        // Anything the session has decoded before is a re-decode and
        // charges the replay budget first, so alternating jumps across
        // a decoded region stay bounded like backward replays.
        _chargeReplay(_cursor, index);
        for (var i = _cursor; i < index; i++) {
          _decodeChainEntry(_records[i]);
        }
        _chargeReplay(index, index + 1);
        decoded = _decodeChainEntry(entry);
      } else {
        decoded = _replayTo(entry);
      }
      if (index > _highWater) _highWater = index;
      _verifyCrc(entry, decoded);

      return decoded;
    } on UnsealException {
      rethrow;
    } on Object catch (error) {
      // A failed decode leaves the carried dictionary unusable for
      // forward continuation; checkpoint restores still rebuild it.
      _poisoned = true;
      throw ComicException(
        'RAR entry "${entry.name}" could not be decoded (${error.runtimeType}).',
      );
    }
  }

  // Decodes the compressed entry at [record]'s position, advancing the
  // cursor and checkpointing the boundary. Returns the entry's output.
  Uint8List _decodeChainEntry(final RarEntryRecord record) {
    if (!record.isFile) {
      _cursor = record.recordIndex + 1;
      return Uint8List(0);
    }
    final mode = _modeOf(record);
    if (mode != _PayloadMode.rar5) {
      // Stored records do not participate in the compressed dictionary.
      // Dispatch through the normal path to retain their checks and CRC.
      final decoded = inflate(record);
      _cursor = record.recordIndex + 1;
      return decoded;
    }
    final Uint8List decoded;
    try {
      decoded = _solid!.decodeEntry(
        packed: _source.read(record.dataStart, record.packedSize),
        uncompressedSize: record.uncompressedSize,
        windowSize: record.rar5DictSize,
        solid: record.solid,
      );
      _verifyCrc(record, decoded);
    } on Object {
      _poisoned = true;
      rethrow;
    }
    _cursor = record.recordIndex + 1;
    _rememberCheckpoint(record.recordIndex + 1);

    return decoded;
  }

  // Serves a backward access by rebuilding the dictionary: restore the
  // nearest checkpoint at or before the target (else restart the chain
  // from the beginning), decode forward discarding intermediate
  // outputs, then decode the target. The whole replay is charged
  // against the cumulative budget BEFORE any decode work.
  Uint8List _replayTo(final RarEntryRecord entry) {
    final index = entry.recordIndex;
    var best = -1;
    for (final key in _checkpoints.keys) {
      if (key <= index && key > best) best = key;
    }
    final from = best == -1 ? 0 : best;

    _chargeReplay(from, index + 1);

    final checkpoint = best == -1 ? null : _checkpoints[best];
    if (checkpoint != null) {
      _solid!.restoreState(checkpoint.state);
    } else {
      _solid = Rar5SolidDecoder();
    }
    _poisoned = false;

    for (var i = from; i < index; i++) {
      final record = _records[i];
      _decodeChainEntry(record);
    }

    return _decodeChainEntry(entry);
  }

  // Charges the cumulative budget for re-decoding the compressed
  // entries in [from, to) — replay work, priced before it happens.
  void _chargeReplay(final int from, final int to) {
    var cost = 0;
    for (var i = from; i < to && i <= _highWater; i++) {
      final record = _records[i];
      if (_modeOf(record) == _PayloadMode.rar5) cost += record.uncompressedSize;
    }
    if (cost > _replayBudgetBytes) {
      throw ComicException(
        "RAR solid replay of $cost bytes exceeds the session's remaining "
        '$_replayBudgetBytes-byte cumulative replay budget; reopen the archive.',
      );
    }
    _replayBudgetBytes -= cost;
  }

  // Snapshots the dictionary at a served boundary, bounded by count and
  // total window bytes (oldest evicted first). Oversized windows (a
  // declared dictionary above the checkpoint budget) disable
  // checkpointing for the session; replay stays available.
  void _rememberCheckpoint(final int index) {
    final weight = _solid!.windowBytes;
    final replaced = _checkpoints.remove(index);
    if (replaced != null) _checkpointBytes -= replaced.state.weightBytes;
    if (weight > maxRar5SolidCheckpointBytes) return;
    while (_checkpointBytes + weight > maxRar5SolidCheckpointBytes ||
        _checkpoints.length >= maxRar5SolidCheckpoints) {
      if (_checkpoints.isEmpty) return;
      final oldestKey = _checkpoints.keys.first;
      _checkpointBytes -= _checkpoints.remove(oldestKey)!.state.weightBytes;
    }
    _checkpoints[index] = _SolidCheckpoint(_solid!.captureState(), index);
    _checkpointBytes += weight;
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

/// One dictionary snapshot: the decode state able to decode the entry
/// at [recordIndex] next.
final class _SolidCheckpoint {
  _SolidCheckpoint(this.state, this.recordIndex);

  final Rar5SolidState state;
  final int recordIndex;
}

/// How the eager reader's payload grammar classifies a record.
enum _PayloadMode {
  /// RAR 5 compressed stream the shared decoder handles (out-of-subset
  /// records reject before reaching this mode).
  rar5,

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
          recordIndex: records.length,
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
List<RarEntryRecord> _indexRar5(final ZipByteSource source) {
  final container = readRar5Structure(source);
  final records = <RarEntryRecord>[];
  for (var index = 0; index < container.entries.length; index++) {
    final header = container.entries[index];
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
        recordIndex: index,
        hasCrc32: header.hasDataCrc,
        solid: header.solid,
        isSplit: header.isSplit,
        dictExp: header.dictExp,
        unpackedSizeUnknown: header.unpackedSizeUnknown,
        rar5Header: header,
      ),
    );
  }

  return records;
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
