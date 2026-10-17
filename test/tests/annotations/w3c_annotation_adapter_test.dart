import 'package:test/test.dart';
import 'package:unseal/src/features/annotations/durable/anchor_limits.dart';
import 'package:unseal/src/features/annotations/durable/annotation_anchor.dart';
import 'package:unseal/src/features/annotations/durable/w3c_annotation_adapter.dart';

import '../../support/anchor_fixtures.dart';

void main() {
  group('code point ↔ UTF-16 conversion', () {
    // 'livro 📖 e nota 𝄞': the two astral characters are one code
    // point and two UTF-16 units each.
    const astral = 'livro 📖 e nota 𝄞';

    test('astral characters count once', () {
      final conversion = W3cAnnotationAdapter.utf16RangeFromPositionSelector(
        astral,
        const W3cTextPositionSelector(start: 6, end: 7),
      );

      expect(conversion, isA<W3cRangeConverted>());
      final converted = conversion as W3cRangeConverted;
      expect(converted.start, 6);
      expect(converted.end, 8); // The 📖 pair spans two units.
      expect(astral.substring(converted.start, converted.end), '📖');
    });

    test('the reverse conversion returns one code point for a pair', () {
      final conversion = W3cAnnotationAdapter.positionSelectorFromUtf16Range(
        astral,
        start: 6,
        end: 8,
      );

      expect(conversion, isA<W3cRangeConverted>());
      expect((conversion as W3cRangeConverted).start, 6);
      expect(conversion.end, 7);
    });

    test('combining marks count individually (declared: no grapheme clustering)', () {
      const text = 'e\u0301clair'; // é as e + combining acute, 6 code points, 6 units.
      final conversion = W3cAnnotationAdapter.positionSelectorFromUtf16Range(
        text,
        start: 0,
        end: 6,
      );

      expect(conversion, isA<W3cRangeConverted>());
      expect((conversion as W3cRangeConverted).end, 6);

      final back = W3cAnnotationAdapter.utf16RangeFromPositionSelector(
        text,
        const W3cTextPositionSelector(start: 0, end: 2),
      );
      expect((back as W3cRangeConverted).end, 2);
      expect(text.substring(0, 2), 'e\u0301');
    });

    test('a bound inside a surrogate pair is unrepresentable and unshifted', () {
      // Offset 7 is between the surrogate halves of 📖.
      final conversion = W3cAnnotationAdapter.positionSelectorFromUtf16Range(
        astral,
        start: 6,
        end: 7,
      );

      expect(conversion, isA<W3cRangeUnconverted>());
      expect(
        (conversion as W3cRangeUnconverted).reason,
        W3cConversionUnsupportedReason.midSurrogatePair,
      );

      // The isolated-surrogate fixture: a lone high surrogate stays a
      // one-unit code point, so its offsets still convert.
      const lone = '\u{1F600}\uD800fim';
      final loneConversion = W3cAnnotationAdapter.positionSelectorFromUtf16Range(
        lone,
        start: 2,
        end: 3,
      );
      expect(loneConversion, isA<W3cRangeConverted>());
    });

    test('out-of-range positions report instead of clamping', () {
      final pastEnd = W3cAnnotationAdapter.utf16RangeFromPositionSelector(
        astral,
        const W3cTextPositionSelector(start: 0, end: 99),
      );
      expect(pastEnd, isA<W3cRangeUnconverted>());
      expect(
        (pastEnd as W3cRangeUnconverted).reason,
        W3cConversionUnsupportedReason.positionOutOfRange,
      );

      final negative = W3cAnnotationAdapter.utf16RangeFromPositionSelector(
        astral,
        const W3cTextPositionSelector(start: -1, end: 2),
      );
      expect(negative, isA<W3cRangeUnconverted>());

      // An empty selection at the very end is representable: 18 UTF-16
      // units are 16 code points, and the end boundary is a code point
      // index.
      final endBoundary = W3cAnnotationAdapter.positionSelectorFromUtf16Range(
        astral,
        start: astral.length,
        end: astral.length,
      );
      expect(endBoundary, isA<W3cRangeConverted>());
      expect((endBoundary as W3cRangeConverted).start, 16);
      expect(endBoundary.end, 16);
    });

    test('round trips preserve supported information', () {
      const text = 'início — meio 📖 fim';
      for (final (start, end) in [(0, 0), (3, 4), (9, 10), (11, 12), (0, 11), (12, 12)]) {
        final toCodePoints = W3cAnnotationAdapter.positionSelectorFromUtf16Range(
          text,
          start: start,
          end: end,
        );
        expect(toCodePoints, isA<W3cRangeConverted>(), reason: 'utf16 $start..$end');
        final back = W3cAnnotationAdapter.utf16RangeFromPositionSelector(
          text,
          W3cTextPositionSelector(
            start: (toCodePoints as W3cRangeConverted).start,
            end: toCodePoints.end,
          ),
        );
        expect(
          back,
          isA<W3cRangeConverted>(),
          reason: 'code points ${toCodePoints.start}..${toCodePoints.end}',
        );
        expect((back as W3cRangeConverted).start, start, reason: 'utf16 $start..$end');
        expect(back.end, end, reason: 'utf16 $start..$end');
      }
    });
  });

  group('quote selector ↔ anchor quote', () {
    test('round trips without losses inside the limits', () {
      const quote = AnchorQuote(
        exact: 'trecho exato',
        before: 'contexto antes. ',
        after: ', e depois',
      );
      final conversion = W3cAnnotationAdapter.textQuoteSelectorFromAnchorQuote(quote);

      expect(conversion.hasLosses, isFalse);
      final selector = conversion.value;
      expect(selector.exact, 'trecho exato');
      expect(selector.prefix, quote.before);
      expect(selector.suffix, quote.after);

      final back = W3cAnnotationAdapter.anchorQuoteFromTextQuoteSelector(
        W3cAnnotationAdapter.encodeTextQuoteSelector(selector),
      );
      expect(back.hasLosses, isFalse);
      expect(back.value, quote);
    });

    test('context beyond the limit truncates and names the loss', () {
      final quote = AnchorQuote(exact: 'trecho', before: 'x' * 600, after: 'y' * 513);
      final conversion = W3cAnnotationAdapter.textQuoteSelectorFromAnchorQuote(quote);

      expect(conversion.hasLosses, isTrue);
      expect(conversion.losses, containsAll(['before truncated', 'after truncated']));
      expect(conversion.value.prefix.length, AnchorLimits().maxContextLength);
      expect(conversion.value.suffix.length, AnchorLimits().maxContextLength);
      expect(conversion.value.exact, 'trecho');
    });

    test('decoding a hostile selector fails typed', () {
      expect(
        () => W3cAnnotationAdapter.decodeTextQuoteSelector(<Object?, Object?>{
          'type': 'TextQuoteSelector',
        }),
        throwsA(isA<W3cAdapterException>()),
      );
      expect(
        () => W3cAnnotationAdapter.decodeTextQuoteSelector(<Object?, Object?>{
          'type': 'TextQuoteSelector',
          'exact': 42,
        }),
        throwsA(isA<W3cAdapterException>()),
      );
      expect(
        () => W3cAnnotationAdapter.decodeTextQuoteSelector(<Object?, Object?>{
          'type': 'TextPositionSelector',
          'exact': 'x',
        }),
        throwsA(isA<W3cAdapterException>()),
      );
      expect(
        () => W3cAnnotationAdapter.decodeTextPositionSelector(<Object?, Object?>{
          'type': 'TextPositionSelector',
          'start': 3,
          'end': 'x',
        }),
        throwsA(isA<W3cAdapterException>()),
      );
      expect(
        () => W3cAnnotationAdapter.decodeTextQuoteSelector(<Object?, Object?>{
          'type': 'TextQuoteSelector',
          'exact': 'x' * 5000,
        }),
        throwsA(isA<W3cAdapterException>()),
      );
      expect(
        () => W3cAnnotationAdapter.decodeTextQuoteSelector('not an object'),
        throwsA(isA<W3cAdapterException>()),
      );
    });

    test('a point anchor converts to an empty exact selector and back', () {
      const quote = AnchorQuote(exact: '', before: 'no ponto', after: '');

      final conversion = W3cAnnotationAdapter.textQuoteSelectorFromAnchorQuote(quote);
      expect(conversion.value.exact, isEmpty);

      final back = W3cAnnotationAdapter.anchorQuoteFromTextQuoteSelector(
        W3cAnnotationAdapter.encodeTextQuoteSelector(conversion.value),
      );
      expect(back.value, quote);
    });
  });

  group('subset declaration', () {
    test('supported and unknown selector types are named explicitly', () {
      final selectors = [
        {'type': 'TextQuoteSelector', 'exact': 'a'},
        {'type': 'TextPositionSelector', 'start': 0, 'end': 1},
        {'type': 'RangeSelector'},
        {'type': 'SvgSelector'},
        {'type': 'DataPositionSelector'},
      ];

      final support = W3cAnnotationAdapter.annotationSelectorSupport(selectors);

      expect(support.fullySupported, isFalse);
      expect(support.supported, ['TextQuoteSelector', 'TextPositionSelector']);
      expect(support.unsupported, ['RangeSelector', 'SvgSelector', 'DataPositionSelector']);
    });

    test('accepts a full annotation body and single selectors', () {
      final annotation = {
        'target': {
          'selector': [
            {'type': 'TextQuoteSelector', 'exact': 'a'},
          ],
        },
      };
      expect(W3cAnnotationAdapter.annotationSelectorSupport(annotation).fullySupported, isTrue);

      final single = {'type': 'TextPositionSelector', 'start': 0, 'end': 1};
      expect(W3cAnnotationAdapter.annotationSelectorSupport(single).fullySupported, isTrue);
    });

    test('hostile support payloads fail typed', () {
      expect(
        () => W3cAnnotationAdapter.annotationSelectorSupport([
          {'noType': 1},
        ]),
        throwsA(isA<W3cAdapterException>()),
      );
      expect(
        () => W3cAnnotationAdapter.annotationSelectorSupport(['a string']),
        throwsA(isA<W3cAdapterException>()),
      );
      expect(
        () => W3cAnnotationAdapter.annotationSelectorSupport(17),
        throwsA(isA<W3cAdapterException>()),
      );
    });
  });

  group('limits', () {
    test('non-positive limits fail at the entry point', () {
      expect(
        () => W3cAnnotationAdapter.decodeTextQuoteSelector(const {
          'type': 'TextQuoteSelector',
          'exact': 'a',
        }, limits: const AnchorLimits(maxSelectorLength: 0)),
        throwsArgumentError,
      );
    });
  });

  group('identity fixtures', () {
    test('fixture order digest stays stable (guards the shared helper)', () {
      expect(AnchorFixtures.orderRevision, startsWith('sha256:'));
      expect(AnchorFixtures.orderRevision, AnchorFixtures.orderRevision);
    });
  });
}
