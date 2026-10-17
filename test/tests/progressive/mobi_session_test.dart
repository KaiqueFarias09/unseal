import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

Uint8List _fixture(final String name) {
  final file = File('test/resources/books/mobi/$name');

  return file.readAsBytesSync();
}

void main() {
  group('MOBI 6 session', () {
    test('opens with complete structure and an empty file set', () async {
      final bytes = _fixture('alice-old-pg.mobi');
      final session = await BookSession.open(bytes);
      try {
        final book = session.book as MobiBook;
        expect(book.format, BookFormat.mobi);
        expect(book.files.html, isEmpty);
        expect(book.readingOrderPaths, isNotNull);
        expect(book.readingOrderPaths, isNotEmpty);
        expect(book.metadata.title, contains('Alice'));

        final eager = Unseal.parse(bytes) as MobiBook;
        expect(
          book.navigation.navPoints.length,
          eager.navigation.navPoints.length,
          reason: 'the byte-level open pass must derive the same navigation',
        );
      } finally {
        session.dispose();
      }
    });

    test('section texts concatenate to the eager document text', () async {
      final bytes = _fixture('alice-old-pg.mobi');
      final eager = Unseal.parse(bytes) as MobiBook;
      final eagerText = eager.files.html
          .map(documentTextOf)
          .join();

      final session = await BookSession.open(bytes);
      try {
        final buffer = StringBuffer();
        for (final item in session.book.readingOrder) {
          final text = await session.loadDocumentText(item.name);
          expect(text, isNotNull, reason: '${item.name} must materialize');
          buffer.write(text);
        }

        expect(buffer.toString(), eagerText);
      } finally {
        session.dispose();
      }
    });

    test('navigation labels match eager and targets resolve', () async {
      final bytes = _fixture('alice-old-pg.mobi');
      final eager = Unseal.parse(bytes) as MobiBook;
      final session = await BookSession.open(bytes);
      try {
        final labels = <String>[];
        void collect(final List<NavPoint> points) {
          for (final point in points) {
            labels.add(point.label);
            collect(point.subNavPoints);
          }
        }

        collect((session.book as MobiBook).navigation.navPoints);
        expect(labels, eager.navigation.navPoints.map((final p) => p.label).toList());
      } finally {
        session.dispose();
      }
    });

    test('resources load on demand with eager hashes', () async {
      final bytes = _fixture('alice-old-pg.mobi');
      final eager = Unseal.parse(bytes) as MobiBook;
      final session = await BookSession.open(bytes);
      try {
        final eagerHashes = <String>[];
        for (final image in eager.files.images) {
          eagerHashes.add(image.path);
          final loaded = await session.loadResource(image.path);
          expect(loaded, isNotNull, reason: '${image.path} must load');
          expect(loaded!.length, image.content.length, reason: image.path);
        }
        expect(eagerHashes, isNotEmpty);
      } finally {
        session.dispose();
      }
    });
  });

  group('KF8 (AZW3) session', () {
    test('opens with the part reading order', () async {
      final bytes = _fixture('alice-kf8-pg.azw3');
      final session = await BookSession.open(bytes);
      try {
        final book = session.book as MobiBook;
        expect(book.format, BookFormat.azw3);
        final eager = Unseal.parse(bytes) as MobiBook;
        expect(book.readingOrderPaths, hasLength(eager.files.html.length));
      } finally {
        session.dispose();
      }
    });

    test('part texts equal the eager part texts', () async {
      final bytes = _fixture('alice-kf8-pg.azw3');
      final eager = Unseal.parse(bytes) as MobiBook;
      final eagerByName = <String, String>{
        for (final file in eager.files.html) file.path: documentTextOf(file),
      };

      final session = await BookSession.open(bytes);
      try {
        for (final item in session.book.readingOrder) {
          final text = await session.loadDocumentText(item.name);
          expect(text, isNotNull, reason: '${item.name} must materialize');
          expect(text, eagerByName[item.name], reason: item.name);
        }
      } finally {
        session.dispose();
      }
    });

    test('navigation resolves through rebuilt parts', () async {
      final bytes = _fixture('alice-kf8-pg.azw3');
      final eager = Unseal.parse(bytes) as MobiBook;
      final session = await BookSession.open(bytes);
      try {
        final sessionNav = (session.book as MobiBook).navigation;
        final eagerNav = eager.navigation;
        String labelsOf(final Navigation nav) => nav.navPoints
            .map((final p) => p.label)
            .join('|');
        expect(labelsOf(sessionNav), labelsOf(eagerNav));
        expect(sessionNav.navPoints, isNotEmpty);
      } finally {
        session.dispose();
      }
    });
  });
}
