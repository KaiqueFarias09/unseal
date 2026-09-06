import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

void main() {
  final manifestFile = File('test/resources/books/manifest.json');
  final manifest = jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
  final books = (manifest['books']! as List<Object?>).cast<Map<String, Object?>>();
  final formatFixtures = (manifest['format_fixtures']! as List<Object?>)
      .cast<Map<String, Object?>>();
  final realWorldFixtures = (manifest['real_world_fixtures']! as List<Object?>)
      .cast<Map<String, Object?>>();

  group('multilingual and edge-case book corpus', () {
    test('manifest has unique IDs and files', () {
      expect(manifest['schema_version'], 3);
      expect(books, hasLength(15));
      expect(formatFixtures, hasLength(BookFormat.values.length - 1));
      expect(realWorldFixtures, hasLength(4));
      final fixtures = [...books, ...formatFixtures, ...realWorldFixtures];
      expect(fixtures.map((final book) => book['id']).toSet(), hasLength(fixtures.length));
      expect(fixtures.map((final book) => book['file']).toSet(), hasLength(fixtures.length));
      for (final fixture in fixtures) {
        expect(fixture['license'], isA<String>(), reason: '${fixture['id']} has no license');
        final licenseFile = fixture['license_file'] as String?;
        final licenseUrl = fixture['license_url'] as String?;
        expect(
          licenseUrl != null ||
              (licenseFile != null && File('test/resources/books/$licenseFile').existsSync()),
          isTrue,
          reason: '${fixture['id']} has no usable license evidence',
        );
      }
      for (final fixture in realWorldFixtures) {
        expect(Uri.parse(fixture['source_page_url']! as String).isScheme('https'), isTrue);
        expect(Uri.parse(fixture['download_url']! as String).isScheme('https'), isTrue);
      }
    });

    test('known redistribution-restricted books are absent', () {
      const forbiddenTitles = <String>{
        "The Geography of Bliss: One Grump's Search for the Happiest Places in the World",
        'Famous Paintings',
        'Sway',
        'World Cultures and Geography',
      };
      final epubFiles = Directory('test/resources')
          .listSync(recursive: true)
          .whereType<File>()
          .where((final file) => file.path.endsWith('.epub'));

      for (final file in epubFiles) {
        final metadata = BookReader.readMetadataSync(file.readAsBytesSync());
        expect(
          forbiddenTitles.contains(metadata.title),
          isFalse,
          reason: '${file.path} contains the restricted title ${metadata.title}',
        );
      }
    });

    for (final fixture in books) {
      final id = fixture['id']! as String;
      final relativePath = fixture['file']! as String;
      final expectedBytes = fixture['bytes']! as int;
      final expectedLanguage = (fixture['language']! as String).toLowerCase();
      final file = File('test/resources/books/$relativePath');

      test('$id opens with its declared language and reading order', () async {
        expect(file.existsSync(), isTrue, reason: relativePath);
        expect(file.lengthSync(), expectedBytes, reason: relativePath);
        expect(sha256.convert(file.readAsBytesSync()).toString(), fixture['sha256']);

        final book = await BookReader.openFromPath(file.path);

        expect(book, isA<EpubBook>());
        expect(book.metadata.title, isNotEmpty);
        expect(
          book.metadata.languages.map((final language) => language.toLowerCase()),
          contains(expectedLanguage),
        );
        expect(book.readingOrder, isNotEmpty);
      });
    }

    test('format fixtures cover every supported book format', () {
      final covered = <BookFormat>{BookFormat.epub, ...formatFixtures.map(_declaredFormat)};
      expect(covered, BookFormat.values.toSet());
    });

    for (final fixture in formatFixtures) {
      final id = fixture['id']! as String;
      final relativePath = fixture['file']! as String;
      final expectedBytes = fixture['bytes']! as int;
      final expectedTitle = fixture['title'] as String?;
      final expectedLanguage = fixture['language'] as String?;
      final expectedFormat = _declaredFormat(fixture);
      final file = File('test/resources/books/$relativePath');

      test('$id opens through the public dispatcher', () async {
        expect(file.existsSync(), isTrue, reason: relativePath);
        expect(file.lengthSync(), expectedBytes, reason: relativePath);
        expect(sha256.convert(file.readAsBytesSync()).toString(), fixture['sha256']);

        final book = await BookReader.openFromPath(file.path);

        expect(book.format, expectedFormat);
        expect(book.readingOrder, isNotEmpty);
        if (expectedTitle != null) expect(book.metadata.title, expectedTitle);
        if (expectedLanguage != null) {
          expect(
            book.metadata.languages.map((final language) => language.toLowerCase()),
            contains(expectedLanguage.toLowerCase()),
          );
        }
      });
    }

    for (final fixture in realWorldFixtures) {
      final id = fixture['id']! as String;
      final relativePath = fixture['file']! as String;
      final expectedBytes = fixture['bytes']! as int;
      final expectedTitle = fixture['title'] as String?;
      final expectedLanguage = fixture['language'] as String?;
      final expectedFormat = _declaredFormat(fixture);
      final expectedError = fixture['expected_error_contains'] as String?;
      final minimumReadingOrderItems = fixture['minimum_reading_order_items'] as int?;
      final file = File('test/resources/books/$relativePath');

      test('$id opens through the public dispatcher', () async {
        expect(file.existsSync(), isTrue, reason: relativePath);
        expect(file.lengthSync(), expectedBytes, reason: relativePath);
        expect(sha256.convert(file.readAsBytesSync()).toString(), fixture['sha256']);

        if (expectedError != null) {
          await expectLater(
            BookReader.openFromPath(file.path),
            throwsA(
              isA<ComicException>().having(
                (final error) => error.toString(),
                'message',
                contains(expectedError),
              ),
            ),
          );
          return;
        }

        final book = await BookReader.openFromPath(file.path);

        expect(book.format, expectedFormat);
        expect(book.readingOrder.length, greaterThanOrEqualTo(minimumReadingOrderItems!));
        if (expectedFormat == BookFormat.cbr) {
          final comicBook = book as ComicBook;
          expect(comicBook.pages.every((final page) => page.content.isNotEmpty), isTrue);
        }
        if (expectedTitle != null) expect(book.metadata.title, expectedTitle);
        if (expectedLanguage != null) {
          expect(
            book.metadata.languages.map((final language) => language.toLowerCase()),
            contains(expectedLanguage.toLowerCase()),
          );
        }
      });
    }
  });
}

BookFormat _declaredFormat(final Map<String, Object?> fixture) => switch (fixture['format']) {
  'mobi' => BookFormat.mobi,
  'azw3' => BookFormat.azw3,
  'fb2' => BookFormat.fb2,
  'cbz' => BookFormat.cbz,
  'cbr' => BookFormat.cbr,
  'pdf' => BookFormat.pdf,
  final value => throw FormatException('Unknown fixture format: $value'),
};
