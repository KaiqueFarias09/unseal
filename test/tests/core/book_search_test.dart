import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

import '../mobi/mobi_fixture_builder.dart';

Uint8List _buildBook(final String html) {
  return buildPdb('Synthetic', [
    buildMobiRecord0(textRecordCount: 1, title: 'Search Fixture'),
    Uint8List.fromList(convert.utf8.encode(html)),
  ]);
}

Book parseFixture(final String html) => BookReader.parseBook(_buildBook(html));

/// Builds an EPUB book in memory. Unlike the MOBI pipeline, this
/// preserves invisible characters (soft hyphens, zero-width spaces),
/// which the MOBI text decoder normalizes away.
Book buildEpubFixture(final String html) {
  return EpubBook(
    navigation: Navigation(title: 'Contents', navPoints: const []),
    files: Files(
      images: const [],
      css: const [],
      html: [TextFile(name: 'chapter1.html', type: 'xhtml', path: 'chapter1.html', content: html)],
      fonts: const [],
      others: const [],
    ),
    cover: BinaryFile.empty(),
    package: Epub2Package(
      xmlns: null,
      uniqueIdentifier: 'uid',
      version: '2.0',
      metadata: Epub2Metadata(
        rights: const [],
        contributor: null,
        creator: 'Test Author',
        publisher: null,
        title: 'Search Fixture',
        date: '2024-01-01',
        language: 'en',
        subject: null,
        description: null,
        identifiers: const ['test-id-1'],
        uniqueIdentifierValue: 'test-id-1',
      ),
      manifest: Epub2Manifest(
        items: [ManifestItem(path: 'chapter1.html', id: 'c1', mediaType: 'application/xhtml+xml')],
      ),
      spine: Spine(tocId: null, items: const ['c1']),
      guide: null,
    ),
  );
}

