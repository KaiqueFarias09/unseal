import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/unseal.dart';

void main() {
  group('SessionEngine header parity', () {
    final fixtures = [
      'test/resources/books/epub/elements-of-chemistry.epub',
      'test/resources/books/epub/accessible-epub-3.epub',
      'test/resources/books/epub/fxl-mixed-fixed-override.epub',
      'test/resources/books/epub/fxl-nonlinear.epub',
    ];

    for (final fixture in fixtures) {
      test('header structure equals the eager parse: $fixture', () async {
        final bytes = File(fixture).readAsBytesSync();
        final engine = await SessionEngine.openBytes(bytes);
        final full = Unseal.parse(bytes) as EpubBook;
        addTearDown(engine.close);

        final header = engine.book as EpubBook;

        expect(header.files.html, isEmpty, reason: 'header must hold no content');
        expect(header.spinePaths, full.spinePaths, reason: 'spine paths');
        expect(header.spineIdrefs, full.spineIdrefs, reason: 'spine idrefs');
        expect(header.metadata.title, full.metadata.title, reason: 'title');
        expect(
          header.metadata.authors.join(','),
          full.metadata.authors.join(','),
          reason: 'authors',
        );
        expect(
          header.navigation.navPoints.length,
          full.navigation.navPoints.length,
          reason: 'nav points',
        );
        expect(header.archiveEntries.length, full.archiveEntries.length, reason: 'inventory');
        expect(
          <String, int>{for (final e in header.archiveEntries) e.path: e.size},
          <String, int>{for (final e in full.archiveEntries) e.path: e.size},
          reason: 'inventory sizes',
        );
        expect(header.nonLinearSpinePaths, full.nonLinearSpinePaths, reason: 'non-linear spine');

        // Viewports: the session extracts pre-paginated documents only,
        // so its map is a subset of the eager map with equal values.
        for (final entry in header.contentViewports.entries) {
          expect(full.contentViewports[entry.key], entry.value, reason: 'viewport ${entry.key}');
        }
      });
    }
  });

  group('SessionEngine on-demand content', () {
    const fixture = 'test/resources/books/epub/elements-of-chemistry.epub';

    test('resource and document text bytes equal the eager parse', () async {
      final bytes = File(fixture).readAsBytesSync();
      final engine = await SessionEngine.openBytes(bytes);
      addTearDown(engine.close);
      final full = Unseal.parse(bytes) as EpubBook;

      for (final file in full.files.html) {
        expect(await engine.documentText(file.path), documentTextOf(file), reason: file.path);
      }
      for (final file in [...full.files.images, ...full.files.fonts, ...full.files.others]) {
        expect(await engine.resource(file.path), file.content, reason: file.path);
      }
      for (final file in full.files.css) {
        expect((await engine.textFile(file.path))!.content, file.content, reason: file.path);
      }
    });

    test('missing entries resolve to null', () async {
      final bytes = File(fixture).readAsBytesSync();
      final engine = await SessionEngine.openBytes(bytes);
      addTearDown(engine.close);

      expect(await engine.resource('does/not/exist.png'), isNull);
      expect(await engine.documentText('does/not/exist.xhtml'), isNull);
    });

    test('search results equal BookSearch on the full parse', () async {
      final bytes = File(fixture).readAsBytesSync();
      final engine = await SessionEngine.openBytes(bytes);
      addTearDown(engine.close);
      final full = Unseal.parse(bytes);

      final query = full.metadata.title?.split(' ').first ?? 'chemistry';
      final sessionResults = await engine.search(query, maxMatches: 500);
      final fullResults = full.search(query, maxMatches: 500);

      expect(sessionResults.matches.length, fullResults.matches.length, reason: 'match count');
      for (var i = 0; i < sessionResults.matches.length && i < fullResults.matches.length; i++) {
        expect(sessionResults.matches[i].sectionIndex, fullResults.matches[i].sectionIndex);
        expect(sessionResults.matches[i].start, fullResults.matches[i].start);
        expect(sessionResults.matches[i].end, fullResults.matches[i].end);
        expect(sessionResults.matches[i].snippet, fullResults.matches[i].snippet);
      }
    });

    test('progression equals the full parse progression', () async {
      final bytes = File(fixture).readAsBytesSync();
      final engine = await SessionEngine.openBytes(bytes);
      addTearDown(engine.close);
      final full = Unseal.parse(bytes);

      final sessionProgression = await engine.computeProgression();
      final fullProgression = BookProgression.of(full);

      expect(sessionProgression.sectionCount, fullProgression.sectionCount);
      expect(sessionProgression.totalCharacters, fullProgression.totalCharacters);
      expect(
        sessionProgression.fractionOf(sectionIndex: 1, charOffset: 10),
        fullProgression.fractionOf(sectionIndex: 1, charOffset: 10),
      );
    });

    test('CFI build and resolve round-trip through the session', () async {
      final bytes = File(fixture).readAsBytesSync();
      final engine = await SessionEngine.openBytes(bytes);
      addTearDown(engine.close);
      final full = Unseal.parse(bytes) as EpubBook;

      final sectionFile = full.files.html.first;
      final sectionIndex = full.spinePaths!.indexOf(sectionFile.path);
      final text = documentTextOf(sectionFile);
      final offset = text.length ~/ 2;
      final expected = full.buildEpubCfi(contentIndex: sectionIndex, offsetInText: offset);

      final built = await engine.buildCfi(contentIndex: sectionIndex, offsetInText: offset);
      expect(built, expected);

      final location = await engine.resolveCfi(built);
      expect(location, isNotNull);
      expect(location!.contentIndex, sectionIndex);
      expect(location.charOffset, offset);
    });

    test('statistics measure the whole book, not the loaded slice', () async {
      final bytes = File(fixture).readAsBytesSync();
      final engine = await SessionEngine.openBytes(bytes);
      addTearDown(engine.close);

      final stats = await engine.computeStatistics();
      expect(stats.wordCount, greaterThan(0));
    });
  });

  group('SessionEngine comic sessions', () {
    const fixture = 'test/resources/books/comic/halfpenny-surprise-1895.cbz';

    test('page inventory and cover match the eager parse', () async {
      final bytes = File(fixture).readAsBytesSync();
      final engine = await SessionEngine.openBytes(bytes);
      addTearDown(engine.close);
      final full = Unseal.parse(bytes) as ComicBook;
      final header = engine.book as ComicBook;

      expect(header.pageCount, full.pageCount);
      expect(
        [for (final page in header.pages) page.path],
        [for (final page in full.pages) page.path],
      );
      expect(header.readingDirection, full.readingDirection);
      expect(header.cover.isEmpty, isFalse);
      expect(header.cover.content, full.cover.content);
      for (final page in header.pages) {
        expect(page.content, isEmpty, reason: 'placeholder pages carry no bytes');
        final loaded = await engine.resource(page.path);
        expect(loaded, isNotNull);
      }
    });
  });

  group('SessionEngine cache policy', () {
    test('entries stay correct when the LRU evicts under a tiny budget', () async {
      final bytes = File('test/resources/books/epub/elements-of-chemistry.epub').readAsBytesSync();
      final full = Unseal.parse(bytes) as EpubBook;
      final engine = await SessionEngine.openBytes(
        bytes,
        policy: const SessionPolicy(cacheBytes: 1 << 20),
      );
      addTearDown(engine.close);

      // Load enough sections to overflow a 1 MiB budget several times;
      // every reload must still be exact.
      for (var pass = 0; pass < 2; pass++) {
        for (final file in full.files.html) {
          expect(await engine.documentText(file.path), documentTextOf(file), reason: file.path);
        }
      }
    });

    test('an oversized cover leaves the header cover empty but loadable', () async {
      final bytes = File(
        'test/resources/books/comic/halfpenny-surprise-1895.cbz',
      ).readAsBytesSync();
      final engine = await SessionEngine.openBytes(
        bytes,
        policy: const SessionPolicy(coverMaxBytes: 1024),
      );
      addTearDown(engine.close);
      final header = engine.book as ComicBook;
      final full = Unseal.parse(bytes) as ComicBook;

      expect(header.cover.isEmpty, isTrue);
      expect(await engine.resource(full.cover.path), isNotNull);
    });
  });

  group('SessionEngine lifecycle and guards', () {
    test('closed engines fail typed', () async {
      final bytes = File('test/resources/books/epub/elements-of-chemistry.epub').readAsBytesSync();
      final engine = await SessionEngine.openBytes(bytes);
      engine.close();

      expect(() => engine.resource('x'), throwsA(isA<SessionClosedException>()));
      expect(() => engine.search('x'), throwsA(isA<SessionClosedException>()));
      expect(engine.computeProgression, throwsA(isA<SessionClosedException>()));
      expect(() => engine.documentText('x'), throwsA(isA<SessionClosedException>()));
    });

    test('unsupported formats throw the typed session error', () async {
      final bytes = File('test/resources/books/txt/synthetic.txt').readAsBytesSync();

      expect(
        () => SessionEngine.openBytes(bytes),
        throwsA(isA<SessionUnsupportedFormatException>()),
      );
    });

    test('broken containers surface the parse failure hierarchy', () async {
      final bytes = Uint8List.fromList(<int>[0x50, 0x4b, 0x03, 0x04, 1, 2, 3]);

      expect(() => SessionEngine.openBytes(bytes), throwsA(isA<UnsealException>()));
    });
  });
}
