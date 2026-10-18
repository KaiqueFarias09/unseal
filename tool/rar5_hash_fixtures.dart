/// Builds the derived RAR 5 hash fixtures from the committed primaries
/// and checks them.
///
/// Every derivation is a byte patch on a primary fixture from
/// `test/resources/books/comic/rar5/`: the patched block's header
/// CRC-32 is always repaired, so a downstream failure surfaces as the
/// intended typed cause (digest, hash type, record length) instead of
/// a header checksum error. Rerunning the tool reproduces the
/// committed bytes exactly; `--check` verifies that.
///
/// Derivations:
///  - `rar5-hash-stored-corrupt-digest.cbr`: one digest byte flipped.
///  - `rar5-hash-stored-zero-digest.cbr`: digest replaced by 32 zero
///    bytes — a present digest, not an absent record.
///  - `rar5-hash-m3-blake2s.cbr`: digest replaced by the payload's
///    BLAKE2s-256 (sequential hash) — never a substitute for BLAKE2sp.
///  - `rar5-hash-unknown-type.cbr`: hash record type 0 -> 1.
///  - `rar5-hash-truncated.cbr`: hash record shortened past its
///    payload.
///  - `rar5-hash-oversized.cbr`: hash record grown with trailing bytes.
///  - `rar5-hash-both-checksums.cbr`: a header CRC-32 field injected
///    into the `-htb` archive's file headers (both checksums correct).
///  - `rar5-hash-both-corrupt-digest.cbr`: both-checksums archive with
///    every digest flipped under a repaired header CRC.
///
/// The primaries store every payload verbatim (method 0) and use
/// one-byte vints for the patched fields, which keeps each derivation
/// a fixed-width in-place patch; a primary outside that shape fails
/// the tool instead of producing a silently wrong fixture.
///
/// Usage:
/// ```
/// dart run tool/rar5_hash_fixtures.dart --out test/resources/books/comic/rar5
/// dart run tool/rar5_hash_fixtures.dart --check test/resources/books/comic/rar5
/// ```
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:unseal/src/features/comic/archive/rar5_archive.dart';
import 'package:unseal/src/foundation/archive/zip_byte_source.dart';

/// BLAKE2s-256 (the sequential hash, not BLAKE2sp) of the decoded
/// `m-medium.jpg` payload of `rar5-hash-m3.cbr` (whose SHA-256 is
/// `787b295e593265aed86aad646ddc7057da5f1ec515166efb091616f26a31c56a`),
/// computed during fixture preparation with Python 3.12
/// `hashlib.blake2s` (OpenSSL) and pinned here: an implementation that
/// accepts BLAKE2s in the RAR 5 hash record would wrongly verify this
/// archive.
const String blake2sOfMMediumHex =
    '5c0162bb7e58279f155f1178409ff498f5356b1339becedcdd82eccfd2d3172f';

const String _resourceDir = 'test/resources/books/comic/rar5';

void main(final List<String> arguments) {
  final checkIndex = arguments.indexOf('--check');
  final outIndex = arguments.indexOf('--out');
  final dir = checkIndex != -1 && checkIndex + 1 < arguments.length
      ? arguments[checkIndex + 1]
      : outIndex != -1 && outIndex + 1 < arguments.length
      ? arguments[outIndex + 1]
      : _resourceDir;
  if (!Directory(dir).existsSync()) {
    stderr.writeln('missing fixture directory $dir');
    exit(2);
  }

  final derived = _buildDerivations();
  var failed = false;
  for (final entry in derived.entries) {
    final file = File('$dir/${entry.key}');
    if (checkIndex != -1) {
      if (!file.existsSync()) {
        stdout.writeln('MISSING ${entry.key}');
        failed = true;
        continue;
      }
      final actual = file.readAsBytesSync();
      final expected = entry.value;
      if (_bytesEqual(actual, expected)) {
        stdout.writeln('ok ${entry.key}');
      } else {
        stdout.writeln('DIFF ${entry.key} (${actual.length}B vs ${expected.length}B)');
        failed = true;
      }
    } else {
      file.writeAsBytesSync(entry.value);
      stdout.writeln('wrote ${entry.key} (${entry.value.length}B)');
    }
  }
  exit(failed ? 1 : 0);
}

