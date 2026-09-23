import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/chm.dart';
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
  });
}
