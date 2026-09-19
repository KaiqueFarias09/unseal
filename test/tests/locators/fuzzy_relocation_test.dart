import 'package:test/test.dart';
import 'package:unseal/src/features/locators/book_locator.dart';
import 'package:unseal/src/features/locators/fuzzy_relocation.dart';

void main() {
  group('relocateTextLocator', () {
    test('relocates after offset drift inside the same section', () {
      const quote = TextQuote(before: 'quick ', text: 'brown fox', after: ' jumped');
      const text = 'Once upon a time the quick brown fox jumped high.';
      final relocated = relocateTextLocator(
        const TextLocator(sectionIndex: 0, start: 26, end: 35, quote: quote),
        [text],
      );
      final found = text.indexOf('brown fox');
      expect(relocated, TextLocator(sectionIndex: 0, start: found, end: found + 9, quote: quote));
    });

    test('keeps a point a point and keeps longer ranges clamped to the quote', () {
      const quote = TextQuote(before: '', text: 'anchor', after: '');
      const text = 'prose anchor prose';
      final point = relocateTextLocator(
        const TextLocator(sectionIndex: 0, start: 6, end: 6, quote: quote),
        [text],
      );
      expect(point!.start, text.indexOf('anchor'));
      expect(point.isPoint, isTrue);

      final long = relocateTextLocator(
        const TextLocator(sectionIndex: 0, start: 6, end: 30, quote: quote),
        [text],
      );
      expect(long!.end, long.start + quote.text.length);
    });

    test('picks the duplicate whose context agrees', () {
      const quote = TextQuote(before: 'c ', text: 'key', after: ' d');
      const text = 'a key b and c key d';
      final relocated = relocateTextLocator(
        const TextLocator(sectionIndex: 0, start: 14, end: 17, quote: quote),
        [text],
      );
      expect(relocated!.start, 14);
      expect(relocated.end, 17);
    });

    test('falls back to the earliest duplicate on a context tie', () {
      const quote = TextQuote(before: '', text: 'key', after: '');
      const text = 'a key b and c key d';
      final relocated = relocateTextLocator(
        const TextLocator(sectionIndex: 0, start: 2, end: 5, quote: quote),
        [text],
      );
      expect(relocated!.start, 2);
    });

    test('follows the quote into another section', () {
      const quote = TextQuote(before: 'the ', text: 'garden gate', after: '.');
      const sections = ['nothing relevant here', 'beyond the garden gate.'];
      final relocated = relocateTextLocator(
        const TextLocator(sectionIndex: 0, start: 7, end: 18, quote: quote),
        sections,
      );
      expect(relocated, TextLocator(sectionIndex: 1, start: 11, end: 22, quote: quote));
    });

    test('prefers a hit in the original section over other sections', () {
      const quote = TextQuote(before: '', text: 'garden gate', after: '');
      const sections = ['a garden gate ahead', 'no quote here', 'garden gate again'];
      final relocated = relocateTextLocator(
        const TextLocator(sectionIndex: 2, start: 0, end: 11, quote: quote),
        sections,
      );
      expect(relocated!.sectionIndex, 2);
      expect(relocated.start, 0);
    });

    test('picks the earliest section on a cross-section tie', () {
      const quote = TextQuote(before: '', text: 'echo', after: '');
      const sections = ['only filler', 'first echo here', 'second echo here'];
      final relocated = relocateTextLocator(
        const TextLocator(sectionIndex: 0, start: 0, end: 4, quote: quote),
        sections,
      );
      expect(relocated!.sectionIndex, 1);
      expect(relocated.start, sections[1].indexOf('echo'));
    });

    test('handles an out-of-range original section', () {
      const quote = TextQuote(before: '', text: 'echo', after: '');
      const sections = ['an echo somewhere'];
      final relocated = relocateTextLocator(
        const TextLocator(sectionIndex: 9, start: 3, end: 7, quote: quote),
        sections,
      );
      expect(relocated!.sectionIndex, 0);
      expect(relocated.start, 3);
    });

    test('returns null when the quote is deleted everywhere', () {
      const quote = TextQuote(before: 'the ', text: 'garden gate', after: '.');
      expect(
        relocateTextLocator(const TextLocator(sectionIndex: 0, start: 4, end: 15, quote: quote), [
          'only the wall.',
        ]),
        isNull,
      );
    });

    test('returns null for a quote-less or empty-text quote', () {
      expect(
        relocateTextLocator(const TextLocator(sectionIndex: 0, start: 0, end: 5), ['some text']),
        isNull,
      );
      expect(
        relocateTextLocator(
          const TextLocator(
            sectionIndex: 0,
            start: 0,
            end: 0,
            quote: TextQuote(before: '', text: '', after: ''),
          ),
          ['some text'],
        ),
        isNull,
      );
    });

    test('returns null when there are no sections at all', () {
      const quote = TextQuote(before: '', text: 'echo', after: '');
      expect(
        relocateTextLocator(const TextLocator(sectionIndex: 0, start: 0, end: 4, quote: quote), []),
        isNull,
      );
    });
  });
}
