import 'dart:io';

import 'package:archive/archive.dart';
import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

void main() {
  group('readEpubMetadata fast path', () {
    final files = Directory(
      'test/resources/epub',
    ).listSync().whereType<File>().where((final file) => file.path.endsWith('.epub')).toList();

    for (final file in files) {
      test('reads metadata of ${file.uri.pathSegments.last}', () {
        final archive = ZipDecoder().decodeBytes(File(file.path).readAsBytesSync());
        final metadata = readEpubMetadata(archive);

        expect(metadata.format, BookFormat.epub);
        expect(metadata.title, isNotEmpty);
        expect(metadata.languages, isNotEmpty);
      });
    }

    test('carries the cover bytes for sample1', () {
      final archive = ZipDecoder().decodeBytes(
        File('test/resources/epub/sample1.epub').readAsBytesSync(),
      );
      final metadata = readEpubMetadata(archive);
      expect(metadata.cover, isNotNull);
      expect(metadata.cover!.bytes.length, greaterThan(1000));
    });
  });

  group('cover precedence', () {
    test('every fixture resolves a cover or degrades gracefully', () {
      final files = Directory(
        'test/resources/epub',
      ).listSync().whereType<File>().where((final file) => file.path.endsWith('.epub'));

      for (final file in files) {
        final book = parseEpubBook(File(file.path).readAsBytesSync());
        if (!book.cover.isEmpty) {
          expect(
            sniffImageType(book.cover.content),
            isNotNull,
            reason: 'cover of ${file.path} is not a valid image',
          );
        }
      }
    });
  });
}
