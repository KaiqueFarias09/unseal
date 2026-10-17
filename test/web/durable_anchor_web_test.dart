@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:unseal/src/features/annotations/durable/anchor_codec.dart';
import 'package:unseal/src/features/annotations/durable/anchor_limits.dart';
import 'package:unseal/src/features/annotations/durable/anchor_resolution.dart';
import 'package:unseal/src/features/annotations/durable/annotation_anchor.dart';
import 'package:unseal/src/features/annotations/durable/durable_annotations.dart';
import 'package:unseal/src/features/annotations/durable/w3c_annotation_adapter.dart';
import 'package:unseal/src/foundation/text/canonical_text_snapshot.dart';
import 'package:unseal/src/foundation/text/publication_revision.dart';
import 'package:unseal/src/foundation/text/revision_digest.dart';
import 'package:unseal/src/foundation/text/section_occurrence.dart';
import 'package:unseal/src/foundation/text/text_profile.dart';

import '../support/text_identity_vectors.dart';

/// Runs the durable-anchor core inside Chrome: capture, resolve and
/// the W3C conversions are pure Dart over UTF-16 strings, so the
/// browser must produce the same digests, the same ambiguity verdicts
/// and the same unrepresentable-boundary refusals the VM suite pins —
/// astral and combining text included.
void main() {
  const order = [('chapter-1.xhtml', true), ('chapter-2.xhtml', true)];
  final orderRevision = RevisionDigest.readingOrderRevision(order);
  final identity = PublicationRevision(
    publicationId: 'web:edition',
    sourceRevision: TextIdentityVectors.astralRevision,
    sourceEvidence: SourceEvidence.sha256,
  );

  CanonicalTextSnapshot snapshotOf(final String text, final int sectionIndex) {
    return CanonicalTextSnapshot(
      identity: identity,
      occurrence: SectionOccurrence(
        sectionIndex: sectionIndex,
        resourcePath: order[sectionIndex].$1,
        readingOrderRevision: orderRevision,
      ),
      profile: TextProfile.of(
        algorithm: 'document-text',
        options: const {},
        planRevision: RevisionDigest.textRevision('unseal document-text extraction 1'),
      ),
      text: text,
    );
  }

  test('capture reuses the pinned astral digest inside the browser', () {
    // The anchor's textRevision must equal the P0 vector's digest for
    // the same astral text.
    final snapshot = snapshotOf(TextIdentityVectors.astralText, 0);
    final anchor = AnnotationAnchor.capture(
      snapshot: snapshot,
      start: 6,
      end: 10, // The 📖 surrogate pair, two code units.
    );

    expect(snapshot.textRevision, TextIdentityVectors.astralRevision);
    expect(anchor.textRevision, TextIdentityVectors.astralRevision);
    expect(anchor.quote.exact, snapshot.text.substring(6, 10));
    expect(anchor.isExportable, isTrue);
  });

  test('resolution migrates across a revision exactly as the VM does', () {
    final anchor = AnnotationAnchor.capture(
      snapshot: snapshotOf('capítulo com citação astral 📖 no meio do texto', 0),
      start: 14,
      end: 32,
    );

    final revisedIdentity = PublicationRevision(
      publicationId: 'web:edition',
      sourceRevision: 'sha256:${'9a' * 32}',
      sourceEvidence: SourceEvidence.sha256,
    );
    final originalSnap = snapshotOf('capítulo com citação astral 📖 no meio do texto', 0);
    final revisedSnapshot = CanonicalTextSnapshot(
      identity: revisedIdentity,
      occurrence: originalSnap.occurrence,
      profile: originalSnap.profile,
      text: originalSnap.text,
    );

    final strict = DurableAnnotations.resolve(anchor: anchor, targets: [revisedSnapshot]);
    expect(strict, isA<AnchorIncompatibleRevision>());

    final resolved =
        DurableAnnotations.resolve(
              anchor: anchor,
              targets: [revisedSnapshot],
              policy: AnchorPolicy.explicitMigration,
            )
            as AnchorResolved;

    expect(resolved.verified, isFalse);
    expect(resolved.range.text, anchor.quote.exact);
    expect(resolved.range.text.contains('📖'), isTrue);
  });

  test('repeated phrases stay ambiguous in the browser too', () {
    const text = 'eco eco eco eco';
    final anchor = AnnotationAnchor.capture(snapshot: snapshotOf(text, 0), start: 0, end: 7);
    final bare = AnnotationAnchor.parts(
      identity: anchor.identity,
      occurrence: anchor.occurrence,
      profile: anchor.profile,
      textRevision: anchor.textRevision,
      start: anchor.start,
      end: anchor.end,
      quote: AnchorQuote(exact: anchor.quote.exact),
    );
    final revisedIdentity = PublicationRevision(
      publicationId: 'web:repeat',
      sourceRevision: 'host:v2',
      sourceEvidence: SourceEvidence.host,
    );
    final target = CanonicalTextSnapshot(
      identity: revisedIdentity,
      occurrence: anchor.occurrence,
      profile: anchor.profile,
      text: text,
    );

    final resolution = DurableAnnotations.resolve(
      anchor: bare,
      targets: [target],
      policy: AnchorPolicy.contextRecovery,
    );

    expect(resolution, isA<AnchorAmbiguous>());
    expect((resolution as AnchorAmbiguous).candidates, hasLength(3));
  });

  test('W3C conversions refuse mid-surrogate bounds without shifting', () {
    const astral = 'livro 📖 e nota 𝄞';

    final converted = W3cAnnotationAdapter.positionSelectorFromUtf16Range(astral, start: 6, end: 8);
    expect(converted, isA<W3cRangeConverted>());
    expect((converted as W3cRangeConverted).end, 7);

    final unconvertible = W3cAnnotationAdapter.positionSelectorFromUtf16Range(
      astral,
      start: 6,
      end: 7,
    );
    expect(unconvertible, isA<W3cRangeUnconverted>());
    expect(
      (unconvertible as W3cRangeUnconverted).reason,
      W3cConversionUnsupportedReason.midSurrogatePair,
    );

    final back = W3cAnnotationAdapter.utf16RangeFromPositionSelector(
      astral,
      const W3cTextPositionSelector(start: 6, end: 7),
    );
    expect((back as W3cRangeConverted).start, 6);
    expect(back.end, 8);
  });

  test('the anchor codec round-trips through the browser', () {
    final snapshot = snapshotOf(TextIdentityVectors.astralText, 0);
    final anchor = AnnotationAnchor.capture(snapshot: snapshot, start: 0, end: 12);

    expect(decodeAnchor(encodeAnchor(anchor)), anchor);
  });

  test('limits stay enforced on the web', () {
    final snapshot = snapshotOf(TextIdentityVectors.astralText, 0);
    expect(
      () => AnnotationAnchor.capture(
        snapshot: snapshot,
        start: 0,
        end: 4,
        limits: const AnchorLimits(maxQuoteLength: 0),
      ),
      throwsArgumentError,
    );
    expect(() => decodeAnchor(const <String, Object?>{}), throwsA(isA<AnchorCodecException>()));
  });
}
