import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

const String aliceTitle = "Alice's Adventures in Wonderland";

void main() {
  group('MOBI 6 (alice-old.mobi)', () {
    final book = parseMobiBook(_read('test/resources/mobi/alice-old.mobi'));

    test('parses metadata', () {
      expect(book.format, BookFormat.mobi);
      expect(book.title, aliceTitle);
      expect(book.metadata.authors, ['Lewis Carroll']);
      expect(book.metadata.languages, isNotEmpty);
      expect(book.metadata.languages.first, startsWith('en'));
    });

    test('extracts a cover image', () {
      expect(book.cover.isEmpty, isFalse);
      expect(sniffImageType(book.cover.content), isNotNull);
      expect(book.metadata.cover, isNotNull);
      expect(book.metadata.cover!.mimeType, startsWith('image/'));
    });

    test('extracts the html content', () {
      expect(book.files.html, hasLength(1));
      final html = book.files.html.first.content;
      expect(html, contains('Alice'));
      expect(html, contains('src="image'));
      // Internal filepos links are converted to anchors.
      expect(html, contains('href="#filepos'));
    });

    test('extracts images', () {
      expect(book.files.images.length, greaterThan(10));
      for (final image in book.files.images) {
        expect(sniffImageType(image.content), isNotNull, reason: image.name);
      }
    });

    test('splits chapters at the toc anchors', () {
      final chapters = book.chapters;
      // Front matter + one chapter per toc entry.
      expect(chapters.length, greaterThan(9));
      expect(chapters.first.title, aliceTitle);
      final first = chapters[1];
      expect(first.title, contains('Rabbit-Hole'));
      expect(first.file.content, contains('Alice'));
      // Chapters reassemble into the full content.
      final total = chapters.fold<int>(
        0,
        (final sum, final chapter) => sum + chapter.file.content.length,
      );
      expect(total, lessThanOrEqualTo(book.files.html.first.content.length));
    });

    test('derives navigation from filepos anchors', () {
      expect(book.navigation.navPoints.length, greaterThanOrEqualTo(8));
      for (final point in book.navigation.navPoints) {
        expect(point.content, startsWith('#filepos'));
        expect(point.label, isNotEmpty);
      }
    });
  });

  group('AZW3 standalone (alice-kf8.azw3)', () {
    final book = parseMobiBook(_read('test/resources/mobi/alice-kf8.azw3'));

    test('parses metadata', () {
      expect(book.format, BookFormat.azw3);
      expect(book.title, aliceTitle);
      expect(book.metadata.authors, ['Lewis Carroll']);
    });

    test('rebuilds the xhtml files', () {
      // index.html + one part per chapter.
      expect(book.files.html.length, greaterThanOrEqualTo(10));
      expect(book.files.html.first.name, 'index.html');
      final chapter = book.files.html.firstWhere((final file) => file.name == 'part0001.html');
      expect(chapter.content, contains('Rabbit-Hole'));
    });

    test('extracts css, fonts and images', () {
      expect(book.files.css, isNotEmpty);
      expect(book.files.fonts.length, greaterThanOrEqualTo(1));
      expect(book.files.images.length, greaterThan(10));
    });

    test('resolves every kindle reference', () {
      for (final file in book.files.html) {
        expect(
          file.content.contains('kindle:'),
          isFalse,
          reason: 'unresolved reference in ${file.name}',
        );
      }
      // Links point to rebuilt part files.
      final links = book.files.html
          .expand((final file) => RegExp('href="part[^"]*"').allMatches(file.content))
          .length;
      expect(links, greaterThan(0));
    });

    test('builds navigation from the NCX index', () {
      expect(book.navigation.navPoints.length, greaterThanOrEqualTo(8));
      final first = book.navigation.navPoints.first;
      expect(first.content, startsWith('part'));
      expect(first.label, contains('Rabbit-Hole'));
    });

    test('extracts a cover image', () {
      expect(book.cover.isEmpty, isFalse);
      expect(sniffImageType(book.cover.content), isNotNull);
    });
  });

  group('AZW3 joint (alice-joint.mobi)', () {
    final book = parseMobiBook(_read('test/resources/mobi/alice-joint.mobi'));

    test('detects and parses the KF8 half', () {
      expect(book.format, BookFormat.azw3);
      expect(book.title, aliceTitle);
      expect(book.files.html.length, greaterThanOrEqualTo(10));
      expect(book.files.css, isNotEmpty);
    });

    test('resolves every kindle reference', () {
      for (final file in book.files.html) {
        expect(
          file.content.contains('kindle:'),
          isFalse,
          reason: 'unresolved reference in ${file.name}',
        );
      }
    });
  });

  group('readMobiMetadata fast path', () {
    test('reads metadata without extracting content', () {
      final metadata = readMobiMetadata(_read('test/resources/mobi/alice-old.mobi'));
      expect(metadata.title, aliceTitle);
      expect(metadata.authors, ['Lewis Carroll']);
      expect(metadata.cover, isNotNull);
      expect(metadata.cover!.bytes.length, greaterThan(1000));
    });

    test('reads AZW3 metadata', () {
      final metadata = readMobiMetadata(_read('test/resources/mobi/alice-kf8.azw3'));
      expect(metadata.format, BookFormat.azw3);
      expect(metadata.title, aliceTitle);
      expect(metadata.cover, isNotNull);
    });
  });
}

Uint8List _read(final String path) => Uint8List.fromList(File(path).readAsBytesSync());
