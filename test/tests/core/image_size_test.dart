import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

void main() {
  group('imageSize', () {
    test('reads PNG dimensions from IHDR', () {
      // 1x1 transparent PNG.
      const base64Png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
          'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
      expect(imageSize(base64.decode(base64Png)), const ImageSize(1, 1));
    });

    test('reads GIF dimensions', () {
      final gif = Uint8List.fromList([
        ...'GIF89a'.codeUnits,
        0x60, 0x00, // width 96 LE
        0x1E, 0x00, // height 30 LE
        0x00,
      ]);
      expect(imageSize(gif), const ImageSize(96, 30));
    });

    test('reads BMP dimensions', () {
      final bmp = Uint8List(26);
      bmp[0] = 0x42;
      bmp[1] = 0x4D;
      final view = ByteData.sublistView(bmp);
      view.setInt32(18, 320, Endian.little);
      view.setInt32(22, 240, Endian.little);
      expect(imageSize(bmp), const ImageSize(320, 240));
    });

    test('reads JPEG dimensions from the SOF marker', () {
      final jpeg = Uint8List.fromList([
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0 stub
        0xFF, 0xC0, 0x00, 0x0B, // SOF0, length 11
        0x08, // precision
        0x01, 0x40, // height 320
        0x00, 0xC8, // width 200
        0x01, // components
        0x01, 0x11, 0x00,
        0xFF, 0xD9, // EOI
      ]);
      expect(imageSize(jpeg), const ImageSize(200, 320));
    });

    test('reads WebP VP8X canvas dimensions', () {
      final webp = Uint8List(30);
      webp.setRange(0, 4, 'RIFF'.codeUnits);
      webp.setRange(8, 12, 'WEBP'.codeUnits);
      webp.setRange(12, 16, 'VP8X'.codeUnits);
      final view = ByteData.sublistView(webp);
      view.setUint32(16, 10, Endian.little); // chunk size
      // canvas minus one: 97 x 64 -> 98x65
      webp[24] = 97;
      webp[27] = 64;
      expect(imageSize(webp), const ImageSize(98, 65));
    });

    test('real MOBI cover carries dimensions', () {
      final metadata = readMobiMetadata(
        File('test/resources/mobi/alice-kf8.azw3').readAsBytesSync(),
      );
      expect(metadata.cover, isNotNull);
      expect(metadata.cover!.width, greaterThan(0));
      expect(metadata.cover!.height, greaterThan(0));
    });
  });
}
