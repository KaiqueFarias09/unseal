// Builders for synthetic MOBI / PDB binary fixtures.
//
// Real AZW3 files with CONT/CRES image containers or HUFF-compressed
// text are impractical to ship, so the tests assemble them from
// parts and run the real parser over the result.

// Byte-packing builders read best as sequential field writes.
// ignore_for_file: cascade_invocations

import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:e_livre/src/features/mobi/header/pdb_header.dart';

/// A 1x1 transparent PNG.
final Uint8List tinyPng = convert.base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Builds a minimal HUFF header: every byte maps to an 8-bit terminal
/// code with maxcode 255, so `unpack` becomes the identity function.
Uint8List buildHuffHeader() {
  final buffer = BytesBuilder();
  buffer.add('HUFF'.codeUnits);
  buffer.add(Uint8List.fromList([0, 0, 0, 0x18]));

  const off1 = 16; // dict1 table follows the 16-byte header
  const off2 = off1 + 256 * 4; // dict2 after dict1
  final offsets = ByteData(8)
    ..setUint32(0, off1)
    ..setUint32(4, off2);
  buffer.add(offsets.buffer.asUint8List());

  // dict1: 256 entries; codelen=8, terminal, maxcode=255.
  final dict1 = ByteData(256 * 4);
  for (var i = 0; i < 256; i++) {
    dict1.setUint32(i * 4, (255 << 8) | 0x80 | 8);
  }
  buffer.add(dict1.buffer.asUint8List());

  // dict2: 32 (min, max) pairs for codelens 1..32; only codelen 8
  // (index 7) is live: min 0, max (256 << 24) - 1.
  final dict2 = ByteData(64 * 4);
  for (var i = 0; i < 32; i++) {
    if (i == 7) {
      dict2.setUint32(i * 8, 0);
      dict2.setUint32(i * 8 + 4, 0xFFFFFFFF);
    } else {
      dict2.setUint32(i * 8, 0xFFFFFFFF);
      dict2.setUint32(i * 8 + 4, 0);
    }
  }
  buffer.add(dict2.buffer.asUint8List());
  return buffer.takeBytes();
}

/// Builds a CDIC dictionary whose cached entry r holds the literal
/// byte 255 - r (matching the identity code above).
Uint8List buildCdic() {
  final buffer = BytesBuilder();
  buffer.add('CDIC'.codeUnits);
  buffer.add(Uint8List.fromList([0, 0, 0, 0x10]));

  final header = ByteData(8)
    ..setUint32(0, 256) // phrases
    ..setUint32(4, 8); // bits: 1 << 8 >= 256 entries
  buffer.add(header.buffer.asUint8List());

  // Offsets table: entry i lives at 16 + 256*2 + i * 3.
  const base = 16 + 256 * 2;
  final offsets = ByteData(256 * 2);
  for (var i = 0; i < 256; i++) {
    offsets.setUint16(i * 2, base - 16 + i * 3);
  }
  buffer.add(offsets.buffer.asUint8List());

  // Entries: u16 blen (cached | length 1) + 1 data byte.
  for (var i = 0; i < 256; i++) {
    final entry = ByteData(3)
      ..setUint16(0, 0x8000 | 1)
      ..setUint8(2, 255 - i);
    buffer.add(entry.buffer.asUint8List());
  }
  return buffer.takeBytes();
}

/// A minimal JPEG stub (magic bytes are enough for the sniffer).
final Uint8List tinyJpeg = Uint8List.fromList([
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  0,
  1,
  2,
  3,
  0xFF,
  0xD9,
]);

/// Assembles a PalmDB container holding [records].
Uint8List buildPdb(final String name, final List<Uint8List> records) {
  final tableLength = records.length * 8;
  var position = 78 + tableLength;
  final table = ByteData(tableLength);
  for (var i = 0; i < records.length; i++) {
    table.setUint32(i * 8, position);
    position += records[i].length;
  }

  final head = ByteData(78);
  final nameUnits = name.codeUnits;
  for (var i = 0; i < nameUnits.length && i < 32; i++) {
    head.setUint8(i, nameUnits[i]);
  }
  head.buffer.asUint8List().setRange(60, 68, 'BOOKMOBI'.codeUnits);
  head.setUint16(76, records.length);

  final builder = BytesBuilder(copy: false)
    ..add(head.buffer.asUint8List())
    ..add(table.buffer.asUint8List());
  for (final record in records) {
    builder.add(record);
  }
  return builder.takeBytes();
}