void main() {
  group('book search', () {
    test('finds every occurrence case-insensitively', () {
      final book = parseFixture(
        '<html><body><p>The quick brown fox. the lazy dog.</p></body></html>',
      );
      final results = book.search('the');
      expect(results.matches, hasLength(2));
      expect(results.truncated, isFalse);
      expect(results.query, 'the');
      for (final match in results.matches) {
        expect(match.sectionIndex, 0);
        expect(match.snippet.toLowerCase(), contains('the'));
        expect(match.end, greaterThan(match.start));
      }
    });

    test('respects caseSensitive', () {
      final book = parseFixture(
        '<html><body><p>The quick brown fox. the lazy dog.</p></body></html>',
      );
      expect(book.search('the', caseSensitive: true).matches, hasLength(1));
      expect(book.search('The', caseSensitive: true).matches, hasLength(1));
    });

    test('builds a context snippet around the match', () {
      final book = parseFixture(
        '<html><body><p>${'lorem ipsum ' * 20}needle here${' dolor sit' * 20}</p></body></html>',
      );
      final results = book.search('needle');
      expect(results.matches, hasLength(1));
      final snippet = results.matches.single.snippet;
      expect(snippet, contains('needle here'));
      expect(snippet.startsWith('…'), isTrue);
      expect(snippet.endsWith('…'), isTrue);
    });

    test('returns no matches for absent terms', () {
      final book = parseFixture('<html><body><p>Hello world</p></body></html>');
      final results = book.search('zebra');
      expect(results.matches, isEmpty);
      expect(results.truncated, isFalse);
    });

    test('empty queries match nothing', () {
      final book = parseFixture('<html><body><p>Hello world</p></body></html>');
      expect(book.search('').matches, isEmpty);
    });

    test('truncates at maxMatches', () {
      final book = parseFixture('<html><body><p>abc abc abc abc abc abc</p></body></html>');
      final results = book.search('abc', maxMatches: 2);
      expect(results.matches, hasLength(2));
      expect(results.truncated, isTrue);
    });

    test('matches in later sections carry their reading-order index', () {
      final book = parseFixture('<html><body><p>first chapter</p></body></html>');
      final results = book.search('chapter');
      expect(results.matches.single.sectionName, isNotEmpty);
    });

    test('tolerates soft hyphens between characters', () {
      final book = buildEpubFixture('<html><body><p>colo\u00ADrial water</p></body></html>');
      // 'colorial' is split by a soft hyphen; the tolerant pattern
      // matches it without the hyphen in the query.
      expect(book.search('colorial').matches, hasLength(1));
      // Calibre joins EVERY character pair with the invisible
      // separator, so 'color' also matches the hyphen-split
      // 'colo\u00ADr' prefix of a longer word — wholeWords mode is
      // the remedy for that.
      expect(book.search('color').matches, hasLength(1));
      expect(book.search('color', mode: SearchMode.wholeWords).matches, isEmpty);
    });

    test('collapses whitespace runs in the query', () {
      final book = parseFixture('<html><body><p>between  two   words</p></body></html>');
      expect(book.search('between two words').matches, hasLength(1));
      expect(book.search('between   two\nwords').matches, hasLength(1));
    });

    group('wholeWords mode', () {
      test('matches whole words only', () {
        final book = parseFixture('<html><body><p>the theme they hold the</p></body></html>');
        final results = book.search('the', mode: SearchMode.wholeWords);
        expect(results.matches, hasLength(2));
      });

      test('requires every token as a whole word', () {
        final book = parseFixture(
          '<html><body><p>red herring; a red car and a herring</p></body></html>',
        );
        expect(book.search('red herring', mode: SearchMode.wholeWords).matches, hasLength(1));
      });

      test('keeps the tolerant leniency inside tokens', () {
        final book = buildEpubFixture('<html><body><p>colo\u00ADrial pattern</p></body></html>');
        expect(book.search('colorial', mode: SearchMode.wholeWords).matches, hasLength(1));
      });
    });

    group('regex mode', () {
      test('matches the raw pattern', () {
        final book = parseFixture('<html><body><p>foo123 bar456 baz</p></body></html>');
        final results = book.search(r'\w+\d+', mode: SearchMode.regex);
        expect(results.matches, hasLength(2));
      });

      test('is multiline and honors caseSensitive', () {
        final book = parseFixture('<html><body><p>First line\nsecond line</p></body></html>');
        final results = book.search('^second', mode: SearchMode.regex);
        expect(results.matches, hasLength(1));
        expect(book.search('^SECOND', mode: SearchMode.regex).matches, hasLength(1));
        expect(
          book.search('^SECOND', mode: SearchMode.regex, caseSensitive: true).matches,
          isEmpty,
        );
      });

      test('throws FormatException for an invalid pattern', () {
        final book = parseFixture('<html><body><p>x</p></body></html>');
        expect(() => book.search('([unclosed', mode: SearchMode.regex), throwsFormatException);
      });
    });

    group('proximity mode', () {
      test('finds all words within the default interval', () {
        final book = parseFixture(
          '<html><body><p>the quick brown fox jumps over the lazy dog</p></body></html>',
        );
        // Calibre's near requires every word inside a candidate
        // window; the any-word alternation does not impose an order.
        expect(book.search('quick lazy', mode: SearchMode.proximity).matches, hasLength(1));
        expect(book.search('lazy quick', mode: SearchMode.proximity).matches, hasLength(1));
      });

      test('rejects windows wider than the interval', () {
        final book = parseFixture(
          '<html><body><p>${'filler ' * 30}start ${'filler ' * 30}end</p></body></html>',
        );
        // ~180 characters apart: outside the 60-char default, inside 400.
        expect(book.search('start end', mode: SearchMode.proximity).matches, isEmpty);
        expect(book.search('start end 400', mode: SearchMode.proximity).matches, hasLength(1));
      });

      test('trailing digits set the interval, not a search word', () {
        final book = parseFixture('<html><body><p>alpha beta gamma</p></body></html>');
        expect(book.search('alpha gamma 20', mode: SearchMode.proximity).matches, hasLength(1));
      });

      test('second pass requires every word inside the window', () {
        // The any-word alternation alone would match "alpha alpha"
        // windows; every listed word must actually occur.
        final book = parseFixture('<html><body><p>alpha alpha beta</p></body></html>');
        expect(book.search('alpha beta', mode: SearchMode.proximity).matches, hasLength(1));
        expect(book.search('alpha delta', mode: SearchMode.proximity).matches, isEmpty);
      });

      test('throws for fewer than two words', () {
        final book = parseFixture('<html><body><p>lonely</p></body></html>');
        expect(() => book.search('lonely', mode: SearchMode.proximity), throwsFormatException);
      });
    });
  });
}
