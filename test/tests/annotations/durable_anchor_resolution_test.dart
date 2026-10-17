import 'package:test/test.dart';
import 'package:unseal/src/features/annotations/durable/anchor_limits.dart';
import 'package:unseal/src/features/annotations/durable/anchor_resolution.dart';
import 'package:unseal/src/features/annotations/durable/annotation_anchor.dart';
import 'package:unseal/src/features/annotations/durable/durable_annotations.dart';
import 'package:unseal/src/foundation/text/canonical_text_snapshot.dart';
import 'package:unseal/src/foundation/text/revision_digest.dart';
import 'package:unseal/src/foundation/text/section_occurrence.dart';

import '../../support/anchor_fixtures.dart';

/// Rebuilds an anchor's parts for hostile-input cases the public
/// capture refuses to produce.
AnnotationAnchor rebuilt(
  final AnnotationAnchor anchor, {
  final int? start,
  final int? end,
  final String? before,
  final String? after,
}) {
  return AnnotationAnchor.parts(
    identity: anchor.identity,
    occurrence: anchor.occurrence,
    profile: anchor.profile,
    textRevision: anchor.textRevision,
    start: start ?? anchor.start,
    end: end ?? anchor.end,
    quote: AnchorQuote(
      exact: anchor.quote.exact,
      before: before ?? anchor.quote.before,
      after: after ?? anchor.quote.after,
    ),
    annotationId: anchor.annotationId,
  );
}

