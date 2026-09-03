import 'dart:io';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

void main() {
  group('Reader', () {
    test('should throw exception when path is empty', () async {
      const path = '';
      expect(BookReader.openFromPath(path), throwsA(isA<ArgumentError>()));
    });

    test('should throw exception when file does not exist', () async {
      const path = '/path/to/nonexistent/file.epub';
      expect(BookReader.openFromPath(path), throwsA(isA<FileSystemException>()));
    });

    final directory = Directory('test/resources/epub');
    final files = directory.listSync();
    final books = files.where((final book) {
      return book.path.endsWith('.epub');
    }).toList();

    for (final book in books) {
      test('should succeed', () async {
        final bookEntity = await BookReader.openFromPath(book.path);
        expect(bookEntity, isA<EpubBook>());
      });
    }
  });

  group('NCX navigation', () {
    // Regression: `XmlElement.value` is always null in package:xml, so
    // NCX labels used to come out empty for every book.
    test('reads labels and title from a real calibre-generated NCX', () async {
      final book = await BookReader.openFromPath(
        'test/resources/epub/Alices Adventures in Wonderland.epub',
      );
      expect(book.navigation.title, isNotEmpty);
      expect(book.navigation.navPoints, isNotEmpty);
      for (final point in book.navigation.navPoints) {
        expect(point.label, isNotEmpty, reason: 'nav point ${point.id}');
      }
    });

    test('reads labels for every point of the tree, however nested', () {
      final book = parseEpubBook(
        File('test/resources/epub/Alices Adventures in Wonderland.epub').readAsBytesSync(),
      );

      void walk(final Iterable<NavPoint> points) {
        for (final point in points) {
          expect(point.label, isNotEmpty, reason: 'nav point ${point.id}');
          walk(point.subNavPoints);
        }
      }

      walk(book.navigation.navPoints);
    });
  });
}
