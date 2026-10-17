import 'package:unseal/src/features/annotations/durable/anchor_limits.dart';
import 'package:unseal/src/features/annotations/durable/annotation_anchor.dart';
import 'package:unseal/src/features/annotations/durable/durable_annotations.dart'
    show documentTextProfile;
import 'package:unseal/src/foundation/text/canonical_text_range.dart';
import 'package:unseal/src/foundation/text/canonical_text_snapshot.dart';
import 'package:unseal/src/foundation/text/publication_revision.dart';
import 'package:unseal/src/foundation/text/revision_digest.dart';
import 'package:unseal/src/foundation/text/section_occurrence.dart';
import 'package:unseal/src/foundation/text/text_profile.dart';

/// Shared fixtures for the durable-anchor suites: verified and
/// in-memory identities, per-section snapshots over explicit strings,
/// and the reading-order digest that binds occurrences together.
abstract final class AnchorFixtures {
  const AnchorFixtures._();

  /// The reading order every fixture occurrence binds to: two
  /// chapters, in this order.
  static const readingOrder = <(String, bool)>[
    ('chapter-1.xhtml', true),
    ('chapter-2.xhtml', true),
  ];

  /// The digest of [readingOrder].
  static final String orderRevision = RevisionDigest.readingOrderRevision(readingOrder);

  /// The verified identity: a parser-computed source revision.
  static PublicationRevision verifiedIdentity({final String? sourceRevision}) {
    return PublicationRevision(
      publicationId: 'test:edition-a',
      sourceRevision: sourceRevision ?? 'sha256:${'ab' * 32}',
      sourceEvidence: SourceEvidence.sha256,
    );
  }

  /// A second verified revision of the same publication: the source
  /// bytes changed, the work did not.
  static PublicationRevision revisedIdentity() {
    return PublicationRevision(
      publicationId: 'test:edition-a',
      sourceRevision: 'sha256:${'cd' * 32}',
      sourceEvidence: SourceEvidence.sha256,
    );
  }

  /// Another publication entirely — similar metadata, different work.
  static PublicationRevision otherPublicationIdentity() {
    return PublicationRevision(
      publicationId: 'test:edition-b',
      sourceRevision: 'sha256:${'ef' * 32}',
      sourceEvidence: SourceEvidence.sha256,
    );
  }

  /// The in-memory identity: nothing verified, nothing claimed.
  static PublicationRevision get unverifiedIdentity =>
      PublicationRevision(publicationId: 'test:edition-a');

  /// The generic document-text profile, the same constant the public
  /// capture uses.
  static TextProfile get documentProfile => documentTextProfile;

  /// A different profile — what a reflow plan change produces.
  static TextProfile get otherProfile => TextProfile.of(
    algorithm: 'document-text',
    options: const {'wrap': 'hard'},
    planRevision: RevisionDigest.textRevision('unseal document-text extraction 2'),
  );

  /// The snapshot of section [sectionIndex] (of [AnchorFixtures
  /// .readingOrder]) over [text], under [identity].
  static CanonicalTextSnapshot snapshot(
    final String text, {
    required final int sectionIndex,
    required final PublicationRevision identity,
    TextProfile? profile,
  }) {
    return CanonicalTextSnapshot(
      identity: identity,
      occurrence: SectionOccurrence(
        sectionIndex: sectionIndex,
        resourcePath: readingOrder[sectionIndex].$1,
        readingOrderRevision: orderRevision,
      ),
      profile: profile ?? documentProfile,
      text: text,
    );
  }

  /// Captures the anchor of `text`'s [start]..[end] in section
  /// [sectionIndex], under [identity].
  static AnnotationAnchor anchor(
    final String text, {
    required final int sectionIndex,
    required final int start,
    required final int end,
    required final PublicationRevision identity,
    TextProfile? profile,
    final AnchorLimits limits = const AnchorLimits(),
  }) {
    return AnnotationAnchor.capture(
      snapshot: snapshot(text, sectionIndex: sectionIndex, identity: identity, profile: profile),
      start: start,
      end: end,
      limits: limits,
    );
  }

  /// The first occurrence of [needle] in [text], failing the test
  /// suite when absent.
  static (int, int) spanOf(final String text, final String needle) {
    final start = text.indexOf(needle);
    if (start < 0) {
      throw StateError('fixture needle not present: $needle');
    }

    return (start, start + needle.length);
  }

  /// The range [start]..[end] over [snapshot].
  static CanonicalTextRange range(
    final CanonicalTextSnapshot snapshot,
    final int start,
    final int end,
  ) {
    return CanonicalTextRange(snapshot: snapshot, start: start, end: end);
  }
}