void main() {
  const chapter1 =
      'O capitão marinhou ao norte, e a tripulação duvidou do '
      'rumo, mas a estrela fixa guiou a nau até o porto de vidro.';
  const chapter2 =
      'No diário do imediato restou uma linha: a estrela fixa '
      'guiou a nau, e ninguém perguntou como.';
  // The corrected edition fixes one word ("guiou" → "levou") and
  // re-wraps nothing.
  const corrected1 =
      'O capitão marinhou ao norte, e a tripulação duvidou do '
      'rumo, mas a estrela fixa levou a nau até o porto de vidro.';
  // The reordered edition: chapter 2 comes first, chapter 1 second.
  const reordered1 = chapter2;
  const reordered2 = chapter1;

  group('verified reuse (same revision)', () {
    test('resolves exactly through the identity tuple', () {
      final identity = AnchorFixtures.verifiedIdentity();
      final targets = [
        AnchorFixtures.snapshot(chapter1, sectionIndex: 0, identity: identity),
        AnchorFixtures.snapshot(chapter2, sectionIndex: 1, identity: identity),
      ];
      final (start, end) = AnchorFixtures.spanOf(chapter1, 'estrela fixa guiou a nau');
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: start,
        end: end,
        identity: identity,
      );

      final resolution = DurableAnnotations.resolve(anchor: anchor, targets: targets);

      expect(resolution, isA<AnchorResolved>());
      final resolved = resolution as AnchorResolved;
      expect(resolved.verified, isTrue);
      expect(resolved.basis, AnchorMatchBasis.identityReuse);
      expect(resolved.range.snapshot, same(targets[0]));
      expect(resolved.range.start, start);
      expect(resolved.range.end, end);
      expect(resolved.range.text, 'estrela fixa guiou a nau');
    });

    test('a tampered anchor range fails typed against its own revision', () {
      final identity = AnchorFixtures.verifiedIdentity();
      final targets = [AnchorFixtures.snapshot(chapter1, sectionIndex: 0, identity: identity)];
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: 2,
        end: 10,
        identity: identity,
      );

      // Bounds beyond the section length: the parts constructor cannot
      // see the text, the resolution must.
      final outOfBounds = rebuilt(anchor, end: chapter1.length + 5);

      expect(
        DurableAnnotations.resolve(anchor: outOfBounds, targets: targets),
        isA<AnchorMissing>().having(
          (final outcome) => outcome.reason,
          'reason',
          AnchorMissingReason.anchorRangeOutOfBounds,
        ),
      );
    });
  });

  group('repetition and ambiguity', () {
    test('repeated phrase with identical context stays ambiguous', () {
      const text = 'eco eco eco eco';
      final anchor = AnchorFixtures.anchor(
        text,
        sectionIndex: 0,
        start: 0,
        end: 7,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      // The anchor keeps no distinguishing context, so the three
      // occurrences in the revised edition carry the same (empty)
      // surroundings.
      final bare = rebuilt(anchor, before: '', after: '');

      final resolution = DurableAnnotations.resolve(
        anchor: bare,
        targets: [
          AnchorFixtures.snapshot(
            text,
            sectionIndex: 0,
            identity: AnchorFixtures.revisedIdentity(),
          ),
        ],
        policy: AnchorPolicy.explicitMigration,
      );

      expect(resolution, isA<AnchorAmbiguous>());
      final ambiguous = resolution as AnchorAmbiguous;
      expect(ambiguous.basis, AnchorMatchBasis.exact);
      expect(ambiguous.candidates, hasLength(3));
      expect(ambiguous.truncated, isFalse);
      // Candidates stay in reading order; the earlier one never wins.
      expect(ambiguous.candidates.map((final candidate) => candidate.range.start), [0, 4, 8]);
    });

    test('distinct context breaks the tie toward the right occurrence', () {
      final identity = AnchorFixtures.verifiedIdentity();
      final (start, end) = AnchorFixtures.spanOf(chapter2, 'estrela fixa');
      final anchor = AnchorFixtures.anchor(
        chapter2,
        sectionIndex: 1,
        start: start,
        end: end,
        identity: identity,
      );
      final revised = AnchorFixtures.revisedIdentity();
      final revisedTargets = [
        AnchorFixtures.snapshot(chapter1, sectionIndex: 0, identity: revised),
        AnchorFixtures.snapshot(chapter2, sectionIndex: 1, identity: revised),
      ];

      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: revisedTargets,
        policy: AnchorPolicy.explicitMigration,
      );

      expect(resolution, isA<AnchorResolved>());
      final resolved = resolution as AnchorResolved;
      expect(resolved.verified, isFalse);
      expect(resolved.basis, AnchorMatchBasis.exact);
      expect(resolved.range.snapshot, same(revisedTargets[1]));
      expect(resolved.range.text, 'estrela fixa');
    });

    test('candidate lists cap at the limit and report truncation', () {
      const text =
          'eco eco eco eco eco eco eco eco eco eco eco eco eco eco '
          'eco eco eco eco eco eco'; // 20 occurrences of "eco".
      final anchor = AnchorFixtures.anchor(
        text,
        sectionIndex: 0,
        start: 0,
        end: 3,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final bare = rebuilt(anchor, before: '', after: '');

      final resolution = DurableAnnotations.resolve(
        anchor: bare,
        targets: [
          AnchorFixtures.snapshot(
            text,
            sectionIndex: 0,
            identity: AnchorFixtures.revisedIdentity(),
          ),
        ],
        policy: AnchorPolicy.explicitMigration,
        limits: const AnchorLimits(maxCandidates: 5),
      );

      expect(resolution, isA<AnchorAmbiguous>());
      final ambiguous = resolution as AnchorAmbiguous;
      expect(ambiguous.candidates, hasLength(5));
      expect(ambiguous.truncated, isTrue);
    });
  });

  group('revised editions', () {
    test('default policy reports incompatibleRevision, never a guess', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: chapter1.indexOf('estrela fixa'),
        end: chapter1.indexOf('estrela fixa') + 12,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final revisedTargets = [
        AnchorFixtures.snapshot(
          chapter1,
          sectionIndex: 0,
          identity: AnchorFixtures.revisedIdentity(),
        ),
      ];

      final resolution = DurableAnnotations.resolve(anchor: anchor, targets: revisedTargets);

      expect(resolution, isA<AnchorIncompatibleRevision>());
      final mismatch = resolution as AnchorIncompatibleRevision;
      expect(mismatch.kind, AnchorIncompatibilityKind.revisionMismatch);
      expect(mismatch.differingFields, contains('sourceRevision'));
    });

    test('corrected edition resolves through the bounded fuzzy pass', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: AnchorFixtures.spanOf(chapter1, 'a estrela fixa guiou a nau').$1,
        end: AnchorFixtures.spanOf(chapter1, 'a estrela fixa guiou a nau').$2,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final correctedTargets = [
        AnchorFixtures.snapshot(
          corrected1,
          sectionIndex: 0,
          identity: AnchorFixtures.revisedIdentity(),
        ),
      ];

      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: correctedTargets,
        policy: AnchorPolicy.explicitMigration,
      );

      expect(resolution, isA<AnchorResolved>());
      final resolved = resolution as AnchorResolved;
      expect(resolved.basis, AnchorMatchBasis.fuzzy);
      expect(resolved.verified, isFalse);
      expect(resolved.editDistance, 3);
      expect(resolved.range.text, 'a estrela fixa levou a nau');
    });

    test('reordered chapters resolve through the new reading order', () {
      final anchor = AnchorFixtures.anchor(
        chapter2,
        sectionIndex: 1,
        start: AnchorFixtures.spanOf(chapter2, 'estrela fixa').$1,
        end: AnchorFixtures.spanOf(chapter2, 'estrela fixa').$2,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      // The reordered edition: chapter 2 first, chapter 1 second — its
      // reading-order digest differs from the capture edition's.
      const reorderedOrder = [('chapter-2.xhtml', true), ('chapter-1.xhtml', true)];
      final reorderedIdentity = AnchorFixtures.verifiedIdentity(
        sourceRevision: 'sha256:${'1a' * 32}',
      );
      final reorderedRevision = RevisionDigest.readingOrderRevision(reorderedOrder);
      CanonicalTextSnapshot reorderedSnapshot(
        final String text,
        final int sectionIndex,
        final String path,
      ) {
        return CanonicalTextSnapshot(
          identity: reorderedIdentity,
          occurrence: SectionOccurrence(
            sectionIndex: sectionIndex,
            resourcePath: path,
            readingOrderRevision: reorderedRevision,
          ),
          profile: AnchorFixtures.documentProfile,
          text: text,
        );
      }

      final reorderedTargets = [
        reorderedSnapshot(reordered1, 0, 'chapter-2.xhtml'),
        reorderedSnapshot(reordered2, 1, 'chapter-1.xhtml'),
      ];

      final defaultResolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: reorderedTargets,
      );
      expect(defaultResolution, isA<AnchorIncompatibleRevision>());
      expect(
        (defaultResolution as AnchorIncompatibleRevision).differingFields,
        containsAll(['readingOrderRevision', 'sourceRevision']),
      );

      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: reorderedTargets,
        policy: AnchorPolicy.explicitMigration,
      );

      expect(resolution, isA<AnchorResolved>());
      final resolved = resolution as AnchorResolved;
      expect(resolved.range.snapshot.occurrence.sectionIndex, 0);
      expect(resolved.range.text, 'estrela fixa');
    });

    test('re-wrapped text resolves through the whitespace-normalized pass', () {
      const wrapped = 'entre um ato\ne outro ato, o público\nespera';
      const rewrapped = 'entre um ato e outro ato, o público espera';
      final anchor = AnchorFixtures.anchor(
        wrapped,
        sectionIndex: 0,
        start: AnchorFixtures.spanOf(wrapped, 'um ato\ne outro ato').$1,
        end: AnchorFixtures.spanOf(wrapped, 'um ato\ne outro ato').$2,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final targets = [
        AnchorFixtures.snapshot(
          rewrapped,
          sectionIndex: 0,
          identity: AnchorFixtures.revisedIdentity(),
        ),
      ];

      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: targets,
        policy: AnchorPolicy.explicitMigration,
      );

      expect(resolution, isA<AnchorResolved>());
      final resolved = resolution as AnchorResolved;
      expect(resolved.basis, AnchorMatchBasis.whitespaceNormalized);
      expect(resolved.range.text, 'um ato e outro ato');
    });

    test('removed target is missing', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: AnchorFixtures.spanOf(chapter1, 'porto de vidro').$1,
        end: AnchorFixtures.spanOf(chapter1, 'porto de vidro').$2,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final targets = [
        AnchorFixtures.snapshot(
          chapter2,
          sectionIndex: 0,
          identity: AnchorFixtures.revisedIdentity(),
        ),
      ];

      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: targets,
        policy: AnchorPolicy.explicitMigration,
      );

      expect(resolution, isA<AnchorMissing>());
      expect((resolution as AnchorMissing).reason, AnchorMissingReason.quoteNotFound);
    });

    test('empty targets are missing', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: 0,
        end: 4,
        identity: AnchorFixtures.verifiedIdentity(),
      );

      expect(
        DurableAnnotations.resolve(anchor: anchor, targets: const []),
        isA<AnchorMissing>().having(
          (final outcome) => outcome.reason,
          'reason',
          AnchorMissingReason.noTargets,
        ),
      );
    });

    test('point anchors have no migration evidence', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: 12,
        end: 12,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final targets = [
        AnchorFixtures.snapshot(
          corrected1,
          sectionIndex: 0,
          identity: AnchorFixtures.revisedIdentity(),
        ),
      ];

      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: targets,
        policy: AnchorPolicy.explicitMigration,
      );

      expect(resolution, isA<AnchorMissing>());
      expect((resolution as AnchorMissing).reason, AnchorMissingReason.noQuoteEvidence);
    });
  });

  group('unknown identity', () {
    test('another publication never migrates by proximity', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: AnchorFixtures.spanOf(chapter1, 'estrela fixa').$1,
        end: AnchorFixtures.spanOf(chapter1, 'estrela fixa').$2,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      // The same text, but the target declares another publication.
      final otherTargets = [
        AnchorFixtures.snapshot(
          chapter1,
          sectionIndex: 0,
          identity: AnchorFixtures.otherPublicationIdentity(),
        ),
      ];

      for (final policy in AnchorPolicy.values.take(2)) {
        final resolution = DurableAnnotations.resolve(
          anchor: anchor,
          targets: otherTargets,
          policy: policy,
        );

        expect(resolution, isA<AnchorIncompatibleRevision>());
        final mismatch = resolution as AnchorIncompatibleRevision;
        expect(mismatch.kind, AnchorIncompatibilityKind.publicationMismatch);
        expect(mismatch.differingFields, ['publicationId']);
      }
    });

    test('explicit context recovery resolves unverified', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: AnchorFixtures.spanOf(chapter1, 'estrela fixa').$1,
        end: AnchorFixtures.spanOf(chapter1, 'estrela fixa').$2,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final otherTargets = [
        AnchorFixtures.snapshot(
          chapter1,
          sectionIndex: 0,
          identity: AnchorFixtures.otherPublicationIdentity(),
        ),
      ];

      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: otherTargets,
        policy: AnchorPolicy.contextRecovery,
      );

      expect(resolution, isA<AnchorResolved>());
      final resolved = resolution as AnchorResolved;
      expect(resolved.verified, isFalse);
      expect(resolved.range.text, 'estrela fixa');
    });

    test('unverified identity does not upgrade to verified reuse', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: AnchorFixtures.spanOf(chapter1, 'estrela fixa').$1,
        end: AnchorFixtures.spanOf(chapter1, 'estrela fixa').$2,
        identity: AnchorFixtures.unverifiedIdentity,
      );
      final verifiedTargets = [
        AnchorFixtures.snapshot(
          chapter1,
          sectionIndex: 0,
          identity: AnchorFixtures.verifiedIdentity(),
        ),
      ];

      final resolution = DurableAnnotations.resolve(anchor: anchor, targets: verifiedTargets);

      expect(resolution, isA<AnchorIncompatibleRevision>());
      final mismatch = resolution as AnchorIncompatibleRevision;
      expect(mismatch.kind, AnchorIncompatibilityKind.revisionMismatch);
      expect(mismatch.differingFields, containsAll(['sourceRevision', 'sourceEvidence']));
    });
  });

  group('profile mismatches', () {
    test('a different extraction profile is an incompatibility, then migrates', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: AnchorFixtures.spanOf(chapter1, 'estrela fixa').$1,
        end: AnchorFixtures.spanOf(chapter1, 'estrela fixa').$2,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final otherProfileTargets = [
        AnchorFixtures.snapshot(
          chapter1,
          sectionIndex: 0,
          identity: AnchorFixtures.revisedIdentity(),
          profile: AnchorFixtures.otherProfile,
        ),
      ];

      expect(
        DurableAnnotations.resolve(anchor: anchor, targets: otherProfileTargets),
        isA<AnchorIncompatibleRevision>(),
      );

      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: otherProfileTargets,
        policy: AnchorPolicy.explicitMigration,
      );

      expect(resolution, isA<AnchorResolved>());
      expect((resolution as AnchorResolved).range.text, 'estrela fixa');
    });
  });

  group('limits and work', () {
    test('an exhausted scan budget reports unsupported, not missing', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: AnchorFixtures.spanOf(chapter1, 'porto de vidro').$1,
        end: AnchorFixtures.spanOf(chapter1, 'porto de vidro').$2,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final targets = [
        AnchorFixtures.snapshot(
          chapter2,
          sectionIndex: 0,
          identity: AnchorFixtures.revisedIdentity(),
        ),
      ];

      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: targets,
        policy: AnchorPolicy.explicitMigration,
        limits: const AnchorLimits(maxScanCodeUnits: 4),
      );

      expect(resolution, isA<AnchorUnsupported>());
      expect((resolution as AnchorUnsupported).reason, AnchorUnsupportedReason.scanWorkExceeded);
    });

    test('a budget just above the text size still scans', () {
      final anchor = AnchorFixtures.anchor(
        chapter1,
        sectionIndex: 0,
        start: AnchorFixtures.spanOf(chapter1, 'estrela fixa').$1,
        end: AnchorFixtures.spanOf(chapter1, 'estrela fixa').$2,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      final targets = [
        AnchorFixtures.snapshot(
          chapter1,
          sectionIndex: 0,
          identity: AnchorFixtures.revisedIdentity(),
        ),
      ];

      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: targets,
        policy: AnchorPolicy.explicitMigration,
        limits: AnchorLimits(maxScanCodeUnits: chapter1.length * 2),
      );

      expect(resolution, isA<AnchorResolved>());
    });

    test('quotes beyond the fuzzy bound skip that pass and say so', () {
      // A genuinely long quote exercises the skip path.
      final longText = '${'palavra ' * 40}X${' palavra ' * 40}';
      final anchor = AnchorFixtures.anchor(
        longText,
        sectionIndex: 0,
        start: 0,
        end: 300,
        identity: AnchorFixtures.verifiedIdentity(),
      );
      expect(anchor.quote.exact.length, greaterThanOrEqualTo(AnchorLimits().maxFuzzyQuoteLength));

      final targets = [
        AnchorFixtures.snapshot(
          'outro texto inteiro, sem a citação longa que se busca aqui',
          sectionIndex: 0,
          identity: AnchorFixtures.revisedIdentity(),
        ),
      ];

      final resolution = DurableAnnotations.resolve(
        anchor: anchor,
        targets: targets,
        policy: AnchorPolicy.explicitMigration,
      );

      expect(resolution, isA<AnchorMissing>());
      expect((resolution as AnchorMissing).fuzzySkipped, isTrue);
    });
  });
}
