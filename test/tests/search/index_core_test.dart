import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import 'book_index_fixture.dart';

void main() {
  group('search index tokenizer', () {
    List<IndexedToken> tokensOf(final String text) => SearchIndexTokenizer().tokenize(text);

    test('projects tokens to original UTF-16 ranges', () {
      final tokens = tokensOf('Olá, mundo!');
      expect(tokens, hasLength(2));
      expect(tokens[0].term, 'ola');
      expect(tokens[0].start, 0);
      expect(tokens[0].end, 3); // Ó takes one code unit.
      expect(tokens[1].term, 'mundo');
      expect('Olá, mundo!'.substring(tokens[1].start, tokens[1].end), 'mundo');
    });

    test('cuts astral text on the original range', () {
      final text = 'a𐍈b';
      final tokens = tokensOf(text);
      expect(tokens, hasLength(1));
      expect(tokens.single.start, 0);
      expect(tokens.single.end, text.length); // 4 code units, one astral pair.
    });

    test('joins soft-hyphen-split words and keeps the hyphen in the range', () {
      final text = 'colo\u00ADrial';
      final tokens = tokensOf(text);
      expect(tokens, hasLength(1));
      expect(tokens.single.term, 'colorial');
      expect(text.substring(tokens.single.start, tokens.single.end), text);
    });

    test('zero-width joiners stay ignorable inside runs', () {
      final tokens = tokensOf('para\u200Bdice');
      expect(tokens.single.term, 'paradice');
    });

    test('folds precomposed and combining accents to the same term', () {
      final precomposed = tokensOf('ação').single.term;
      final combining = tokensOf('aça\u0303o').single.term;
      expect(precomposed, 'acao');
      expect(combining, 'acao');
    });

    test('folds Portuguese, German sharp s, and fullwidth forms', () {
      expect(tokensOf('AÇÃO').single.term, 'acao');
      expect(tokensOf('Straße').single.term, 'strasse');
      expect(tokensOf('Ｔｅｓｔ１２３').single.term, 'test123');
    });

    test('folds Cyrillic and Greek case', () {
      expect(tokensOf('Москва').single.term, 'москва');
      expect(tokensOf('ПРИВЕТ').single.term, 'привет');
      expect(tokensOf('Παράδειγμα').single.term, 'παραδειγμα');
    });

    test('plain hyphens split tokens like the legacy grammar', () {
      final tokens = tokensOf('state-of-the-art');
      expect(tokens.map((final t) => t.term), <String>['state', 'of', 'the', 'art']);
    });

    test('combining marks do not split a run', () {
      expect(tokensOf('e\u0301gal').single.term, 'egal');
    });
  });

  group('book search index', () {
    test('finds hits and cuts the original text', () async {
      final index = await BookSearchIndex.build(
        buildIndexedBook(<int, String>{0: 'A navegação do leitor.', 1: 'Outra página.'}),
      );
      final results = index.query('navegacao');
      expect(results.hits, hasLength(1));
      expect(results.hits.single.sectionIndex, 0);
      const text = 'A navegação do leitor.';
      expect(text.substring(results.hits.single.start, results.hits.single.end), 'navegação');
      expect(results.coverage.isComplete, isTrue);
      expect(results.isTruncated, isFalse);
      // The hit converts to the shared locator space.
      final locator = results.hits.single.toTextLocator();
      expect(locator.sectionIndex, 0);
      expect(locator.end - locator.start, 'navegação'.length);
    });

    test('repeated paths stay distinct occurrences', () async {
      final book = buildIndexedBook(<int, String>{0: 'feitiço', 1: 'outro feitiço'});
      // Same path twice in the reading order: two distinct occurrences.
      final index = await BookSearchIndex.build(book);
      final results = index.query('feitico');
      expect(results.hits, hasLength(2));
      expect(results.hits.map((final h) => h.sectionName).toSet(), <String>{
        'section0.html',
        'section1.html',
      });
    });

    test('prefix mode expands the last token only', () async {
      final index = await BookSearchIndex.build(
        buildIndexedBook(<int, String>{0: 'navio navegação nave', 1: 'mar'}),
      );
      final prefix = index.query('nave', mode: IndexedQueryMode.prefix);
      expect(prefix.hits, hasLength(2));
      expect(prefix.hits.every((final h) => h.sectionIndex == 0), isTrue);
      // Exact mode sees only the literal token: the first 'nave'.
      final exact = index.query('nave');
      expect(exact.hits.single.start, exact.hits.single.end - 4);
      // The prefix hit count covers both anchored terms ('nave' and
      // 'navegação' occurrences).
      expect(prefix.hits, hasLength(2));
    });

    test('fuzzy mode matches within the derived distance', () async {
      final index = await BookSearchIndex.build(
        buildIndexedBook(<int, String>{0: 'navio navegacao navegaca zebra'}),
      );
      // 'navegacao' derives distance 2 (a fifth of its length, rounded);
      // 'navegaca' sits at distance 1, 'navio' and 'zebra' far away.
      final results = index.query('navegacao', mode: IndexedQueryMode.fuzzy);
      expect(results.hits, hasLength(2));
      expect(results.hits.map((final h) => h.end - h.start).toSet(), <int>{9, 8});
    });

    test('multi-token queries require every token', () async {
      final index = await BookSearchIndex.build(
        buildIndexedBook(<int, String>{0: 'white rabbit', 1: 'white', 2: 'rabbit run'}),
      );
      final results = index.query('white rabbit');
      expect(results.hits.single.sectionIndex, 0);
    });

    test('tiebreak follows score desc, occurrence, start, end', () async {
      final index = await BookSearchIndex.build(
        buildIndexedBook(<int, String>{0: 'repeat repeat', 1: 'repeat and more words repeat'}),
      );
      final results = index.query('repeat');
      // The shorter section scores higher; its second occurrence
      // follows with an equal score and a larger start.
      expect(results.hits.first.sectionIndex, 0);
      expect(results.hits.first.start, 0);
      final second = results.hits[1];
      expect(second.sectionIndex, 0);
      expect(second.start, 7);
    });

    test('complete builds report complete coverage', () async {
      final index = await BookSearchIndex.build(
        buildIndexedBook(<int, String>{0: 'palavra', 1: 'palavra escondida'}),
        sectionsPerBatch: 1,
      );
      final results = index.query('escondida');
      expect(results.hits, hasLength(1));
      expect(results.coverage.isComplete, isTrue);
      expect(results.coverage.indexedSections, 2);
    });

    test('prefix fan-out beyond the cap fails typed', () async {
      final index = await BookSearchIndex.build(
        buildIndexedBook(<int, String>{0: 'aa ab ac ad ae af ag ah'}),
      );
      expect(
        () => index.query('a', mode: IndexedQueryMode.prefix, maxExpansions: 2),
        throwsA(isA<SearchIndexLimitExceededException>()),
      );
    });

    test('queries with too many tokens fail typed', () async {
      final index = await BookSearchIndex.build(buildIndexedBook(<int, String>{0: 'text'}));
      expect(
        () => index.query(List.filled(20, 'w').join(' ')),
        throwsA(isA<SearchIndexInvalidArgumentException>()),
      );
    });

    test('truncation reports the cut', () async {
      final index = await BookSearchIndex.build(buildIndexedBook(<int, String>{0: 'x x x x x'}));
      final results = index.query('x', maxMatches: 2);
      expect(results.hits, hasLength(2));
      expect(results.isTruncated, isTrue);
    });

    test('empty queries return empty results without failing', () async {
      final index = await BookSearchIndex.build(buildIndexedBook(<int, String>{0: 'texto'}));
      expect(index.query('').hits, isEmpty);
      expect(index.query('   ').hits, isEmpty);
      expect(index.query('inexistente').hits, isEmpty);
    });
  });
}
