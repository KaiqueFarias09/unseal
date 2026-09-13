import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'seeded_random.dart';

/// Compression method for a ZIP entry.
enum ZipMethod {
  /// Method 0: stored, no compression.
  stored,

  /// Method 8: raw DEFLATE.
  deflate,
}

/// One file inside a ZIP container under construction.
final class ZipEntrySpec {
  const ZipEntrySpec(this.name, this.data, {this.method = ZipMethod.deflate, this.comment});

  /// Entry name (forward-slash separated, no leading slash).
  final String name;

  /// Entry payload bytes.
  final List<int> data;

  /// Compression method recorded in the headers.
  final ZipMethod method;

  /// Optional entry comment.
  final String? comment;
}

const int _localHeaderSignature = 0x04034b50;
const int _centralDirSignature = 0x02014b50;
const int _eocdSignature = 0x06054b50;

/// Builds a spec-compliant ZIP container with fully deterministic bytes.
///
/// Unlike generic ZIP encoders this exposes the pieces robustness tests
/// care about: per-entry compression method, entry comments, archive
/// comment and fixed timestamps (1980-01-01) so output is reproducible
/// from inputs alone.
Uint8List buildZip(final List<ZipEntrySpec> entries, {final String? archiveComment}) {
  final out = BytesBuilder(copy: false);
  final centralRecords = <_CentralRecord>[];

  for (final entry in entries) {
    final nameBytes = Uint8List.fromList(utf8.encode(entry.name));
    final payload = _encodePayload(entry);
    final commentBytes = entry.comment == null
        ? Uint8List(0)
        : Uint8List.fromList(utf8.encode(entry.comment!));
    final crc = crc32(entry.data);
    final localOffset = out.length;

    out.add(_u32(_localHeaderSignature));
    out.add(_u16(20)); // version needed
    out.add(_u16(0)); // flags: none (sizes are known up front)
    out.add(_u16(entry.method == ZipMethod.deflate ? 8 : 0));
    out.add(_u16(0)); // mod time
    out.add(_u16(0x21)); // mod date 1980-01-01
    out.add(_u32(crc));
    out.add(_u32(payload.length));
    out.add(_u32(entry.data.length));
    out.add(_u16(nameBytes.length));
    out.add(_u16(0)); // extra field length (local headers have no comment field)
    out.add(nameBytes);
    out.add(payload);
    centralRecords.add(
      _CentralRecord(
        name: nameBytes,
        crc: crc,
        compressed: payload.length,
        uncompressed: entry.data.length,
        method: entry.method == ZipMethod.deflate ? 8 : 0,
        localOffset: localOffset,
        comment: commentBytes,
      ),
    );
  }

  final centralStart = out.length;
  for (final record in centralRecords) {
    out.add(_u32(_centralDirSignature));
    out.add(_u16(20)); // version made by
    out.add(_u16(20)); // version needed
    out.add(_u16(0)); // flags
    out.add(_u16(record.method));
    out.add(_u16(0)); // time
    out.add(_u16(0x21)); // date
    out.add(_u32(record.crc));
    out.add(_u32(record.compressed));
    out.add(_u32(record.uncompressed));
    out.add(_u16(record.name.length));
    out.add(_u16(0)); // extra
    out.add(_u16(record.comment.length));
    out.add(_u16(0)); // disk number
    out.add(_u16(0)); // internal attrs
    out.add(_u32(0)); // external attrs
    out.add(_u32(record.localOffset));
    out.add(record.name);
    out.add(record.comment);
  }
  final centralSize = out.length - centralStart;

  final commentBytes = archiveComment == null
      ? Uint8List(0)
      : Uint8List.fromList(utf8.encode(archiveComment));
  out.add(_u32(_eocdSignature));
  out.add(_u16(0)); // disk
  out.add(_u16(0)); // cd disk
  out.add(_u16(centralRecords.length));
  out.add(_u16(centralRecords.length));
  out.add(_u32(centralSize));
  out.add(_u32(centralStart));
  out.add(_u16(commentBytes.length));
  out.add(commentBytes);

  return out.toBytes();
}

/// Decompresses method-8 payloads written by [buildZip] (raw DEFLATE).
Uint8List decodeZipPayload(final Uint8List payload, {final bool deflate = true}) =>
    deflate ? Uint8List.fromList(ZLibDecoder(raw: true).convert(payload)) : payload;

Uint8List _encodePayload(final ZipEntrySpec entry) {
  if (entry.method == ZipMethod.stored) {
    return Uint8List.fromList(entry.data);
  }
  return Uint8List.fromList(ZLibEncoder(raw: true, level: 9).convert(entry.data));
}

final class _CentralRecord {
  const _CentralRecord({
    required this.name,
    required this.crc,
    required this.compressed,
    required this.uncompressed,
    required this.method,
    required this.localOffset,
    required this.comment,
  });

  final Uint8List name;
  final int crc;
  final int compressed;
  final int uncompressed;
  final int method;
  final int localOffset;
  final Uint8List comment;
}

Uint8List _u16(final int value) => Uint8List.fromList([value & 0xFF, (value >> 8) & 0xFF]);
Uint8List _u32(final int value) => Uint8List.fromList([
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
]);

final List<int> _crcTable = List<int>.generate(256, (final index) {
  var c = index;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) == 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
  }
  return c;
});

/// Standard ZIP/PNG CRC-32.
int crc32(final List<int> data, [int crc = 0]) {
  crc ^= 0xFFFFFFFF;
  for (final byte in data) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Deterministic per-index synthetic chapter title (never a real title).
String syntheticTitle(final SeededRandom random) =>
    '${random.word(5)} ${random.word(4)} ${random.word(6)}';
