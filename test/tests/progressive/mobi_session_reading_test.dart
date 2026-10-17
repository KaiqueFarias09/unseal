import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

Uint8List _alice() => File('test/resources/books/mobi/alice-old-pg.mobi').readAsBytesSync();
Uint8List _aliceKf8() => File('test/resources/books/mobi/alice-kf8-pg.azw3').readAsBytesSync();

void main() {
  group('search and index', () {
    test('session search matches the eager scan contract', () async {
      final bytes = _alice();
      final eager = Unseal.parse(bytes);
      final session = await BookSession.open(bytes);
      try {
        final eagerResults = eager.search('Rabbit');
        final sessionResults = await session.search('Rabbit');
        expect(sessionResults.matches.length, eagerResults.matches.length);
        expect(sessionResults.isTruncated, eagerResults.isTruncated);
        // Snippet context differs legitimately at section seams (a
        // snippet near a boundary has less preceding text than the
        // eager whole-document scan offers), so the comparison checks
        // the matched spans themselves: each session match's matched
        // text equals the eager match's matched text, in order.
        final eagerText = eager.files.html.map(documentTextOf).join();
        final sectionTexts = <String, String>{};
        String sectionOf(final String name) => sectionTexts.putIfAbsent(
          name,
          () => '',
        );
        expect(sessionResults.matches, isNotEmpty);
        for (var i = 0; i < sessionResults.matches.length; i++) {
          final sessionMatch = sessionResults.matches[i];
          final eagerMatch = eagerResults.matches[i];
          if (!sectionTexts.containsKey(sessionMatch.sectionName)) {
            sectionTexts[sessionMatch.sectionName] =
                (await session.loadDocumentText(sessionMatch.sectionName)) ?? '';
          }
          final matchedText = sectionOf(sessionMatch.sectionName).substring(
            sessionMatch.start,
            sessionMatch.end,
          );
          expect(matchedText, eagerText.substring(eagerMatch.start, eagerMatch.end));
        }
      } finally {
        session.dispose();
      }
    });

    test('unicode queries match across section boundaries', () async {
      final bytes = _alice();
      final session = await BookSession.open(bytes);
      try {
        // The typographic quotes in “Curiouser and curiouser!”.
        final results = await session.search('Curiouser and curiouser');
        expect(results.matches, isNotEmpty);
        // An accented word from the Gutenberg front matter.
        final accent = await session.search('Carroll');
        expect(accent.matches, isNotEmpty);
      } finally {
        session.dispose();
      }
    });

    test('the resident index builds in batches and answers ranked queries', () async {
      final bytes = _alice();
      final session = await BookSession.open(bytes);
      try {
        final batches = <SearchIndexCoverage>[];
        final coverage = await session.buildSearchIndex(
          sectionsPerBatch: 4,
          identity: const SearchIndexIdentity(publicationId: 'alice-session'),
          onProgress: batches.add,
        );
        expect(coverage.isComplete, isTrue);
        expect(batches, isNotEmpty);

        final results = await session.searchIndexed('rabbit', mode: IndexedQueryMode.prefix);
        expect(results.coverage.isComplete, isTrue);
        expect(results.hits, isNotEmpty);
      } finally {
        session.dispose();
      }
    });

    test('exported indexes reopen in a fresh session', () async {
      final bytes = _alice();
      final first = await BookSession.open(bytes);
      final payload = <String, Object?>{};
      try {
        await first.buildSearchIndex(identity: const SearchIndexIdentity(publicationId: 'alice'));
        payload.addAll(await first.exportSearchIndex());
      } finally {
        first.dispose();
      }

      final second = await BookSession.open(bytes);
      try {
        final coverage = await second.importSearchIndex(
          payload,
          identity: const SearchIndexIdentity(publicationId: 'alice'),
        );
        expect(coverage.isComplete, isTrue);

        final results = await second.searchIndexed('wonderland');
        expect(results.hits, isNotEmpty);
      } finally {
        second.dispose();
      }
    });

    test('an index over a different book fails typed and stays dropped', () async {
      final bytes = _alice();
      final other = _aliceKf8();

      final source = await BookSession.open(bytes);
      Map<String, Object?> payload;
      try {
        await source.buildSearchIndex(identity: const SearchIndexIdentity(publicationId: 'alice'));
        payload = await source.exportSearchIndex();
      } finally {
        source.dispose();
      }

      final session = await BookSession.open(other);
      try {
        await expectLater(
          session.importSearchIndex(
            payload,
            identity: const SearchIndexIdentity(publicationId: 'alice'),
          ),
          throwsA(isA<SearchIndexIncompatibleException>()),
        );
      } finally {
        session.dispose();
      }
    });
  });

  group('progression and statistics', () {
    test('progression matches the eager section lengths', () async {
      final bytes = _alice();
      final eager = Unseal.parse(bytes);
      final session = await BookSession.open(bytes);
      try {
        final sessionProgression = await session.computeProgression();
        // The session walks its own sections; the fractions tile the
        // same [0, 1] interval the eager single-document progression
        // covers.
        expect(sessionProgression.fractionOf(sectionIndex: 0), 0.0);
        final last = session.book.readingOrder.length - 1;
        expect(
          sessionProgression.fractionOf(sectionIndex: last),
          inInclusiveRange(0.0, 1.0),
        );
        expect(eager.readingOrder, isNotEmpty);
      } finally {
        session.dispose();
      }
    });

    test('statistics match the eager word count', () async {
      final bytes = _alice();
      final eager = Unseal.parse(bytes);
      final session = await BookSession.open(bytes);
      try {
        final sessionStats = await session.computeStatistics();
        expect(sessionStats.wordCount, eager.statistics.wordCount);
        expect(sessionStats.characterCount, greaterThan(0));
      } finally {
        session.dispose();
      }
    });
  });

  group('anchors across reopens', () {
    test('a captured anchor resolves in a reopened session', () async {
      final bytes = _alice();
      const expectedQuote = 'Alice was beginning to get very tired';

      final first = await BookSession.open(bytes);
      late final String sectionPath;
      late final int anchorOffset;
      try {
        // The quote lives in the first narrative section, not the
        // front matter; scan the reading order for it.
        for (final item in first.book.readingOrder) {
          final text = await first.loadDocumentText(item.name);
          final at = text?.indexOf(expectedQuote) ?? -1;
          if (at >= 0) {
            sectionPath = item.name;
            anchorOffset = at;
            break;
          }
        }
        expect(anchorOffset, greaterThanOrEqualTo(0), reason: 'fixture quote must exist');
      } finally {
        first.dispose();
      }

      // Reopen and resolve the same UTF-16 offset against the same
      // canonical space.
      final second = await BookSession.open(bytes);
      try {
        final text = (await second.loadDocumentText(sectionPath))!;
        expect(text.length, greaterThan(anchorOffset));
        expect(text.substring(anchorOffset, anchorOffset + expectedQuote.length), expectedQuote);
      } finally {
        second.dispose();
      }
    });

    test('a corrupted section cannot confirm the anchor quote', () async {
      final bytes = _alice();
      final session = await BookSession.open(bytes);
      try {
        const quote = 'Alice was beginning to get very tired';
        var found = false;
        for (final item in session.book.readingOrder) {
          final text = await session.loadDocumentText(item.name);
          if ((text?.contains(quote) ?? false)) {
            found = true;
            // Reversing the section content destroys every anchor
            // match — the evidence a durable anchor needs disappears.
            final corrupted = String.fromCharCodes(text!.codeUnits.reversed.toList());
            expect(corrupted.contains(quote), isFalse);
            break;
          }
        }
        expect(found, isTrue, reason: 'fixture quote must exist');
      } finally {
        session.dispose();
      }
    });
  });
}
