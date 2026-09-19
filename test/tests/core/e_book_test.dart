import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  group('Unseal dispatcher', () {
    test('opens an EPUB into an EpubBook', () async {
      final book = await Unseal.readFile(
        'test/resources/books/epub/vertical-writing-ja.epub',
      );
      expect(book, isA<EpubBook>());
      expect(book.format, BookFormat.epub);
      expect(book.metadata.title, isNotEmpty);
      expect(book.metadata.cover, isNotNull);
    });

    test('opens a MOBI 6 book into a MobiBook', () async {
      final book = await Unseal.readFile('test/resources/books/mobi/alice-old-pg.mobi');
      expect(book, isA<MobiBook>());
      expect(book.format, BookFormat.mobi);
    });

    test('opens an AZW3 book into a MobiBook', () async {
      final book = await Unseal.readFile('test/resources/books/mobi/alice-kf8-pg.azw3');
      expect(book, isA<MobiBook>());
      expect(book.format, BookFormat.azw3);
    });

    test('opens an FB2 book into an Fb2Book', () async {
      final book = await Unseal.readFile(
        'test/resources/books/fb2/synthetic-multilingual.fb2',
      );
      expect(book, isA<Fb2Book>());
      expect(book.format, BookFormat.fb2);
    });

    test('reads metadata without a full parse', () async {
      final metadata = await Unseal.readMetadataFile('test/resources/mobi/alice-kf8.azw3');
      expect(metadata.format, BookFormat.azw3);
      expect(metadata.title, "Alice's Adventures in Wonderland");
      expect(metadata.authors, ['Lewis Carroll']);
      expect(metadata.cover, isNotNull);
    });

    test('opens a CBZ comic into a ComicBook', () async {
      final book = await Unseal.readFile('test/resources/books/comic/synthetic-pages.cbz');
      expect(book, isA<ComicBook>());
      expect(book.format, BookFormat.cbz);
      expect((book as ComicBook).pageCount, greaterThan(0));
    });

    test('opens a CBR comic into a ComicBook', () async {
      final book = await Unseal.readFile(
        'test/resources/books/comic/synthetic-stored-pages.cbr',
      );
      expect(book, isA<ComicBook>());
      expect(book.format, BookFormat.cbr);
      expect((book as ComicBook).pageCount, 2);
    });

    test('opens a PDF into a reflowable PdfBook', () async {
      final book = await Unseal.readFile('test/resources/books/pdf/dickens-sample.pdf');
      expect(book, isA<PdfBook>());
      expect(book.format, BookFormat.pdf);
      expect((book as PdfBook).hasTextLayer, isTrue);
    });

    test('reads comic metadata without pages', () async {
      final metadata = await Unseal.readMetadataFile('test/resources/comic/sample.cbz');
      expect(metadata.format, BookFormat.cbz);
      expect(metadata.title, 'Fixture Comic');
    });

    test('rejects empty bytes', () {
      expect(() => Unseal.read(Uint8List(0)), throwsA(isA<EmptyBytesException>()));
    });

    test('rejects missing files', () {
      expect(
        () => Unseal.readFile('test/resources/does-not-exist.mobi'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
