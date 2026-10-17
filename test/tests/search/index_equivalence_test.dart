import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import 'book_index_fixture.dart';

/// An independent naive implementation of the same query grammar: word
/// runs by the legacy `[\p{L}\p{N}_]` rule, folding via
/// `toLowerCase` plus an explicit Latin-1/Latin-Extended-A unaccent
/// map written separately from the index profile. Equivalence on the
/// plain-word corpus below means the index's projection is honest.
final RegExp _wordRun = RegExp(r'[\p{L}\p{N}_]+', unicode: true);

const Map<String, String> _unaccent = <String, String>{
  'á': 'a',
  'à': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'é': 'e',
  'è': 'e',
  'ê': 'e',
  'ë': 'e',
  'í': 'i',
  'ì': 'i',
  'î': 'i',
  'ï': 'i',
  'ó': 'o',
  'ò': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ú': 'u',
  'ù': 'u',
  'û': 'u',
  'ü': 'u',
  'ç': 'c',
  'ñ': 'n',
  'ý': 'y',
  'ÿ': 'y',
  'ß': 'ss',
  'æ': 'ae',
  'œ': 'oe',
};

String _naiveFold(final String run) {
  final lowered = run.toLowerCase();
  final buffer = StringBuffer();
  for (var i = 0; i < lowered.length; i++) {
    buffer.write(_unaccent[lowered[i]] ?? lowered[i]);
  }

  return buffer.toString();
}

/// Every naive occurrence of every word run: `(sectionIndex, term,
/// start, end)`.
List<(int, String, int, int)> _naiveTokens(final List<String> sections) {
  return <(int, String, int, int)>[
    for (var sectionIndex = 0; sectionIndex < sections.length; sectionIndex++)
      for (final match in _wordRun.allMatches(sections[sectionIndex]))
        (sectionIndex, _naiveFold(match[0]!), match.start, match.end),
  ];
}

void main() {
  // One fixed multi-section corpus: Portuguese accents, repeated words
  // across and inside sections, punctuation runs, digits, hyphens.
  const corpus = <int, String>{
    0: 'A navegação do leitor percorre capítulos; o leitor decide.',
    1: 'Navegação repetida: navegação e mais navegação!',
    2: 'Palavras compostas como correção e correção de texto.',
    3: 'Números 123 e palavras1 misturadas; MAIÚSCULAS e maiúsculas.',
    4: 'Uma seção sem acentos e outra com coração, ação, feitiço.',
  };

  Future<BookSearchIndex> buildIndex() async => BookSearchIndex.build(buildIndexedBook(corpus));

  Set<(int, int, int)> hitsOf(final IndexedSearchResults results) {
    return <(int, int, int)>{
      for (final hit in results.hits) (hit.sectionIndex, hit.start, hit.end),
    };
  }

  Set<(int, int, int)> naiveHitsOf(
    final List<(int, String, int, int)> tokens,
    final bool Function(String term) matches,
  ) {
    return <(int, int, int)>{
      for (final (s, term, start, end) in tokens)
        if (matches(term)) (s, start, end),
    };
  }

  test('exact queries match the naive word-run scan', () async {
    final index = await buildIndex();
    final tokens = _naiveTokens(corpus.values.toList());
    const queries = <String>[
      'navegacao',
      'leitor',
      'correcao',
      'coracao',
      'feitico',
      'maiusculas',
      'palavras1',
      '123',
      'inexistente',
      'acao',
    ];
    for (final query in queries) {
      final results = index.query(query);
      expect(
        hitsOf(results),
        naiveHitsOf(tokens, (final term) => term == query),
        reason: 'exact "$query"',
      );
    }
  });

  test('case-insensitive queries match the naive fold', () async {
    final index = await buildIndex();
    final tokens = _naiveTokens(corpus.values.toList());
    expect(
      hitsOf(index.query('MAIÚSCULAS')),
      naiveHitsOf(tokens, (final term) => term == 'maiusculas'),
    );
    expect(
      hitsOf(index.query('Navegação')),
      naiveHitsOf(tokens, (final term) => term == 'navegacao'),
    );
  });

  test('multi-token queries anchor the first token where all match', () async {
    final index = await buildIndex();
    final tokens = _naiveTokens(corpus.values.toList());
    // Sections holding both 'leitor' and 'decide': only section 0.
    final bothSections = <int>{
      for (final (s, term, _, _) in tokens)
        if (term == 'leitor' || term == 'decide') s,
    };
    expect(bothSections, <int>{0});
    final naive = <(int, int, int)>{
      for (final (s, term, start, end) in tokens)
        if (term == 'leitor' && bothSections.contains(s)) (s, start, end),
    };
    expect(hitsOf(index.query('leitor decide')), naive);
  });

  test('prefix queries match the naive prefix scan', () async {
    final index = await buildIndex();
    final tokens = _naiveTokens(corpus.values.toList());
    for (final prefix in const <String>['nave', 'corr', 'le', 'z']) {
      final results = index.query(prefix, mode: IndexedQueryMode.prefix);
      // The exact term plus its expansions anchor occurrences; the
      // naive scan lists every run starting with the prefix.
      expect(
        hitsOf(results),
        naiveHitsOf(tokens, (final term) => term.startsWith(prefix)),
        reason: 'prefix "$prefix"',
      );
    }
  });

  test('truncation cuts the naive hit set deterministically', () async {
    final index = await buildIndex();
    final results = index.query('navegacao', maxMatches: 2);
    expect(results.hits, hasLength(2));
    expect(results.isTruncated, isTrue);
    // The surviving hits are the top two of the full ranking.
    final full = index.query('navegacao');
    (int, int, int) keyOf(final IndexedSearchHit hit) => (hit.sectionIndex, hit.start, hit.end);
    expect(results.hits.map(keyOf).toList(), full.hits.take(2).map(keyOf).toList());
  });
}
