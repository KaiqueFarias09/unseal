import 'package:test/test.dart';
import 'package:unseal/src/features/annotations/durable/anchor_codec.dart';
import 'package:unseal/src/features/annotations/durable/anchor_limits.dart';
import 'package:unseal/src/features/annotations/durable/annotation_anchor.dart';

import '../../support/anchor_fixtures.dart';

void main() {
  const chapter1 =
      'No princípio era o Verbo. O verbo estava com Deus, e a '
      'citação continuava por parágrafos à frente, dando contexto de sobra '
      'para âncoras com contexto truncado e não truncado.';
  const chapter2 =
      'Segundo capítulo: o Verbo reaparece aqui no fim, e o '
      'resto é contexto diferente do primeiro capítulo.';

  group('anchor capture', () {
    test('captures identity, occurrence, revisions and bounded evidence', () {
      final (start, end) = AnchorFixtures.spanOf(chapter1, 'O verbo estava com Deus');
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: start,
        end: end,
        identity: AnchorFixtures.verifiedIdentity(),
      );

      expect(anchor.identity, AnchorFixtures.verifiedIdentity());
      expect(anchor.occurrence.sectionIndex, 0);
      expect(anchor.occurrence.resourcePath, 'chapter-1.xhtml');
      expect(anchor.occurrence.readingOrderRevision, AnchorFixtures.orderRevision);
      expect(
        anchor.textRevision,
        AnchorFixtures.snapshot(
          chapter1,
          sectionIndex: 0,
          identity: AnchorFixtures.verifiedIdentity(),
        ).textRevision,
      );
      expect(anchor.start, start);
      expect(anchor.end, end);
      expect(anchor.quote.exact, 'O verbo estava com Deus');
      expect(anchor.quote.before, endsWith('Verbo. '));
      expect(anchor.quote.after, startsWith(', e a'));
      expect(anchor.isExportable, isTrue);
    });

    test('truncates context to the limit and keeps the exact quote whole', () {
      final (start, end) = AnchorFixtures.spanOf(chapter1, 'O verbo estava com Deus');
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: start,
        end: end,
        identity: AnchorFixtures.verifiedIdentity(),
        limits: const AnchorLimits(maxContextLength: 8),
      );

      expect(anchor.quote.before.length, lessThanOrEqualTo(8));
      expect(anchor.quote.after.length, lessThanOrEqualTo(8));
      expect(anchor.quote.exact, 'O verbo estava com Deus');
    });

    test('rejects bounds outside the snapshot', () {
      final identity = AnchorFixtures.verifiedIdentity();
      final snapshot = AnchorFixtures.snapshot(chapter1, sectionIndex: 0, identity: identity);

      expect(
        () => AnnotationAnchor.capture(snapshot: snapshot, start: -1, end: 3),
        throwsArgumentError,
      );
      expect(
        () => AnnotationAnchor.capture(snapshot: snapshot, start: 5, end: 4),
        throwsArgumentError,
      );
      expect(
        () => AnnotationAnchor.capture(snapshot: snapshot, start: 0, end: chapter1.length + 1),
        throwsArgumentError,
      );
    });

    test('rejects selections beyond the quote limit, with one just inside', () {
      final longText = 'a' * 5000;
      final identity = AnchorFixtures.verifiedIdentity();
      final snapshot = AnchorFixtures.snapshot(longText, sectionIndex: 0, identity: identity);

      // Immediately above the default limit.
      expect(
        () => AnnotationAnchor.capture(snapshot: snapshot, start: 0, end: 4097),
        throwsArgumentError,
      );
      // Immediately below it.
      final justInside = AnnotationAnchor.capture(snapshot: snapshot, start: 0, end: 4096);
      expect(justInside.quote.exact.length, 4096);

      // A raised limit accepts what the default refused.
      expect(
        () => AnnotationAnchor.capture(
          snapshot: snapshot,
          start: 0,
          end: 4097,
          limits: const AnchorLimits(maxQuoteLength: 4098),
        ),
        returnsNormally,
      );
    });

    test('captures point anchors with an empty exact quote', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: 3,
        end: 3,
        identity: AnchorFixtures.verifiedIdentity(),
      );

      expect(anchor.isPoint, isTrue);
      expect(anchor.quote.exact, isEmpty);
    });

    test('non-positive limits fail validation at the entry point', () {
      expect(() => AnchorLimits(maxCandidates: 0).requireValid(), throwsArgumentError);
      expect(() => AnchorLimits(maxScanCodeUnits: -1).requireValid(), throwsArgumentError);
      expect(
        () => AnnotationAnchor.capture(
          snapshot: AnchorFixtures.snapshot(
            chapter1,
            sectionIndex: 0,
            identity: AnchorFixtures.verifiedIdentity(),
          ),
          start: 0,
          end: 4,
          limits: const AnchorLimits(maxQuoteLength: 0),
        ),
        throwsArgumentError,
      );
    });
  });

  group('anchor codec', () {
    test('round trips a verified anchor losslessly', () {
      final (start, end) = AnchorFixtures.spanOf(chapter1, 'O verbo estava com Deus');
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: start,
        end: end,
        identity: AnchorFixtures.verifiedIdentity(),
        limits: const AnchorLimits(maxContextLength: 6),
      );

      final decoded = decodeAnchor(encodeAnchor(anchor));

      expect(decoded, anchor);
      expect(decoded.quote.before, anchor.quote.before);
      expect(decoded.quote.after, anchor.quote.after);
    });

    test('round trips through its JSON text', () {
      final (start, end) = AnchorFixtures.spanOf(chapter2, 'Verbo reaparece');
      final anchor = AnchorFixtures.anchor(
        chapter2,
        sectionIndex: 1,
        start: start,
        end: end,
        identity: AnchorFixtures.verifiedIdentity(),
      );

      expect(decodeAnchor(encodeAnchor(anchor)), anchor);
    });

    test('refuses to export an in-memory anchor', () {
      final (start, end) = AnchorFixtures.spanOf(chapter1, 'O verbo estava com Deus');
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: start,
        end: end,
        identity: AnchorFixtures.unverifiedIdentity,
      );

      expect(anchor.isExportable, isFalse);
      expect(() => encodeAnchor(anchor), throwsA(isA<AnchorCodecException>()));
    });

    test('carries point anchors as an empty exact of the same span', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: 10,
        end: 10,
        identity: AnchorFixtures.verifiedIdentity(),
      );

      expect(decodeAnchor(encodeAnchor(anchor)), anchor);
    });

    test('rejects unknown schema versions, unknown keys and malformed shapes', () {
      final (start, end) = AnchorFixtures.spanOf(chapter1, 'O verbo estava com Deus');
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: start,
        end: end,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final payload = encodeAnchor(anchor);

      Map<String, Object?> mutate(final void Function(Map<String, Object?> payload) change) {
        final copy = Map.of(payload);
        change(copy);

        return copy;
      }

      expect(
        () => decodeAnchor(mutate((final p) => p['anchorSchemaVersion'] = 2)),
        throwsA(isA<AnchorCodecException>()),
      );
      expect(() => decodeAnchor(<String, Object?>{}), throwsA(isA<AnchorCodecException>()));
      expect(
        () => decodeAnchor(mutate((final p) => p['surprise'] = 1)),
        throwsA(isA<AnchorCodecException>()),
      );
      expect(
        () => decodeAnchor(mutate((final p) => p['range'] = {'start': 9, 'end': 3})),
        throwsA(isA<AnchorCodecException>()),
      );
      expect(
        () => decodeAnchor(mutate((final p) => p['textRevision'] = 'md5:zz')),
        throwsA(isA<AnchorCodecException>()),
      );
      expect(
        () => decodeAnchor(mutate((final p) => p['range'] = {'start': start, 'end': end + 2})),
        throwsA(isA<AnchorCodecException>()),
      );
      expect(
        () => decodeAnchor(
          mutate(
            (final p) =>
                p['identity'] = Map.of(p['identity'] as Map)..['sourceEvidence'] = 'gut-feeling',
          ),
        ),
        throwsA(isA<AnchorCodecException>()),
      );
      expect(
        () => decodeAnchor(
          mutate(
            (final p) =>
                p['profile'] = Map.of(p['profile'] as Map)..['algorithm'] = 'rewritten-scanner',
          ),
        ),
        throwsA(isA<AnchorCodecException>()),
      );
      expect(() => decodeAnchor(42), throwsA(isA<AnchorCodecException>()));
      expect(() => decodeAnchor('{not json'), throwsA(isA<AnchorCodecException>()));
      expect(() => decodeAnchor('[1, 2]'), throwsA(isA<AnchorCodecException>()));
    });

    test('enforces payload and field limits on import', () {
      final (start, end) = AnchorFixtures.spanOf(chapter1, 'O verbo estava com Deus');
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: start,
        end: end,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final payload = encodeAnchor(anchor);

      expect(
        () => decodeAnchor(payload.toString(), limits: const AnchorLimits(maxPayloadCodeUnits: 16)),
        throwsA(isA<AnchorCodecException>()),
      );

      // Immediately above and below the context limit.
      Map<String, Object?> withContext(final String before) =>
          Map.of(payload)..['quote'] = {'exact': anchor.quote.exact, 'before': before, 'after': ''};
      expect(() => decodeAnchor(withContext('x' * 513)), throwsA(isA<AnchorCodecException>()));
      expect(decodeAnchor(withContext('x' * 512)), isA<AnnotationAnchor>());
    });
  });

  group('v1 isolation', () {
    test('the anchor wire is a distinct schema, not a v1 payload', () {
      final (start, end) = AnchorFixtures.spanOf(chapter1, 'O verbo estava com Deus');
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: start,
        end: end,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final payload = encodeAnchor(anchor);

      expect(payload.containsKey('formatVersion'), isFalse);
      expect(payload['anchorSchemaVersion'], 1);
    });
  });
}
