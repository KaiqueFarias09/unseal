import 'dart:convert';
import 'dart:typed_data';

import 'seeded_random.dart';

/// PalmDOC (MOBI) compression method 2: greedy LZ77 back-references plus
/// literal runs, exactly as the PalmDOC spec describes.
///
/// For robustness corpora we also need method 1 (no compression), which
/// is just the raw text chunked into records unchanged.
Uint8List palmDocCompress(final List<int> text) {
  final out = BytesBuilder(copy: false);
  var i = 0;
  while (i < text.length) {
    var bestDistance = 0;
    var bestLength = 0;
    final windowStart = (i - 4095).clamp(0, i);
    // Greedy longest match within the 4095-byte sliding window.
    for (var j = i - 1; j >= windowStart; j--) {
      var length = 0;
      while (length < 10 && i + length < text.length && text[j + length] == text[i + length]) {
        length++;
      }
      if (length > bestLength) {
        bestLength = length;
        bestDistance = i - j;
        if (length == 10) {
          break;
        }
      }
    }
    if (bestLength >= 3) {
      out.addByte(0x80 | ((bestLength - 3) << 4) | ((bestDistance >> 8) & 0x0F));
      out.addByte(bestDistance & 0xFF);
      i += bestLength;
    } else {
      final literal = text[i];
      if (literal < 0x80 && literal != 0x00) {
        out.addByte(literal);
      } else {
        // Escape: 0x00 followed by the byte value.
        out.addByte(0x00);
        out.addByte(literal);
      }
      i++;
    }
  }
  return out.toBytes();
}

/// A MOBI record 0 + PalmDB container generator.
final class PdbSpec {
  const PdbSpec({
    required this.records,
    this.name = 'FuzzFixture',
    this.type = 'BOOKMOBI',
    this.creator = 'MOBI',
    this.compression = 1,
    this.textEncoding = 65001,
    this.exthRecords = const [],
  });

  /// Records after record 0 (text records, image records, ...).
  final List<List<int>> records;

  /// PDB name field (truncated to 31 bytes).
  final String name;

  /// 8-byte type + creator string, e.g. `BOOKMOBI` (BOOK + MOBI).
  final String type;

  /// Creator override when [type] carries only 4 characters.
  final String creator;

  /// MOBI compression field: 1 = none, 2 = PalmDOC, 17480 = HUFF/CDIC.
  final int compression;

  /// Text encoding in the MOBI header (65001 = UTF-8).
  final int textEncoding;

  /// EXTH (type, valueBytes) pairs appended to the MOBI header.
  final List<(int, List<int>)> exthRecords;
}

/// Serializes a PalmDB with a MOBI record 0, EXTH block, and records.
///
/// All integers are big-endian per the PDB spec; epoch fields are fixed
/// so output bytes depend only on the spec.
Uint8List buildPdb(final PdbSpec spec) {
  final nameBytes = utf8.encode(spec.name).take(31).toList();
  final record0 = _buildMobiRecord0(spec);
  final allRecords = <Uint8List>[record0, for (final r in spec.records) Uint8List.fromList(r)];
  final headerSize = 78 + allRecords.length * 8 + 2;
  final out = BytesBuilder(copy: false);

  out.add(nameBytes);
  out.add(Uint8List(32 - nameBytes.length)); // name padding
  out.add(_u16(0)); // attributes
  out.add(_u16(0)); // version
  out.add(_u32(0x3862A180)); // creation: fixed 2000-01-01 epoch seconds
  out.add(_u32(0x3862A180)); // modification
  out.add(_u32(0)); // backup
  out.add(_u32(0)); // modification number
  out.add(_u32(0)); // app info id
  out.add(_u32(0)); // sort info id
  out.add(utf8.encode(spec.type.substring(0, 4).padRight(4)));
  out.add(
    utf8.encode(spec.type.length >= 8 ? spec.type.substring(4, 8) : spec.creator.padRight(4)),
  );
  out.add(_u32(0)); // uniqueIDseed
  out.add(_u32(0)); // nextRecordListID
  out.add(_u16(allRecords.length));
  var offset = headerSize;
  for (var i = 0; i < allRecords.length; i++) {
    out.add(_u32(offset));
    out.addByte(0); // record attributes
    out.add(_u24(i)); // unique id (3 bytes)
    offset += allRecords[i].length;
  }
  out.add(_u16(0)); // customary 2-byte gap to data
  for (final record in allRecords) {
    out.add(record);
  }
  return out.toBytes();
}

