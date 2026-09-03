import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

import '../mobi/mobi_fixture_builder.dart';

Uint8List _buildBook(final String html) {
  return buildPdb('Synthetic', [
    buildMobiRecord0(
      textRecordCount: 1,
      title: 'Search Fixture',
    ),
    Uint8List.fromList(convert.utf8.encode(html)),
  ]);
}

Book parseFixture(final String html) => BookReader.parseBook(_buildBook(html));

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
      final book = parseFixture(
        '<html><body><p>abc abc abc abc abc abc</p></body></html>',
      );
      final results = book.search('abc', maxMatches: 2);
      expect(results.matches, hasLength(2));
      expect(results.truncated, isTrue);
    });

    test('matches in later sections carry their reading-order index', () {
      final book = parseFixture(
        '<html><body><p>first chapter</p></body></html>',
      );
      final results = book.search('chapter');
      expect(results.matches.single.sectionName, isNotEmpty);
    });
  });
}
