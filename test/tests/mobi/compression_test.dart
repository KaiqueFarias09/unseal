import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/features/mobi/compression/huff_cdic.dart';
import 'package:e_livre/features/mobi/compression/palmdoc.dart';
import 'package:e_livre/features/mobi/header/mobi_header.dart';
import 'package:e_livre/features/mobi/header/pdb_header.dart';
import 'package:test/test.dart';

import 'mobi_fixture_builder.dart';

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
      final sections = <Uint8List>[buildHuffHeader(), buildCdic()];
      final reader = HuffReader(sections);

      final payload =
          Uint8List.fromList('Alice was beginning to get very tired'.codeUnits);
      final unpacked = reader.unpack(payload);
      expect(String.fromCharCodes(unpacked), 'Alice was beginning to get very tired');
    });
  });
}
