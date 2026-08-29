import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/features/mobi/compression/huff_cdic.dart';
import 'package:e_livre/features/mobi/compression/palmdoc.dart';
import 'package:e_livre/features/mobi/header/mobi_header.dart';
import 'package:e_livre/features/mobi/header/pdb_header.dart';
import 'package:test/test.dart';

void main() {
  group('decompressPalmdoc', () {
    test('writes literal bytes as-is', () {
      final data = Uint8List.fromList([0x03, 0x41, 0x42, 0x43]);
      expect(decompressPalmdoc(data), 'ABC'.codeUnits);
    });

    test('writes literal zero', () {
      expect(decompressPalmdoc(Uint8List.fromList([0x00])), [0x00]);
    });

    test('expands 0xC0-0xFF as space plus char', () {
      // 0xC2 -> ' ' + (0xC2 ^ 0x80) = ' ' + 'B'
      expect(
        decompressPalmdoc(Uint8List.fromList([0xC2])),
        ' B'.codeUnits,
      );
    });

    test('copies back references', () {
      // Build: 'AAAA' then a pair referencing it.
      // pair word = (distance << 3) | (length - 3); distance <= output len.
      // Output 'ABCD' (4 bytes) then copy distance=4, length=3+1=4.
      // pair = (4 << 3) | 1 = 33 = 0x21 -> bytes 0x80, 0x21.
      final data = Uint8List.fromList(
        [0x04, 0x41, 0x42, 0x43, 0x44, 0x80, 0x21],
      );
      expect(
        decompressPalmdoc(data),
        'ABCDABCD'.codeUnits,
      );
    });

    test('decompresses real book text', () {
      final bytes =
          File('test/resources/mobi/alice-old.mobi').readAsBytesSync();
      final pdb = PdbHeader.parse(bytes);
      final header = MobiHeader.parse(pdb.record(0), pdb.ident);
      expect(header.compressionType, 2); // PalmDoc
      final record = pdb.record(1);
      final chunk = decompressPalmdoc(record);
      expect(chunk, isNotEmpty);
    });
  });

  group('HuffReader', () {
    test('round-trips data through an 8-bit identity dictionary', () {
      final sections = <Uint8List>[_buildHuffHeader(), _buildCdic()];
      final reader = HuffReader(sections);

      final payload =
          Uint8List.fromList('Alice was beginning to get very tired'.codeUnits);
      final unpacked = reader.unpack(payload);
      expect(String.fromCharCodes(unpacked), 'Alice was beginning to get very tired');
    });
  });
}

/// Builds a minimal HUFF header: every byte maps to an 8-bit terminal
/// code with maxcode 255, so `unpack` becomes the identity function.
Uint8List _buildHuffHeader() {
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
    // v >> 8 = 255, v & 0x1F = 8, v & 0x80 set (terminal).
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
Uint8List _buildCdic() {
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
