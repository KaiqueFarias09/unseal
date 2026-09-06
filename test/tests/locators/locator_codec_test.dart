import 'package:e_livre/src/features/locators/book_locator.dart';
import 'package:e_livre/src/features/locators/locator_codec.dart';
import 'package:test/test.dart';

void main() {
  group('locatorToJson and locatorFromJson', () {
    test('round-trips a point text locator', () {
      const locator = TextLocator(sectionIndex: 3, start: 42, end: 42);
      expect(locatorFromJson(locatorToJson(locator)), locator);
    });

    test('round-trips a range text locator with a quote', () {
      const locator = TextLocator(
        sectionIndex: 1,
        start: 10,
        end: 25,
        quote: TextQuote(before: 'the ', text: 'quick brown fox', after: ' jumps'),
      );
      expect(locatorFromJson(locatorToJson(locator)), locator);
    });

    test('round-trips a cfi locator', () {
      const locator = CfiLocator('epubcfi(/6/4!/4/2:10)');
      expect(locatorFromJson(locatorToJson(locator)), locator);
    });

    test('round-trips page locators with and without a total', () {
      const paged = PageLocator(pageIndex: 7, total: 128);
      const open = PageLocator(pageIndex: 2);
      expect(locatorFromJson(locatorToJson(paged)), paged);
      expect(locatorFromJson(locatorToJson(open)), open);
    });

    test('emits the version and kind envelope', () {
      expect(locatorToJson(const CfiLocator('epubcfi(/6/4)')), {
        'v': 1,
        'kind': 'cfi',
        'cfi': 'epubcfi(/6/4)',
      });
      final text = locatorToJson(const TextLocator(sectionIndex: 0, start: 1, end: 2));
      expect(text['v'], 1);
      expect(text['kind'], 'text');
      expect(locatorToJson(const PageLocator(pageIndex: 0))['kind'], 'page');
    });

    test('rejects unknown and missing versions', () {
      const payload = {'kind': 'text', 'sectionIndex': 0, 'start': 0, 'end': 0};
      expect(locatorFromJson({...payload, 'v': 2}), isNull);
      expect(locatorFromJson({...payload, 'v': 99}), isNull);
      expect(locatorFromJson(payload), isNull);
    });

    test('rejects unknown kinds and malformed payloads', () {
      expect(locatorFromJson({'v': 1, 'kind': 'waveform'}), isNull);
      expect(locatorFromJson({'v': 1, 'kind': 'cfi'}), isNull);
      expect(locatorFromJson({'v': 1, 'kind': 'cfi', 'cfi': ''}), isNull);
      expect(locatorFromJson({'v': 1, 'kind': 'text', 'sectionIndex': 0, 'start': 0}), isNull);
      expect(
        locatorFromJson({'v': 1, 'kind': 'text', 'sectionIndex': 'x', 'start': 0, 'end': 0}),
        isNull,
      );
      expect(locatorFromJson({'v': 1, 'kind': 'page'}), isNull);
      expect(
        locatorFromJson({
          'v': 1,
          'kind': 'text',
          'sectionIndex': 0,
          'start': 0,
          'end': 0,
          'quote': {'text': 9},
        }),
        isNull,
      );
    });
  });

  group('eLv1 interop', () {
    test('parses a valid point locator', () {
      expect(
        textLocatorFromELv1('eLv1:3:128'),
        const TextLocator(sectionIndex: 3, start: 128, end: 128),
      );
      expect(textLocatorFromELv1('eLv1:0:0'), const TextLocator(sectionIndex: 0, start: 0, end: 0));
    });

    test('emits the canonical eLv1 form', () {
      expect(eLv1Of(const TextLocator(sectionIndex: 12, start: 34, end: 56)), 'eLv1:12:34');
    });

    test('round-trips through parse and emit', () {
      expect(eLv1Of(textLocatorFromELv1('eLv1:0:0')!), 'eLv1:0:0');
      expect(eLv1Of(textLocatorFromELv1('eLv1:7:912')!), 'eLv1:7:912');
    });

    test('rejects malformed strings', () {
      expect(textLocatorFromELv1(''), isNull);
      expect(textLocatorFromELv1('eLv1'), isNull);
      expect(textLocatorFromELv1('eLv1:3'), isNull);
      expect(textLocatorFromELv1('eLv1:3:12:9'), isNull);
      expect(textLocatorFromELv1('eLv2:3:12'), isNull);
      expect(textLocatorFromELv1('elv1:3:12'), isNull);
      expect(textLocatorFromELv1('eLv1:a:12'), isNull);
      expect(textLocatorFromELv1('eLv1:3:b'), isNull);
    });

    test('rejects negative file indexes', () {
      expect(textLocatorFromELv1('eLv1:-1:0'), isNull);
    });

    test('clamps negative offsets to zero like the viewer', () {
      expect(
        textLocatorFromELv1('eLv1:3:-12'),
        const TextLocator(sectionIndex: 3, start: 0, end: 0),
      );
    });
  });
}
