import 'package:test/test.dart';
import 'package:unseal/src/features/locators/book_locator.dart';
import 'package:unseal/src/features/locators/search_locator.dart';
import 'package:unseal/src/features/search/entities/search_match.dart';

void main() {
  group('SearchMatchLocators.toTextLocator', () {
    test('maps a search match onto a range text locator', () {
      const match = SearchMatch(
        sectionIndex: 2,
        sectionName: 'OEBPS/ch03.xhtml',
        start: 120,
        end: 126,
        snippet: '…the white rabbit…',
      );
      expect(match.toTextLocator(), const TextLocator(sectionIndex: 2, start: 120, end: 126));
      expect(match.toTextLocator().quote, isNull);
    });

    test('maps a zero-length match onto a point', () {
      const match = SearchMatch(
        sectionIndex: 0,
        sectionName: 'c.xhtml',
        start: 5,
        end: 5,
        snippet: '',
      );
      expect(match.toTextLocator().isPoint, isTrue);
    });
  });
}
