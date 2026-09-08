import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

/// Parity tests ported from calibre's
/// `src/calibre/ebooks/metadata/test_author_sort.py`, plus the
/// documented `title_sort` behaviors. Defaults mirror calibre's
/// default tweaks (`author_sort_copy_method = 'comma'`).
void main() {
  void checkAllMethods(
    final String? name, {
    final String? invert,
    final String? comma,
    final String? nocomma,
    final String? copy,
    final bool useSurnamePrefixes = false,
  }) {
    final expectedInvert = invert ?? name;
    final expectedComma = comma ?? expectedInvert;
    final expectedNocomma = nocomma ?? expectedComma;
    final expectedCopy = copy ?? name;

    String sort(final String? author, final AuthorSortMethod method) =>
        authorToAuthorSort(author, method: method, useSurnamePrefixes: useSurnamePrefixes);

    expect(sort(name, AuthorSortMethod.invert), expectedInvert);
    expect(sort(name, AuthorSortMethod.copy), expectedCopy);
    expect(sort(name, AuthorSortMethod.comma), expectedComma);
    expect(sort(name, AuthorSortMethod.nocomma), expectedNocomma);
  }

  group('removeBracketedText (calibre TestRemoveBracketedText)', () {
    test('brackets', () {
      expect(removeBracketedText('a[b]c(d)e{f}g<h>i'), 'aceg<h>i');
    });

    test('nested', () {
      expect(removeBracketedText('a[[b]c(d)e{f}]g(h(i)j[k]l{m})n{{{o}}}p'), 'agnp');
    });

    test('mismatched', () {
      expect(removeBracketedText('a[b(c]d)e'), 'ae');
      expect(removeBracketedText('a{b(c}d)e'), 'ae');
    });

    test('extra closed', () {
      expect(removeBracketedText('a]b}c)d'), 'abcd');
      expect(removeBracketedText('a[b]c]d(e)f{g)h}i}j)k]l'), 'acdfijkl');
    });

    test('unclosed', () {
      expect(removeBracketedText('a]b[c'), 'ab');
      expect(removeBracketedText('a(b[c]d{e}f'), 'a');
      expect(removeBracketedText('a{b}c{d[e]f(g)h'), 'ac');
    });
  });

  group('authorToAuthorSort (calibre TestAuthorToAuthorSort)', () {
    test('single', () {
      checkAllMethods('Aristotle');
    });

    test('all prefix', () {
      checkAllMethods('Mr. Dr Prof.');
    });

    test('all suffix', () {
      checkAllMethods('Senior Inc');
    });

    test('copywords', () {
      checkAllMethods('Don "Team" Smith', invert: 'Smith, Don "Team"', nocomma: 'Smith Don "Team"');
      checkAllMethods('Don Team Smith');
    });

    test('national', () {
      checkAllMethods('National Lampoon');
    });

    test('method', () {
      checkAllMethods('Jane Doe', invert: 'Doe, Jane', nocomma: 'Doe Jane');
    });

    test('prefix suffix', () {
      checkAllMethods(
        'Mrs. Jane Q. Doe III',
        invert: 'Doe, Jane Q. III',
        nocomma: 'Doe Jane Q. III',
      );
    });

    test('surname prefix enabled', () {
      checkAllMethods(
        'Leonardo Da Vinci',
        invert: 'Da Vinci, Leonardo',
        nocomma: 'Da Vinci Leonardo',
        useSurnamePrefixes: true,
      );
      checkAllMethods(
        'Liam Da Mathúna',
        invert: 'Da Mathúna, Liam',
        nocomma: 'Da Mathúna Liam',
        useSurnamePrefixes: true,
      );
      checkAllMethods('Van Gogh', useSurnamePrefixes: true);
      checkAllMethods('Van', useSurnamePrefixes: true);
    });

    test('surname prefix disabled (default)', () {
      checkAllMethods(
        'Leonardo Da Vinci',
        invert: 'Vinci, Leonardo Da',
        nocomma: 'Vinci Leonardo Da',
      );
      checkAllMethods('Van Gogh', invert: 'Gogh, Van', nocomma: 'Gogh Van');
    });

    test('comma', () {
      checkAllMethods(
        'James Wesley, Rawles',
        invert: 'Rawles, James Wesley,',
        comma: 'James Wesley, Rawles',
        nocomma: 'Rawles James Wesley,',
      );
    });

    test('brackets', () {
      checkAllMethods('Seventh Author [7]', invert: 'Author, Seventh', nocomma: 'Author Seventh');
      checkAllMethods(
        'John [x]von Neumann (III)',
        invert: 'Neumann, John von',
        nocomma: 'Neumann John von',
      );
    });

    test('falsy', () {
      checkAllMethods('');
      checkAllMethods(null, invert: '', comma: '', nocomma: '', copy: '');
    });

    test('authors join with ampersand (authors_to_sort_string)', () {
      expect(authorsToSortString(['Jane Doe', 'Don Team Smith']), 'Doe, Jane & Don Team Smith');
      expect(authorsToSortString(const []), '');
    });
  });

  group('titleSort (calibre title_sort)', () {
    test('documented example', () {
      expect(titleSort('The Lord of the Rings'), 'Lord of the Rings, The');
    });

    test('articles a and an', () {
      expect(titleSort('A Study in Scarlet'), 'Study in Scarlet, A');
      expect(titleSort('An Experiment in Criticism'), 'Experiment in Criticism, An');
    });

    test('no article stays untouched', () {
      expect(titleSort('Jane Doe'), 'Jane Doe');
      expect(titleSort('  1984  '), '1984');
    });

    test('case insensitive articles', () {
      expect(titleSort('the time machine'), 'time machine, the');
    });

    test('language specific articles', () {
      expect(titleSort('O Cortiço', lang: 'pt'), 'Cortiço, O');
      expect(titleSort('O Cortiço', lang: 'pt-BR'), 'Cortiço, O');
      expect(titleSort('O Cortiço', lang: 'en'), 'O Cortiço');
      expect(titleSort('Der Steppenwolf', lang: 'de'), 'Steppenwolf, Der');
      expect(titleSort('La Peste', lang: 'fr'), 'Peste, La');
    });

    test('quoted titles', () {
      expect(titleSort('“The Time Machine”'), 'Time Machine, The');
      expect(titleSort('“Alice”'), 'Alice');
    });
  });

  group('effective sort keys', () {
    test('falls back to computed when the file carries none', () {
      const metadata = BookMetadata(
        format: BookFormat.epub,
        title: 'The Lord of the Rings',
        authors: ['Jane Doe'],
      );
      expect(metadata.effectiveTitleSort, 'Lord of the Rings, The');
      expect(metadata.effectiveAuthorSort, 'Doe, Jane');
    });

    test('stored keys win over computed ones', () {
      const metadata = BookMetadata(
        format: BookFormat.epub,
        title: 'The Lord of the Rings',
        titleSort: 'From File',
        authorSort: 'From, File',
        authors: ['Jane Doe'],
      );
      expect(metadata.effectiveTitleSort, 'From File');
      expect(metadata.effectiveAuthorSort, 'From, File');
    });

    test('book language picks the article list', () {
      const metadata = BookMetadata(
        format: BookFormat.epub,
        title: 'O Cortiço',
        languages: ['pt-BR'],
      );
      expect(metadata.effectiveTitleSort, 'Cortiço, O');
    });

    test('nothing to sort without title or authors', () {
      const metadata = BookMetadata(format: BookFormat.mobi);
      expect(metadata.effectiveTitleSort, isNull);
      expect(metadata.effectiveAuthorSort, isNull);
    });
  });
}