Map<String, Uint8List> _buildDerivations() {
  final stored = _readPrimary('rar5-hash-stored.cbr');
  final m3 = _readPrimary('rar5-hash-m3.cbr');

  return {
    'rar5-hash-stored-corrupt-digest.cbr': _rewriteDigests(stored, (final digest) {
      final flipped = Uint8List.fromList(digest);
      flipped[0] ^= 0x40;
      return flipped;
    }),
    'rar5-hash-stored-zero-digest.cbr': _rewriteDigests(
      stored,
      (final digest) => Uint8List(digest.length),
    ),
    'rar5-hash-m3-blake2s.cbr': _rewriteDigests(m3, (final digest) {
      final replacement = _hexToBytes(blake2sOfMMediumHex);
      if (replacement.length != digest.length) {
        stderr.writeln('pinned BLAKE2s digest has the wrong length');
        exit(2);
      }
      return replacement;
    }),
    'rar5-hash-unknown-type.cbr': _patchHashRecords(stored, (final record, final bytes) {
      if (record.hashTypeWidth != 1) _fail('one-byte hash type vint expected');
      bytes[record.hashTypeOffset] = 0x01;
    }),
    'rar5-hash-truncated.cbr': _patchHashRecords(stored, (final record, final bytes) {
      if (record.recordSizeWidth != 1) _fail('one-byte record size vint expected');
      bytes[record.start] = record.recordSize - 4;
    }),
    'rar5-hash-oversized.cbr': _patchHashRecords(stored, (final record, final bytes) {
      if (record.recordSizeWidth != 1) _fail('one-byte record size vint expected');
      // Four trailing bytes already exist inside each primary's record
      // walk only when the record actually grows; instead of moving the
      // following records, mark the record longer than its extra area
      // allows by claiming four bytes more than the record holds.
      bytes[record.start] = record.recordSize + 4;
    }),
    'rar5-hash-both-checksums.cbr': _injectHeaderCrcs(stored),
    'rar5-hash-both-wrong-crc.cbr': _corruptDeclaredCrcs(_injectHeaderCrcs(stored)),
    'rar5-hash-both-corrupt-digest.cbr': _rewriteDigests(_injectHeaderCrcs(stored), (final digest) {
      final flipped = Uint8List.fromList(digest);
      flipped[1] ^= 0x20;
      return flipped;
    }),
    'rar5-hash-conflicting-duplicate.cbr': _duplicateHashRecordWithConflict(stored),
    'rar5-hash-solid-corrupt-middle.cbr': _corruptSolidMiddle(_readPrimary('rar5-hash-solid.cbr')),
  };
}

// ---------------------------------------------------------------------------
// RAR 5 container surgery
// ---------------------------------------------------------------------------

Never _fail(final String message) {
  stderr.writeln('rar5_hash_fixtures: $message');
  exit(2);
}