/// MOBI record 0 following the field offsets the PalmDOC/MOBI community
/// documents (and unseal's parser reads): PalmDOC part, `MOBI` magic at
/// 16, MOBI header at 20, EXTH at `16 + headerLength`, full name tail.
Uint8List _buildMobiRecord0(final PdbSpec spec) {
  const headerLength = 232; // canonical MOBI6 length (0xE8)
  final textRecordCount = spec.records.length;
  final exth = _buildExth(spec.exthRecords);
  final exthPresent = exth.isNotEmpty;

  // Layout: 248 bytes fixed region, then EXTH, then the full name.
  final fixed = Uint8List(248);
  final view = ByteData.sublistView(fixed);

  // PalmDOC part.
  view.setUint16(0, spec.compression);
  view.setUint16(2, 0); // unused
  view.setUint32(4, 0); // text length (readers recompute)
  view.setUint16(8, textRecordCount);
  view.setUint16(10, 4096); // text record size
  view.setUint16(12, 0); // encryption: none
  view.setUint16(14, 0); // unknown
  fixed.setRange(16, 20, utf8.encode('MOBI'));
  // MOBI header.
  view.setUint32(20, headerLength);
  view.setUint32(24, 2); // mobi type: MOBIbook
  view.setUint32(28, spec.textEncoding);
  view.setUint32(32, 0x1234); // unique id
  view.setUint32(36, 6); // file version
  view.setUint32(40, 0xFFFFFFFF); // orthographic index
  view.setUint32(44, 0xFFFFFFFF); // orthographic index tag count
  view.setUint32(48, 0xFFFFFFFF); // inflection index
  view.setUint32(52, 0xFFFFFFFF); // inflection index tag count
  view.setUint32(56, 0xFFFFFFFF); // index names
  view.setUint32(60, 0xFFFFFFFF); // index keys
  view.setUint32(64, 0); // extra index levels depth
  view.setUint32(84, 0); // 0x54: full name offset (patched below)
  view.setUint32(88, 0); // 0x58: full name length (patched below)
  view.setUint32(92, 9); // 0x5C: locale (en)
  view.setUint32(96, 0); // input language
  view.setUint32(100, 0); // output language
  view.setUint32(104, 6); // 0x68: mobi version
  view.setUint32(108, 0xFFFFFFFF); // 0x6C: first image index
  view.setUint32(112, 0); // huffman record offset
  view.setUint32(116, 0); // huffman record count
  view.setUint32(120, 0); // huffman table offset
  view.setUint32(124, 0); // huffman table length
  view.setUint32(128, exthPresent ? 0x60 : 0x40); // 0x80: EXTH flags
  view.setUint16(242, 0); // 0xF2: extra record data flags: none
  view.setUint32(244, 0xFFFFFFFF); // unknown terminator field

  final body = BytesBuilder(copy: false);
  body.add(fixed);
  final titleStart = 248 + exth.length;
  body.add(exth);

  // Full name (the MOBI-header title; EXTH 503 overrides for readers).
  final fullName = utf8.encode('Fuzz Fixture ${spec.name}');
  body.add(fullName);
  body.add(_u16(0)); // two trailing zero bytes follow the name

  final bytes = body.toBytes();
  // Patch the full name pointers now that positions are final.
  final patch = ByteData.sublistView(bytes);
  patch.setUint32(84, titleStart);
  patch.setUint32(88, fullName.length);
  return bytes;
}

Uint8List _buildExth(final List<(int, List<int>)> records) {
  if (records.isEmpty) {
    return Uint8List(0);
  }
  final body = BytesBuilder(copy: false);
  var length = 12;
  final recordBytes = <Uint8List>[];
  for (final (type, value) in records) {
    final record = BytesBuilder(copy: false);
    record.add(_u32(type));
    record.add(_u32(value.length + 8));
    record.add(value);
    final bytes = record.toBytes();
    recordBytes.add(bytes);
    length += bytes.length;
  }
  body.add(utf8.encode('EXTH'));
  body.add(_u32(length));
  body.add(_u32(records.length));
  for (final bytes in recordBytes) {
    body.add(bytes);
  }
  return body.toBytes();
}

/// Assembles a deterministic MOBI fixture: synthetic title/author EXTH
/// plus [chapterCount] uncompressed or PalmDOC-compressed text records.
Uint8List syntheticMobi(
  final int seed, {
  final int chapterCount = 3,
  final bool palmDocCompression = false,
}) {
  final random = SeededRandom(seed);
  final title = '${random.word(6)} ${random.word(5)}';
  final author = '${random.word(4)} ${random.word(6)}';
  final text = StringBuffer();
  for (var i = 0; i < chapterCount; i++) {
    text.write('Chapter ${i + 1}: ${random.word(8)} ${random.word(7)}.\n\n');
    for (var p = 0; p < 4; p++) {
      text.write('${random.word(5)} ${random.word(9)} ${random.word(6)} ${random.word(8)}.\n');
    }
    text.write('\n');
  }
  final textBytes = utf8.encode(text.toString());
  // Split into 4096-byte records as PalmDOC requires.
  final textRecords = <List<int>>[];
  for (var i = 0; i < textBytes.length; i += 4096) {
    final chunk = textBytes.sublist(i, (i + 4096).clamp(0, textBytes.length));
    textRecords.add(palmDocCompression ? palmDocCompress(chunk) : chunk);
  }
  return buildPdb(
    PdbSpec(
      records: textRecords,
      name: 'FuzzFixture$seed',
      compression: palmDocCompression ? 2 : 1,
      exthRecords: [(100, utf8.encode(author)), (503, utf8.encode(title))],
    ),
  );
}

Uint8List _u16(final int value) => Uint8List.fromList([(value >> 8) & 0xFF, value & 0xFF]);
Uint8List _u24(final int value) =>
    Uint8List.fromList([(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF]);
Uint8List _u32(final int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);
