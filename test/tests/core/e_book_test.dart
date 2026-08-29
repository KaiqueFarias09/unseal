import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

void main() {
  group('EBook dispatcher', () {
    test('opens an EPUB into an EpubBook', () async {
      final book = await EBook.openFromFile(
        File('test/resources/epub/sample1.epub'),
      );
      expect(book, isA<EpubBook>());
      expect(book.format, BookFormat.epub);
      expect(book.metadata.title, isNotEmpty);
      expect(book.metadata.cover, isNotNull);
    });

    test('opens a MOBI 6 book into a MobiBook', () async {
      final book = await EBook.openFromFile(
        File('test/resources/mobi/alice-old.mobi'),
      );
      expect(book, isA<MobiBook>());
      expect(book.format, BookFormat.mobi);
    });

    test('opens an AZW3 book into a MobiBook', () async {
      final book = await EBook.openFromFile(
        File('test/resources/mobi/alice-kf8.azw3'),
      );
      expect(book, isA<MobiBook>());
      expect(book.format, BookFormat.azw3);
    });

    test('opens an FB2 book into an Fb2Book', () async {
      final book = await EBook.openFromFile(
        File('test/resources/fb2/alice.fb2'),
      );
      expect(book, isA<Fb2Book>());
      expect(book.format, BookFormat.fb2);
    });

    test('reads metadata without a full parse', () async {
      final metadata = await EBook.readMetadataFromFile(
        File('test/resources/mobi/alice-kf8.azw3'),
      );
      expect(metadata.format, BookFormat.azw3);
      expect(metadata.title, "Alice's Adventures in Wonderland");
      expect(metadata.authors, ['Lewis Carroll']);
      expect(metadata.cover, isNotNull);
    });

    test('rejects empty bytes', () {
      expect(
        () => EBook.openFromBytes(Uint8List(0)),
        throwsA(isA<EmptyBytesException>()),
      );
    });

    test('rejects missing files', () {
      expect(
        () => EBook.openFromPath('test/resources/does-not-exist.mobi'),
        throwsA(isA<Exception>()),
      );
    });
  });
}