/// Rebuilds [file] with [additions] appended as new PDB records.
Uint8List appendPdbRecords(
  final Uint8List file,
  final List<Uint8List> additions,
) {
  final pdb = PdbHeader.parse(file);
  final records = <Uint8List>[
    for (var i = 0; i < pdb.count; i++) Uint8List.fromList(pdb.record(i)),
    ...additions,
  ];
  return buildPdb(pdb.name, records);
}

/// Builds a MOBI header record (record 0) with the given fields.
Uint8List buildMobiRecord0({
  final int compressionType = 2,
  final int textRecordCount = 0,
  final int textRecordSize = 4096,
  final int encryptionType = 0,
  final int codepage = 65001,
  final int mobiVersion = 6,
  final int firstImageIndex = -1,
  final int huffOffset = 0,
  final int huffRecordCount = 0,
  final int extraFlags = 0,
  final int exthFlags = 0,
  final int headerLength = 0xE8,
  final int fdstCount = 0,
  final String title = 'Synthetic',
  final Uint8List? exth,
}) {
  final exthBytes = exth ?? Uint8List(0);
  final titleOffset = 16 + headerLength + exthBytes.length;
  var length = titleOffset + title.length;
  if (length < 0x120) {
    length = 0x120;
  }
  final record = Uint8List(length);
  final view = ByteData.sublistView(record);
  view.setUint16(0, compressionType);
  view.setUint16(8, textRecordCount);
  view.setUint16(10, textRecordSize);
  view.setUint16(12, encryptionType);
  record.setRange(16, 20, 'MOBI'.codeUnits);
  view.setUint32(20, headerLength);
  view.setUint32(28, codepage);
  view.setUint32(32, 1);
  view.setUint32(36, 6);
  view.setUint32(0x54, titleOffset);
  view.setUint32(0x58, title.length);
  view.setUint32(0x5C, 9);
  view.setUint32(0x68, mobiVersion);
  view.setUint32(0x6C, firstImageIndex);
  view.setUint32(0x70, huffOffset);
  view.setUint32(0x74, huffRecordCount);
  view.setUint32(0x80, exthFlags);
  view.setUint32(0xC4, fdstCount);
  if (length >= 0xF4) {
    view.setUint32(0xF4, 0xFFFFFFFF); // ncx
  }
  if (length >= 0xF4 + 2) {
    view.setUint16(0xF2, extraFlags);
  }
  record.setRange(titleOffset, titleOffset + title.length, title.codeUnits);
  if (exthBytes.isNotEmpty) {
    record.setRange(
      16 + headerLength,
      16 + headerLength + exthBytes.length,
      exthBytes,
    );
  }
  return record;
}

/// Builds an EXTH block from `(id, payload)` records.
Uint8List buildExth(final List<(int, Uint8List)> records) {
  final body = BytesBuilder(copy: false);
  for (final (id, payload) in records) {
    final entry = ByteData(8 + payload.length)
      ..setUint32(0, id)
      ..setUint32(4, 8 + payload.length);
    entry.buffer.asUint8List().setRange(8, 8 + payload.length, payload);
    body.add(entry.buffer.asUint8List());
  }
  final bodyBytes = body.takeBytes();
  final header = ByteData(12)
    ..setUint32(4, 12 + bodyBytes.length)
    ..setUint32(8, records.length);
  header.buffer.asUint8List().setRange(0, 4, 'EXTH'.codeUnits);
  final block = BytesBuilder(copy: false)
    ..add(header.buffer.asUint8List())
    ..add(bodyBytes);
  return block.takeBytes();
}

/// Builds a KF8 `CONT` record whose EXTH section advertises [mime] as
/// resource type 539.
Uint8List buildContRecord({final String mime = 'application/image'}) {
  final payload = mime.codeUnits;
  final entrySize = 8 + payload.length;
  final record = Uint8List(60 + entrySize);
  record.setRange(0, 4, 'CONT'.codeUnits);
  record.setRange(48, 52, 'EXTH'.codeUnits);
  final view = ByteData.sublistView(record);
  view.setUint32(52, 8 + entrySize);
  view.setUint32(60, 539);
  view.setUint32(64, entrySize);
  record.setRange(68, 68 + payload.length, payload);
  return record;
}

/// Builds a KF8 `CRES` record wrapping [image] behind the 12-byte
/// prefix the container loader skips.
Uint8List buildCresRecord(final Uint8List image) {
  final record = Uint8List(12 + image.length);
  record.setRange(0, 4, 'CRES'.codeUnits);
  record.setRange(12, 12 + image.length, image);
  return record;
}
