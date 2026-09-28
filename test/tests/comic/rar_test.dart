import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../../support/rar_fixtures.dart';

void main() {
  group('RAR 4 optional header fields', () {
    test('skips the 64-bit size fields (flag 0x0100)', () {
      final archive = buildRar4(['high.jpg'], flags: 0x8000 | 0x0100, withHighSizes: true);
      final book = parseComicBook(archive);

      expect(book.pages.single.name, 'high.jpg');
      expect(book.pages.single.content, tinyJpegPage);
    });

    test('skips the encryption salt (flag 0x0400)', () {
      final archive = buildRar4(['salt.jpg'], flags: 0x8000 | 0x0400, withSalt: true);
      final book = parseComicBook(archive);

      expect(book.pages.single.name, 'salt.jpg');
      expect(book.pages.single.content, tinyJpegPage);
    });

    test('decodes the real RAR 4 method-29 CBR pages', () {
      final bytes = File(
        'test/resources/books/comic/american-beauty-trading-cards-1909.cbr',
      ).readAsBytesSync();
      final pages = parseComicBook(bytes).pages;

      expect(pages, hasLength(24));
      expect(pages.every((final page) => sniffImageType(page.content) == ImageType.jpeg), isTrue);
    });

    test('stops when a file name runs past the buffer', () {
      final archive = buildRar4(['gone.jpg'], nameSizeOvershoot: 2);
      expect(() => parseComicBook(archive), throwsA(isA<ComicException>()));
    });
  });

  group('RAR 5', () {
    test('reads stored entries behind a main header', () {
      final archive = buildRar5(['002.jpg', '001.jpg']);
      final book = parseComicBook(archive);

      expect(book.pages.map((final page) => page.name).toList(), ['001.jpg', '002.jpg']);
      expect(book.pages.first.content, tinyJpegPage);
    });

    test('reads stored entries with an extra metadata area', () {
      final book = parseComicBook(buildRar5(['001.jpg', '002.jpg'], withExtraArea: true));

      expect(book.pages, hasLength(2));
      expect(book.pages.map((final page) => page.name).toList(), ['001.jpg', '002.jpg']);
      expect(book.pages.first.content, tinyJpegPage);
      expect(book.pages.last.content, tinyJpegPage);
    });

    test('reports compressed entries as not stored', () {
      expect(
        () => parseComicBook(buildRar5(['001.jpg'], method: 3)),
        throwsA(isA<ComicException>()),
      );
    });

    test('parses headers carrying mtime and data crc', () {
      final book = parseComicBook(buildRar5(['001.jpg'], fileFlags: 0x0006));

      expect(book.pages.single.name, '001.jpg');
      expect(book.pages.single.content, tinyJpegPage);
    });

    test('marks directory entries', () {
      expect(
        () => parseComicBook(buildRar5(['chapter1/'], fileFlags: 0x0001)),
        throwsA(isA<ComicException>()),
      );
    });

    test('stops at the end-of-archive block', () {
      final book = parseComicBook(buildRar5(['001.jpg'], trailingGarbage: true));

      expect(book.pages, hasLength(1));
    });

    test('rejects non-RAR and truncated buffers', () {
      expect(() => parseComicBook(Uint8List(4)), throwsA(isA<ComicException>()));
      expect(
        () => parseComicBook(Uint8List.fromList('NOTARAR!'.codeUnits)),
        throwsA(isA<ComicException>()),
      );
    });
  });

  group('CBR through the comic parser', () {
    test('RAR 5 comics parse into pages', () {
      final book = parseComicBook(buildRar5(['002.jpg', '001.jpg']));
      expect(book.format, BookFormat.cbr);
      expect(book.pageCount, 2);
      expect(book.pages.first.name, '001.jpg');
      expect(detectFormat(buildRar5(['001.jpg'])), DetectedFormat.comic);
    });

    test('RAR 5 comics with an extra metadata area parse into pages', () {
      final book = parseComicBook(buildRar5(['001.jpg'], withExtraArea: true));

      expect(book.format, BookFormat.cbr);
      expect(book.pageCount, 1);
      expect(book.pages.single.name, '001.jpg');
    });

    test('RAR 5 comics with compressed pages throw', () {
      expect(
        () => parseComicBook(buildRar5(['001.jpg'], method: 3)),
        throwsA(isA<ComicException>()),
      );
    });
  });
}
