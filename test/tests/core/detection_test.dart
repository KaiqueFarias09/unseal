import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

void main() {
  group('detectFormat', () {
    test('detects EPUB zip containers', () {
      final bytes = File('test/resources/epub/sample1.epub').readAsBytesSync();
      expect(detectFormat(bytes), DetectedFormat.epub);
    });

    test('detects MOBI family', () {
      final bytes = File(
        'test/resources/mobi/alice-old.mobi',
      ).readAsBytesSync();
      expect(detectFormat(bytes), DetectedFormat.mobiFamily);
    });

    test('detects FB2 documents', () {
      final bytes = File('test/resources/fb2/alice.fb2').readAsBytesSync();
      expect(detectFormat(bytes), DetectedFormat.fb2);
    });

    test('detects FB2 with xml prologue', () {
      final bytes = Uint8List.fromList(
        '<?xml version="1.0"?><FictionBook></FictionBook>'.codeUnits,
      );
      expect(detectFormat(bytes), DetectedFormat.fb2);
    });

    test('rejects Topaz books', () {
      expect(
        () => detectFormat(Uint8List.fromList('TPZ'.codeUnits)),
        throwsA(isA<FormatNotSupportedException>()),
      );
    });

    test('rejects PDF books', () {
      expect(
        () => detectFormat(Uint8List.fromList('%PDF-1.7 ...'.codeUnits)),
        throwsA(isA<FormatNotSupportedException>()),
      );
    });

    test('rejects RTF books', () {
      expect(
        () => detectFormat(Uint8List.fromList(r'{\rtf1}'.codeUnits)),
        throwsA(isA<FormatNotSupportedException>()),
      );
    });

    test('rejects empty bytes', () {
      expect(
        () => detectFormat(Uint8List(0)),
        throwsA(isA<FormatNotSupportedException>()),
      );
    });

    test('refines mobi versus azw3', () {
      final old = File('test/resources/mobi/alice-old.mobi').readAsBytesSync();
      final kf8 = File('test/resources/mobi/alice-kf8.azw3').readAsBytesSync();
      expect(refineMobiFormat(old), BookFormat.mobi);
      expect(refineMobiFormat(kf8), BookFormat.azw3);
    });
  });

  group('sniffImageType', () {
    test('sniffs jpeg', () {
      expect(
        sniffImageType(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])),
        ImageType.jpeg,
      );
    });

    test('sniffs png', () {
      expect(
        sniffImageType(
          Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        ),
        ImageType.png,
      );
    });

    test('sniffs gif', () {
      expect(
        sniffImageType(Uint8List.fromList('GIF89a'.codeUnits)),
        ImageType.gif,
      );
    });

    test('sniffs bmp', () {
      expect(
        sniffImageType(Uint8List.fromList([0x42, 0x4D, 0x00, 0x01])),
        ImageType.bmp,
      );
    });

    test('sniffs webp', () {
      expect(
        sniffImageType(Uint8List.fromList('RIFF0000WEBP'.codeUnits)),
        ImageType.webp,
      );
    });

    test('returns null for non-image data', () {
      expect(
        sniffImageType(Uint8List.fromList([0x00, 0x01, 0x02, 0x03])),
        isNull,
      );
    });
  });
}
