import 'dart:io';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  group('Unseal.readFile', () {
    test('throws when path is empty', () async {
      const path = '';
      expect(Unseal.readFile(path), throwsA(isA<ArgumentError>()));
    });

    test('throws when file does not exist', () async {
      const path = '/path/to/nonexistent/file.epub';
      expect(Unseal.readFile(path), throwsA(isA<FileSystemException>()));
    });

    final directory = Directory('test/resources/epub');
    final files = directory.listSync();
    final books = files.where((final book) {
      return book.path.endsWith('.epub');
    }).toList();

    for (final book in books) {
      test('reads a book', () async {
        final bookEntity = await Unseal.readFile(book.path);
        expect(bookEntity, isA<EpubBook>());
      });
    }
  });

  group('archive inventory', () {
    // The physical zip view is manifest-independent: infrastructure
    // entries ship alongside the content files.
    test('lists every zip entry, including non-manifest ones', () async {
      final book = await Unseal.readFile(
        'test/resources/epub/Alices Adventures in Wonderland.epub',
      );
      final paths = book.archiveEntries.map((final entry) => entry.path).toSet();
      expect(paths, contains('mimetype'));
      expect(paths, anyElement(contains('META-INF/')));
      for (final entry in book.archiveEntries) {
        expect(entry.size, greaterThanOrEqualTo(0), reason: entry.path);
      }
    });

    test('keeps the manifest content inside the physical inventory', () async {
      final book = await Unseal.readFile(
        'test/resources/epub/Alices Adventures in Wonderland.epub',
      );
      final entries = book.archiveEntries.map((final entry) => entry.path).toSet();
      for (final file in book.files.html) {
        expect(entries, contains(file.path), reason: 'manifest item missing from the zip view');
      }
    });
  });

  group('NCX navigation', () {
    // Regression: `XmlElement.value` is always null in package:xml, so
    // NCX labels used to come out empty for every book.
    test('reads labels and title from a real calibre-generated NCX', () async {
      final book = await Unseal.readFile(
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
