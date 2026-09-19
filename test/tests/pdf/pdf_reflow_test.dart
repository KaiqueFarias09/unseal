import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import 'pdf_fixture_builder.dart';

void main() {
  group('PDF reflow', () {
    test('merges continuation lines into one paragraph', () {
      final book = parsePdfBook(paragraphPageFixture().build());
      final html = book.files.html.single.content;

      // Lines 1-3 coalesce; the paragraph keeps the canonical
      // separators inside one text node.
      expect(html, contains('the age\nof wisdom'));
      expect(html, contains('the season of Light,'));
      // Paragraph two stays its own block.
      expect(html, contains('<p>A second paragraph'));
      // Only one id anchor per page.
      expect(RegExp('id="page_').allMatches(html), hasLength(1));
    });

    test('detects the centered chapter heading', () {
      final book = parsePdfBook(paragraphPageFixture().build());
      final html = book.files.html.single.content;

      expect(html, contains('<h2'));
      expect(html, contains('CHAPTER I</span></h2>'));
    });

    test('the canonical invariant holds: documentText == page text', () {
      for (final bytes in [
        paragraphPageFixture().build(),
        textPageFixture().build(),
        headerFooterFixture().build(),
      ]) {
        final book = parsePdfBook(bytes);
        for (var i = 0; i < book.pageCount; i++) {
          expect(
            DocumentTextScanner(book.files.html[i].content).scan(),
            book.pageTexts[i].text,
            reason: 'page ${i + 1} of ${book.pageCount} broke the canonical invariant',
          );
        }
      }
    });

    test('removes repeated headers and footers', () {
      final book = parsePdfBook(headerFooterFixture().build());

      expect(book.pageCount, 6);
      for (var i = 0; i < book.pageCount; i++) {
        expect(book.pageTexts[i].text, isNot(contains('A Tale of Two Cities')));
        expect(book.pageTexts[i].text, isNot(contains('Page ${i + 1}')));
        expect(book.pageTexts[i].text, contains('Body line one'));
      }
    });

    test('search and progression address the reflowed text space', () {
      final book = parsePdfBook(paragraphPageFixture().build());

      final results = book.search('wisdom');
      expect(results.matches, hasLength(1));
      expect(results.matches.single.sectionIndex, 0);
      expect(
        book.pageTexts.single.text.substring(
          results.matches.single.start,
          results.matches.single.end,
        ),
        'wisdom',
      );

      final progression = BookProgression.of(book);
      expect(progression.sectionCount, 1);
      expect(progression.totalCharacters, book.pageTexts.single.text.length);
    });

    test('reading order is one item per page', () {
      final book = parsePdfBook(headerFooterFixture().build());

      expect(book.readingOrder, hasLength(6));
      expect(book.readingOrder.first.name, 'page_1.html');
      expect(book.readingOrder.last.name, 'page_6.html');
    });

    test('outline anchors land on the reflowed pages', () {
      final book = parsePdfBook(twoPageFixture().build());

      // Empty pages still emit their (empty) section, keeping the
      // page/section index alignment the anchors rely on.
      expect(book.files.html, hasLength(2));
      final targets = resolveNavigation(book);
      expect(targets, hasLength(2));
      expect(targets[1]?.sectionIndex, 1);
    });
  });
}
