import 'dart:convert';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

/// The Readium Locator interchange contract, fixed against the executed
/// `@readium/shared` 2.8.0 toolkit over `tool/readium/corpus/`; see
/// `doc/readium-locators.md`.
void main() {
  group('toolkit-mirroring decode', () {
    test('official example 1: position, progressions, text.after', () {
      final locator = tryDecodeReadiumLocator({
        'href': 'http://example.com/chapter1',
        'type': 'text/html',
        'title': 'Chapter 1',
        'locations': {'position': 4, 'progression': 0.03401, 'totalProgression': 0.01349},
        'text': {
          'after':
              'It is a truth universally acknowledged, that a single man in '
              'possession of a good fortune, must be in want of a wife.',
        },
      });

      expect(locator, isNotNull);
      expect(locator!.href, 'http://example.com/chapter1');
      expect(locator.type, 'text/html');
      expect(locator.title, 'Chapter 1');
      expect(locator.locations.position, 4);
      expect(locator.locations.progression, 0.03401);
      expect(locator.locations.totalProgression, 0.01349);
      expect(locator.locations.fragments, isEmpty);
      expect(locator.text!.after, startsWith('It is a truth'));
      expect(locator.text!.before, isNull);
    });

    test('official example 3: PDF page fragments survive', () {
      final locator = tryDecodeReadiumLocator({
        'href': 'http://example.com/document',
        'type': 'application/pdf',
        'title': 'Page 5',
        'locations': {
          'fragments': ['page=5', 'viewrect=50,50,640,480'],
          'progression': 0.12703,
          'totalProgression': 0.12703,
        },
      });

      expect(locator!.locations.fragments, ['page=5', 'viewrect=50,50,640,480']);
    });

    test('legacy singular fragment folds into fragments', () {
      final locator = tryDecodeReadiumLocator({
        'href': 'chapter1.xhtml',
        'type': 'application/xhtml+xml',
        'locations': {'fragment': 'partialcfi(/4[body01])', 'position': 1, 'progression': 0.0},
      });

      expect(locator!.locations.fragments, ['partialcfi(/4[body01])']);
      // The toolkit drops nothing else; serialize re-emits fragments only.
      final locations = locator.serialize()['locations'] as Map;
      expect(locations.containsKey('fragment'), isFalse);
      expect(locations['fragments'], ['partialcfi(/4[body01])']);
      // Dart emits the double spelling of zero; numeric comparison with
      // the toolkit's `0` is equal.
      expect((locations['progression'] as double), 0.0);
    });

    test('href carrying a fragment splits like the toolkit', () {
      final locator = tryDecodeReadiumLocator({
        'href': 'chapter1.xhtml#para-2',
        'type': 'application/xhtml+xml',
        'title': 'Paragraph 2',
      });

      expect(locator!.href, 'chapter1.xhtml');
      expect(locator.locations.fragments, ['para-2']);
    });

    test('out-of-range locations drop values and keep the locator', () {
      final locator = tryDecodeReadiumLocator({
        'href': 'chapter1.xhtml',
        'type': 'application/xhtml+xml',
        'locations': {'progression': 1.5, 'totalProgression': -0.5, 'position': 0},
      });

      expect(locator, isNotNull);
      expect(locator!.locations.progression, isNull);
      expect(locator.locations.totalProgression, isNull);
      expect(locator.locations.position, isNull);
      // Serialize always carries fragments, empty included — toolkit parity.
      expect((locator.serialize()['locations'] as Map)['fragments'], isEmpty);
    });

    test('non-integer position is dropped (declared stricter divergence)', () {
      final locator = tryDecodeReadiumLocator({
        'href': 'chapter1.xhtml',
        'type': 'application/xhtml+xml',
        'locations': {'position': 2.5},
      });

      expect(locator, isNotNull);
      expect(locator!.locations.position, isNull);
    });

    test('missing href or type rejects', () {
      expect(tryDecodeReadiumLocator({'type': 'application/xhtml+xml'}), isNull);
      expect(tryDecodeReadiumLocator({'href': 'chapter1.xhtml'}), isNull);
      expect(tryDecodeReadiumLocator(<Object?, Object?>{}), isNull);
    });

    test('wrong value types reject structurally', () {
      expect(tryDecodeReadiumLocator({'href': 5, 'type': 'application/xhtml+xml'}), isNull);
      expect(
        tryDecodeReadiumLocator({
          'href': 'c.xhtml',
          'type': 'application/xhtml+xml',
          'locations': {'fragments': 'not-an-array'},
        }),
        isNull,
      );
      expect(
        tryDecodeReadiumLocator({
          'href': 'c.xhtml',
          'type': 'application/xhtml+xml',
          'text': {'highlight': 42},
        }),
        isNull,
      );
    });
  });

  group('extensions policy', () {
    test('unknown location keys stay opaque and re-emit top-level', () {
      final locator = tryDecodeReadiumLocator({
        'href': 'chapter1.xhtml',
        'type': 'application/xhtml+xml',
        'locations': {
          'position': 7,
          'https://example.com/loc-ext': {'second': 42},
        },
      });

      expect(locator!.locations.extensions['https://example.com/loc-ext'], {'second': 42});
      final locations = locator.serialize()['locations'] as Map;
      expect(locations['https://example.com/loc-ext'], {'second': 42});
      expect(locations['position'], 7);
    });

    test('extension bounds reject before interpreting', () {
      Map<Object?, Object?> withExtensions(final List<Map<String, Object?>> entries) => {
        'href': 'c.xhtml',
        'type': 'application/xhtml+xml',
        'locations': {for (final entry in entries) entry.keys.single: entry.values.single},
      };

      // 17 keys cross the 16-key bound.
      expect(
        tryDecodeReadiumLocator(
          withExtensions(List.generate(17, (final index) => {'k$index': index})),
        ),
        isNull,
      );
      // 16 keys stay.
      expect(
        tryDecodeReadiumLocator(
          withExtensions(List.generate(16, (final index) => {'k$index': index})),
        ),
        isNotNull,
      );
      // An oversized value crosses the byte bound.
      expect(
        tryDecodeReadiumLocator({
          'href': 'c.xhtml',
          'type': 'application/xhtml+xml',
          'locations': {'ext': 'x' * 5000},
        }),
        isNull,
      );
    });
  });

  group('bounded string codec', () {
    test('valid locator parses', () {
      final locator = readiumLocatorFromJson(
        jsonEncode({
          'href': 'c.xhtml',
          'type': 'application/xhtml+xml',
          'locations': {'position': 1},
        }),
      );
      expect(locator.locations.position, 1);
      expect(readiumLocatorToJsonString(locator), contains('"position":1'));
    });

    test('malformed JSON fails typed, not with FormatException', () {
      expect(
        () => readiumLocatorFromJson('{href:}'),
        throwsA(isA<ReadiumLocatorFormatException>()),
      );
      expect(
        () => readiumLocatorFromJson('[1,2,3]'),
        throwsA(isA<ReadiumLocatorFormatException>()),
      );
      expect(
        () => readiumLocatorFromJson('{"href":"c.xhtml"}'),
        throwsA(isA<ReadiumLocatorFormatException>()),
      );
    });

    test('limits precede allocation', () {
      // Source cap.
      expect(
        () => readiumLocatorFromJson(' ' * (1 << 20 + 1)),
        throwsA(isA<ReadiumLocatorLimitException>()),
      );
      // Depth cap: 40 nested arrays under a 32-level limit.
      final deep = '{"href":"c","type":"t","locations":{"e":${'[' * 40}${']' * 40}}}';
      expect(() => readiumLocatorFromJson(deep), throwsA(isA<ReadiumLocatorLimitException>()));
      // Node cap under a tiny custom limit set.
      const limits = ReadiumLocatorLimits(maxJsonNodes: 4);
      expect(
        () => readiumLocatorFromJson(
          '{"href":"c","type":"t","locations":{"fragments":["a","b","c","d","e"]}}',
          limits: limits,
        ),
        throwsA(isA<ReadiumLocatorLimitException>()),
      );
    });

    test('position list service decode follows the official example', () {
      final list = readiumPositionListFromJson('''
        {
          "total": 2,
          "positions": [
            {"href": "http://example.com/resource", "type": "application/xhtml+xml",
             "locations": {"fragment": "partialcfi(/4[body01])", "position": 1, "progression": 0.0}},
            {"href": "http://example.com/resource", "type": "application/xhtml+xml",
             "locations": {"fragment": "partialcfi(/18[body02])", "position": 2, "progression": 0.57289}}
          ]
        }
      ''');

      expect(list.total, 2);
      expect(list.positions, hasLength(2));
      expect(list.positions[1].locations.progression, 0.57289);

      final service = jsonDecode(readiumPositionListToJsonString(list)) as Map;
      expect(service.keys.toSet(), {'total', 'positions'});
    });

    test('profile anchors every 1024 scalars with surrogate safety', () {
      final profile = ReadiumPositionListBuilder.profile;
      final plain = 'a' * 3000;
      expect(profile.anchorUtf16Offsets(plain), [0, 1024, 2048]);

      final astral = '\u{1F600}' * 1500; // 2 code units per scalar
      final anchors = profile.anchorUtf16Offsets(astral);
      expect(anchors.first, 0);
      // Scalar 1024 sits at code-unit offset 2048: the anchor lands on
      // the pair's own offset, never splitting a surrogate.
      expect(anchors[1], 2048);
      expect(anchors.length, 2); // 1500 scalars: only the 1024 boundary lands
    });

    test('position list rejects structural damage', () {
      expect(
        () => readiumPositionListFromJson('{"total": 2, "positions": [{"href": "c"}]}'),
        throwsA(isA<ReadiumLocatorFormatException>()),
      );
      expect(
        () => readiumPositionListFromJson('{"positions": []}'),
        throwsA(isA<ReadiumLocatorFormatException>()),
      );
      expect(tryDecodeReadiumPositionListJson({'total': 2, 'positions': <Object?>[]}), isNull);
    });
  });
}