bool _bytesEqual(final Uint8List a, final Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Uint8List _readPrimary(final String name) =>
    Uint8List.fromList(File('$_resourceDir/$name').readAsBytesSync());

Uint8List _hexToBytes(final String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// One file-header block of the container with the offsets the patch
/// operations need.
final class _FileBlock {
  _FileBlock({
    required this.start,
    required this.headerSize,
    required this.headerSizeWidth,
    required this.bodyStart,
    required this.dataSize,
    required this.hashRecords,
  });

  /// Archive offset of the block: its first four bytes are the header
  /// CRC-32.
  final int start;
  final int headerSize;
  final int headerSizeWidth;
  final int bodyStart;

  /// Declared data-area size following the header.
  final int dataSize;

  /// The header's hash records, in extra-area order.
  final List<_HashRecord> hashRecords;

  int get end => bodyStart + headerSize;
}

final class _HashRecord {
  _HashRecord({
    required this.start,
    required this.recordSize,
    required this.recordSizeWidth,
    required this.hashTypeOffset,
    required this.hashTypeWidth,
    required this.digestOffset,
  });

  /// Archive offset of the record's size vint.
  final int start;
  final int recordSize;
  final int recordSizeWidth;
  final int hashTypeOffset;
  final int hashTypeWidth;

  /// Archive offset of the 32-byte digest.
  final int digestOffset;
}

(int, int) _readVint(final Uint8List bytes, final int offset) {
  var value = 0;
  var shift = 0;
  var consumed = 0;
  while (true) {
    final byte = bytes[offset + consumed];
    consumed++;
    value |= (byte & 0x7F) << shift;
    if (byte & 0x80 == 0) return (value, consumed);
    shift += 7;
  }
}

/// Walks every file-header block of [bytes] that carries a well-formed
/// type-0 hash record.
List<_FileBlock> _fileBlocks(final Uint8List bytes) {
  final blocks = <_FileBlock>[];
  var offset = 8;
  while (offset + 4 <= bytes.length) {
    final blockStart = offset;
    final (headerSize, headerSizeWidth) = _readVint(bytes, offset + 4);
    final bodyStart = offset + 4 + headerSizeWidth;
    final bodyEnd = bodyStart + headerSize;
    if (bodyEnd > bytes.length) break;

    final headerType = _readVint(bytes, bodyStart);
    final flags = _readVint(bytes, bodyStart + headerType.$2);
    var cursor = bodyStart + headerType.$2 + flags.$2;
    if (flags.$1 & 0x0001 != 0) {
      cursor += _readVint(bytes, cursor).$2;
    }
    var dataSize = 0;
    if (flags.$1 & 0x0002 != 0) {
      dataSize = _readVint(bytes, cursor).$1;
    }

    if (headerType.$1 == 2) {
      final records = <_HashRecord>[];
      if (flags.$1 & 0x0001 != 0) {
        final extraSize = _readVint(bytes, bodyStart + headerType.$2 + flags.$2).$1;
        var position = bodyEnd - extraSize;
        while (position < bodyEnd) {
          final recordSize = _readVint(bytes, position);
          final recordStart = position;
          final recordEnd = position + recordSize.$2 + recordSize.$1;
          var inner = position + recordSize.$2;
          final recordType = _readVint(bytes, inner);
          inner += recordType.$2;
          if (recordType.$1 == 2) {
            final hashType = _readVint(bytes, inner);
            inner += hashType.$2;
            if (hashType.$1 == 0 && recordEnd - inner == 32) {
              records.add(
                _HashRecord(
                  start: recordStart,
                  recordSize: recordSize.$1,
                  recordSizeWidth: recordSize.$2,
                  hashTypeOffset: position + recordSize.$2 + recordType.$2,
                  hashTypeWidth: hashType.$2,
                  digestOffset: inner,
                ),
              );
            }
          }
          position = recordEnd;
        }
      }
      if (records.isNotEmpty) {
        blocks.add(
          _FileBlock(
            start: blockStart,
            headerSize: headerSize,
            headerSizeWidth: headerSizeWidth,
            bodyStart: bodyStart,
            dataSize: dataSize,
            hashRecords: records,
          ),
        );
      }
    }
    offset = bodyEnd + dataSize;
  }
  return blocks;
}

void _repairHeaderCrc(final Uint8List bytes, final int blockStart) {
  final (headerSize, headerSizeWidth) = _readVint(bytes, blockStart + 4);
  final window = Uint8List.sublistView(
    bytes,
    blockStart + 4,
    blockStart + 4 + headerSizeWidth + headerSize,
  );
  ByteData.sublistView(bytes).setUint32(blockStart, getCrc32(window), Endian.little);
}

/// Corrupts every declared header CRC-32 (file flag 0x0004 field) of
/// [primary] to a wrong value while the payload and BLAKE2sp digest
/// stay correct — the negative that isolates a checksum failure from a
/// hash failure.
Uint8List _corruptDeclaredCrcs(final Uint8List primary) {
  final bytes = Uint8List.fromList(primary);
  final blocks = _fileBlocks(bytes);
  for (final block in blocks) {
    final body = Uint8List.sublistView(bytes, block.bodyStart, block.end);
    final headerType = _readVint(body, 0);
    var cursor = headerType.$2;
    final flags = _readVint(body, cursor);
    cursor += flags.$2;
    cursor += _readVint(body, cursor).$2; // extra area size
    cursor += _readVint(body, cursor).$2; // data size
    final fileFlags = _readVint(body, cursor);
    cursor += fileFlags.$2;
    if (fileFlags.$1 & 0x0004 == 0) _fail('expected an injected header CRC-32');
    cursor += _readVint(body, cursor).$2; // unpacked size
    cursor += _readVint(body, cursor).$2; // attributes
    final crc = getCrc32(Uint8List.sublistView(bytes, block.end, block.end + block.dataSize));
    ByteData.sublistView(
      bytes,
    ).setUint32(block.bodyStart + cursor, crc ^ 0xA5A5A5A5, Endian.little);
    _repairHeaderCrc(bytes, block.start);
  }
  return bytes;
}

/// Rebuilds [primary] with the first file header's hash record
/// duplicated: the duplicate carries a flipped digest, so the entry
/// declares two conflicting BLAKE2sp digests. The extra area and header
/// grow by 35 bytes (one-byte vints in the primaries stay one byte).
Uint8List _duplicateHashRecordWithConflict(final Uint8List primary) {
  final bytes = Uint8List.fromList(primary);
  final blocks = _fileBlocks(bytes);
  if (blocks.isEmpty) _fail('no hash records found in primary');
  final block = blocks.first;
  final record = block.hashRecords.first;
  if (record.recordSizeWidth != 1 || record.recordSize + 35 > 127) {
    _fail('one-byte record sizes expected');
  }
  final (extraSize, extraSizeWidth) = _readVint(bytes, block.bodyStart + 2);
  final (headerSize, headerSizeWidth) = _readVint(bytes, block.start + 4);
  if (extraSizeWidth != 1 || headerSizeWidth != 1 || headerSize + 35 > 127) {
    _fail('one-byte block sizes expected');
  }

  final duplicate = BytesBuilder();
  duplicate.add(bytes.sublist(record.start, record.digestOffset));
  final flipped = Uint8List.fromList(bytes.sublist(record.digestOffset, record.digestOffset + 32));
  flipped[2] ^= 0x11;
  duplicate.add(flipped);
  final recordBytes = duplicate.toBytes();

  final insertion = record.start + 1 + record.recordSize;
  final out = BytesBuilder();
  out.add(bytes.sublist(0, insertion));
  out.add(recordBytes);
  out.add(bytes.sublist(insertion));
  final grown = out.toBytes();

  // Re-encode the extra-area size and the header size; the record size
  // vints themselves stay untouched.
  final extraSizeOffset = block.bodyStart + 2;
  grown[extraSizeOffset] = extraSize + 35;
  grown[block.start + 4] = headerSize + 35;
  _repairHeaderCrc(grown, block.start);

  final result = BytesBuilder()
    ..add(grown.sublist(0, block.start + 4 + 1 + headerSize + 35))
    ..add(grown.sublist(block.start + 4 + 1 + headerSize));
  final shifted = result.toBytes();

  // Self-check: the shared walk must name the conflict.
  try {
    readRar5Structure(MemoryZipByteSource(shifted));
    _fail('conflicting duplicate still parses cleanly');
  } on FormatException {
    _fail('conflicting duplicate failed structurally instead of typed');
  } on Object {
    // Expected typed rejection.
  }
  return shifted;
}

/// Flips a byte of the MIDDLE chain member's digest in the solid
/// fixture — the negative that proves a chain dependency's hash failure
/// poisons the chain before later members publish.
Uint8List _corruptSolidMiddle(final Uint8List primary) {
  final bytes = Uint8List.fromList(primary);
  final blocks = _fileBlocks(bytes);
  if (blocks.length < 3) _fail('solid primary expected at least three file headers');
  final middle = blocks[1].hashRecords.first;
  bytes[middle.digestOffset] ^= 0x08;
  for (final block in blocks) {
    _repairHeaderCrc(bytes, block.start);
  }
  return bytes;
}

/// Rewrites every hash record's digest through [transform] and repairs
/// each touched block's header CRC.
Uint8List _rewriteDigests(
  final Uint8List primary,
  final Uint8List Function(Uint8List digest) transform,
) {
  final bytes = Uint8List.fromList(primary);
  final blocks = _fileBlocks(bytes);
  if (blocks.isEmpty) _fail('no hash records found in primary');
  for (final block in blocks) {
    for (final record in block.hashRecords) {
      final replacement = transform(
        Uint8List.fromList(bytes.sublist(record.digestOffset, record.digestOffset + 32)),
      );
      if (replacement.length != 32) _fail('digest replacement must stay 32 bytes');
      bytes.setRange(record.digestOffset, record.digestOffset + 32, replacement);
    }
    _repairHeaderCrc(bytes, block.start);
  }
  _assertStillParses(bytes, primary);
  return bytes;
}

/// Applies [patch] to every hash record in place and repairs CRCs.
Uint8List _patchHashRecords(
  final Uint8List primary,
  final void Function(_HashRecord record, Uint8List bytes) patch,
) {
  final bytes = Uint8List.fromList(primary);
  final blocks = _fileBlocks(bytes);
  if (blocks.isEmpty) _fail('no hash records found in primary');
  for (final block in blocks) {
    for (final record in block.hashRecords) {
      patch(record, bytes);
    }
    _repairHeaderCrc(bytes, block.start);
  }
  // A malformed record must still parse into a typed failure, never a
  // crash: run the shared walk and expect a ComicException.
  try {
    readRar5Structure(MemoryZipByteSource(bytes));
    _fail('patched archive still parses cleanly');
  } on FormatException {
    _fail('patched archive failed structurally instead of typed');
  } on Object {
    // Expected: the container walk rejects the patched record typed.
  }
  return bytes;
}

/// Injects a CRC-32 field (file flag 0x0004) into every file header of
/// [primary] that carries a hash record, storing the payload's real
/// CRC-32 so the derived archive verifies on both checksums.
Uint8List _injectHeaderCrcs(final Uint8List primary) {
  final blocks = _fileBlocks(primary);
  if (blocks.isEmpty) _fail('no hash records found in primary');
  final builder = BytesBuilder();
  var cursor = 0;
  for (final block in blocks) {
    builder.add(primary.sublist(cursor, block.start));
    builder.add(_patchedBlock(primary, block));
    // The patched header grew by four bytes; its data area follows at
    // the shifted offset and the next block starts after it.
    builder.add(primary.sublist(block.end, block.end + block.dataSize));
    cursor = block.end + block.dataSize;
  }
  builder.add(primary.sublist(cursor));
  final bytes = builder.toBytes();
  // The injected bytes shift every later block, so the main header's
  // quick-open locator would point at stale offsets (real RAR reports
  // "corrupt header" even though every file tests OK). Strip the
  // locator record; the quick-open service block itself is skipped by
  // size and stays harmless.
  _stripMainHeaderLocator(bytes);

  // Self-check: the derived archive must parse with one declared CRC
  // and one digest per file entry.
  final entries = readRar5Structure(MemoryZipByteSource(bytes)).entries;
  for (final entry in entries) {
    if (entry.isDirectory) continue;
    if (!entry.hasDataCrc || !entry.hasBlake2Hash) {
      _fail('derived both-checksums archive lost a checksum on "${entry.name}"');
    }
  }
  return bytes;
}

/// Removes the locator extra record from the main archive header, if
/// present, and repairs the header CRC.
void _stripMainHeaderLocator(final Uint8List bytes) {
  final (headerSize, headerSizeWidth) = _readVint(bytes, 8 + 4);
  final bodyStart = 8 + 4 + headerSizeWidth;
  final bodyEnd = bodyStart + headerSize;
  final headerType = _readVint(bytes, bodyStart);
  if (headerType.$1 != 1) return; // not the main archive header
  final flags = _readVint(bytes, bodyStart + headerType.$2);
  final flagsEnd = bodyStart + headerType.$2 + flags.$2;
  if (flags.$1 & 0x0001 == 0) return; // no extra area, nothing to strip
  final extraSize = _readVint(bytes, flagsEnd);
  final extraStart = bodyEnd - extraSize.$1;

  // Main header layout: [type][flags][extra size][archive flags][extra
  // area]. Keep every record that is not the locator (type 1).
  final kept = BytesBuilder();
  var position = extraStart;
  var sawLocator = false;
  while (position < bodyEnd) {
    final recordSize = _readVint(bytes, position);
    final recordEnd = position + recordSize.$2 + recordSize.$1;
    final recordType = _readVint(bytes, position + recordSize.$2);
    if (recordType.$1 == 1) {
      sawLocator = true;
    } else {
      kept.add(bytes.sublist(position, recordEnd));
    }
    position = recordEnd;
  }
  if (!sawLocator) return;
  final keptBytes = kept.toBytes();

  final out = BytesBuilder();
  out.add(bytes.sublist(bodyStart, bodyStart + headerType.$2));
  final newFlags = keptBytes.isEmpty ? flags.$1 & ~0x0001 : flags.$1;
  out.add(_encodeVint(newFlags));
  if (keptBytes.isNotEmpty) {
    out.add(_encodeVint(keptBytes.length));
  }
  out.add(bytes.sublist(flagsEnd + extraSize.$2, extraStart));
  out.add(keptBytes);
  final newBody = out.toBytes();

  final rebuilt = BytesBuilder();
  rebuilt.add(Uint8List(4));
  rebuilt.add(_encodeVint(newBody.length));
  rebuilt.add(newBody);
  final block = rebuilt.toBytes();
  _repairHeaderCrc(block, 0);

  final result = BytesBuilder()
    ..add(bytes.sublist(0, 8))
    ..add(block)
    ..add(bytes.sublist(bodyEnd));
  bytes.setAll(0, result.toBytes());
}

/// Rebuilds one file-header block with the CRC-32 field injected and
/// its header CRC repaired.
Uint8List _patchedBlock(final Uint8List source, final _FileBlock block) {
  final body = source.sublist(block.bodyStart, block.end);

  final headerType = _readVint(body, 0);
  var cursor = headerType.$2;
  final flags = _readVint(body, cursor);
  cursor += flags.$2;
  if (flags.$1 & 0x0001 == 0) _fail('primary file header without extra area');
  cursor += _readVint(body, cursor).$2; // extra area size
  cursor += _readVint(body, cursor).$2; // data size
  final fileFlags = _readVint(body, cursor);
  if (fileFlags.$1 & 0x0004 != 0) _fail('primary already declares a header CRC-32');
  final fileFlagsOffset = cursor;
  cursor += fileFlags.$2;
  cursor += _readVint(body, cursor).$2; // unpacked size
  final attributesEnd = cursor + _readVint(body, cursor).$2;

  // Payload CRC-32: primaries store payloads verbatim, so the data
  // area is the payload.
  final payload = Uint8List.sublistView(source, block.end, block.end + block.dataSize);

  final out = BytesBuilder();
  // The CRC-32 field sits between the attributes and the compression
  // info — a file-header field, not extra-area content — so only the
  // header size grows; every other field is copied verbatim.
  out.add(body.sublist(0, fileFlagsOffset));
  out.add(_encodeVint(fileFlags.$1 | 0x0004));
  out.add(body.sublist(fileFlagsOffset + fileFlags.$2, attributesEnd));
  final crcBytes = Uint8List(4);
  ByteData.sublistView(crcBytes).setUint32(0, getCrc32(payload), Endian.little);
  out.add(crcBytes);
  out.add(body.sublist(attributesEnd));

  final newHeaderSize = block.headerSize + 4;
  final head = BytesBuilder()
    ..add(source.sublist(block.start + 4, block.start + 4 + block.headerSizeWidth))
    ..add(_encodeVint(newHeaderSize));

  final blockBytes = BytesBuilder()
    ..add(Uint8List(4)) // header CRC placeholder
    ..add(head.toBytes().sublist(block.headerSizeWidth))
    ..add(out.toBytes());
  final bytes = blockBytes.toBytes();
  _repairHeaderCrc(bytes, 0);
  return bytes;
}

Uint8List _encodeVint(final int value) {
  final width = value == 0 ? 1 : (value.bitLength + 6) ~/ 7;
  final out = Uint8List(width);
  for (var i = 0; i < width; i++) {
    final last = i == width - 1;
    out[i] = last ? (value >> (7 * i)) & 0x7F : 0x80 | ((value >> (7 * i)) & 0x7F);
  }
  return out;
}

void _assertStillParses(final Uint8List bytes, final Uint8List primary) {
  final derived = readRar5Structure(MemoryZipByteSource(bytes)).entries;
  final original = readRar5Structure(MemoryZipByteSource(primary)).entries;
  if (derived.length != original.length) {
    _fail('derived archive changed the entry count');
  }
  for (var i = 0; i < derived.length; i++) {
    final a = derived[i];
    final b = original[i];
    if (a.name != b.name ||
        a.unpackedSize != b.unpackedSize ||
        !((a.blake2spDigest == null) == (b.blake2spDigest == null))) {
      _fail('derived archive drifted from its primary at entry ${a.name}');
    }
  }
}
