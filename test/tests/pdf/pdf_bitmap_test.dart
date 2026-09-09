import 'dart:typed_data';

import 'package:e_livre/src/features/pdf/image/pdf_bitmap.dart';
import 'package:test/test.dart';

void main() {
  group('PdfBitmap', () {
    test('fromPacked validates dimensions', () {
      expect(
        () => PdfBitmap.fromPacked(width: 0, height: 8, packed: Uint8List(8)),
        throwsA(predicate((final error) => error.toString().contains('invalid dimensions'))),
      );
    });

    test('fromPacked trims oversized payloads', () {
      final bitmap = PdfBitmap.fromPacked(width: 9, height: 2, packed: Uint8List(64));
      expect(bitmap.packed.length, 4); // 2 rows of ceil(9/8) bytes
    });

    test('fromPacked pads short payloads with white rows', () {
      final bitmap = PdfBitmap.fromPacked(width: 8, height: 3, packed: Uint8List.fromList([0xFF]));
      expect(bitmap.packed.length, 3);
      expect(bitmap.packed[0], 0xFF);
      expect(bitmap.packed[1], 0);
      expect(bitmap.packed[2], 0);
    });

    test('toGrayBytes maps 1 to white and 0 to black, MSB first', () {
      final bitmap = PdfBitmap(
        width: 10,
        height: 2,
        packed: Uint8List.fromList([
          0xC0, 0x00, // row 1: pixels 0 and 1 white
          0x00, 0x80, // row 2: pixel 8 white
        ]),
      );
      final gray = bitmap.toGrayBytes();
      expect(gray, hasLength(20));
      // Row 1 (0xC0, 0x00): pixels 0 and 1 white.
      expect(gray[0], 255);
      expect(gray[1], 255);
      expect(gray[2], 0);
      expect(gray[7], 0);
      // Row 2 (0x00, 0x80): pixel 8 white. Gray output is
      // row-interleaved, so row 2 starts at index 10.
      expect(gray[18], 255);
      expect(gray[19], 0);
    });

    test('toPngBytes produces a well-formed grayscale PNG', () {
      final png = PdfBitmap.fromPacked(
        width: 16,
        height: 4,
        packed: Uint8List.fromList([
          0x0F, 0x0F, // row 1
          0xF0, 0xF0, // row 2
          0x0F, 0x0F, // row 3
          0xF0, 0xF0, // row 4
        ]),
      ).toPngBytes();

      // PNG signature.
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      // IHDR chunk header: length 13 + type.
      expect(png.sublist(8, 16), [0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
      // Width and height, big endian.
      expect(png[16], 0);
      expect(png[17], 0);
      expect(png[18], 0);
      expect(png[19], 16);
      expect(png[20], 0);
      expect(png[21], 0);
      expect(png[22], 0);
      expect(png[23], 4);
      // Bit depth 8, color type grayscale, no interlace.
      expect(png[24], 8);
      expect(png[25], 0);
      expect(png[28], 0);
      // IEND is the final chunk.
      expect(png.sublist(png.length - 12, png.length - 8), [0, 0, 0, 0]);
      expect(png.sublist(png.length - 8, png.length - 4), [0x49, 0x45, 0x4E, 0x44]);
    });
  });
}
