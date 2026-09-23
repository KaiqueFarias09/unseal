import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/chm.dart';
import 'package:unseal/src/features/chm/chm_archive.dart';
import 'package:unseal/src/features/chm/chm_lzx.dart';
import 'package:unseal/unseal.dart' show DetectedFormat, InvalidBookException, Unseal, detectFormat;

import 'chm_fixture_builder.dart';

void main() {
  group('CHM', () {
    test('detects, reads metadata and keeps HTML, CSS and nested contents', () {
      final bytes = chmFixture();
      expect(detectFormat(bytes), DetectedFormat.chm);
      final metadata = readChmMetadata(bytes);
      expect(metadata.title, 'Small CHM');
      final book = Unseal.parse(bytes) as DocumentBook;
      expect(book.format, BookFormat.chm);
      expect(book.files.html.map((final file) => file.path), ['index.html', 'chapter.html']);
      expect(book.files.css.single.content, contains('navy'));
      expect(book.navigation.navPoints.single.label, 'Start');
      expect(book.navigation.navPoints.single.subNavPoints.single.label, 'Next');
      expect(book.navigation.navPoints.single.subNavPoints.single.content, 'chapter.html#section');
      expect(book.readingOrder.map((final item) => item.name), ['index.html', 'chapter.html']);
    });

    test('opens a real LZX-compressed PuTTY manual', () {
      final bytes = File('test/resources/books/chm/putty.chm').readAsBytesSync();
      final book = parseChmBook(bytes);
      expect(book.metadata.title, 'PuTTY User Manual');
      expect(book.files.html.length, 454);
      expect(book.files.html.first.content, contains('PuTTY'));
      expect(book.files.css.single.content, contains('font'));
      expect(book.navigation.navPoints, isNotEmpty);
      expect(book.navigation.navPoints.first.label, 'PuTTY User Manual');
      expect(book.navigation.navPoints.first.content, 'index.html');
      expect(book.archiveEntries.length, 474);
    });

    test('decodes legacy Windows-1251, Windows-1252, and Windows-1256 codepages', () {
      final cyrillic =
          Unseal.parse(File('test/resources/books/chm/legacy-cp1251.chm').readAsBytesSync())
              as DocumentBook;
      expect(cyrillic.metadata.title, 'Русский CHM');
      expect(cyrillic.files.html.single.path, 'chapter-глава.html');
      expect(cyrillic.files.html.single.content, contains('Привет мир'));
      expect(cyrillic.navigation.navPoints.single.label, 'Главная');

      final western = parseChmBook(
        File('test/resources/books/chm/legacy-cp1252.chm').readAsBytesSync(),
      );
      expect(western.metadata.title, 'Café CHM');
      expect(western.files.html.single.path, 'chapter-café.html');
      expect(western.files.html.single.content, contains('Très bien café'));
      expect(western.navigation.navPoints.single.label, 'Été');

      final arabic = parseChmBook(
        File('test/resources/books/chm/legacy-cp1256.chm').readAsBytesSync(),
      );
      expect(arabic.metadata.title, 'دليل CHM');
      expect(arabic.files.html.single.path, 'chapter-سلام.html');
      expect(arabic.files.html.single.content, contains('سلام عليكم'));
      expect(arabic.navigation.navPoints.single.label, 'الرئيسية');
    });

    test('reuses decoded LZX frames for entries in the same reset interval', () {
      final archive = ChmArchive(File('test/resources/books/chm/putty.chm').readAsBytesSync());
      final entry = archive.entries.values.lastWhere(
        (final item) => item.section == 1 && item.length > 0,
      );
      final first = archive.read(entry);
      final expandedAfterFirstRead = archive.decodedLzxFrames;
      expect(expandedAfterFirstRead, greaterThan(0));
      expect(archive.read(entry), first);
      expect(archive.decodedLzxFrames, expandedAfterFirstRead);
    });

    test('rejects damaged headers, offsets and expansion claims with typed errors', () {
      final short = Uint8List.fromList('ITSF'.codeUnits);
      expect(() => parseChmBook(short), throwsA(isA<InvalidBookException>()));

      final badDirectory = chmFixture();
      badDirectory[0x48] = 0xff;
      expect(() => parseChmBook(badDirectory), throwsA(isA<InvalidBookException>()));

      final oversized = chmFixture();
      // PMGL claims that all its bytes are free, leaving no room for its
      // required header or entries.
      final view = ByteData.sublistView(oversized);
      view.setUint32(96 + 84 + 4, 4096, Endian.little);
      expect(() => parseChmBook(oversized), throwsA(isA<InvalidBookException>()));
    });

    test('decodes an LZX uncompressed block', () {
      const text = 'LZX raw block';
      expect(ChmLzxDecoder(15).decodeFrame(lzxRawFrame(text), text.length), text.codeUnits);
    });

    test('reverses Intel E8 addresses from the first LZX frame', () {
      final transformed = Uint8List(64);
      transformed[8] = 0xe8;
      ByteData.sublistView(transformed).setInt32(9, 108, Endian.little);

      final decoded = ChmLzxDecoder(
        15,
      ).decodeFrame(lzxRawFrameBytes(transformed, intelFileSize: 4096), transformed.length);

      expect(decoded[8], 0xe8);
      expect(ByteData.sublistView(decoded).getInt32(9, Endian.little), 100);
    });

    test('keeps the E8 position across frames and reverses negative transformed offsets', () {
      final decoder = ChmLzxDecoder(15);
      decoder.decodeFrame(lzxRawFrameBytes(List<int>.filled(1024, 0), intelFileSize: 1000), 1024);

      final transformed = Uint8List(64);
      transformed[8] = 0xe8;
      ByteData.sublistView(transformed).setInt32(9, -950, Endian.little);
      final decoded = decoder.decodeFrame(
        lzxRawFrameBytes(transformed, includeIntelHeader: false),
        transformed.length,
      );

      expect(ByteData.sublistView(decoded).getInt32(9, Endian.little), 50);
    });
  });
}
