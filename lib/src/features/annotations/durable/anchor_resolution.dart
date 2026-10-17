import '../../../foundation/text/canonical_text_range.dart';
import 'anchor_limits.dart';

/// How far a resolution may reach beyond the anchor's own identity.
///
/// The default reuses verified positions only; the two wider policies
/// are explicit operations the consumer requests — nothing here
/// migrates or recovers a position on its own initiative.
enum AnchorPolicy {
  /// Resolve only through the full identity tuple: the target snapshot
  /// must be the same revision of the same publication the anchor was
  /// captured under. Any identity or revision difference reports
  /// [AnchorIncompatibleRevision] — never a proximity guess.
  verifiedReuse,

  /// Different revision, same publication: re-find the selection
  /// through its quote and context evidence. Similar metadata on
  /// another publication never migrates — a differing publication id
  /// stays incompatible.
  explicitMigration,

  /// Context recovery for anchors whose identity cannot be confirmed
  /// against the target (unknown identity, unverified revisions): the
  /// quote and context re-find the selection, and every outcome
  /// reports itself as not position-verified.
  contextRecovery,
}

/// What evidence backs a resolved or candidate position.
enum AnchorMatchBasis {
  /// The target snapshot's full identity tuple equals the anchor's and
  /// the carried quote re-verified against the target text — position
  /// reuse, verified.
  identityReuse,

  /// The exact quote text occurs (uniquely best) in the target text.
  exact,

  /// The whitespace-normalized quote occurs (uniquely best); the text
  /// re-wrapped around the selection.
  whitespaceNormalized,

  /// The quote matches within the bounded edit distance (a corrected
  /// edition); the outcome carries the measured distance.
  fuzzy,
}

/// Why a resolution found nothing.
enum AnchorMissingReason {
  /// No target snapshots were offered.
  noTargets,

  /// The anchor is a point selection: it has no quote to re-find, so
  /// only identity reuse can ever resolve it.
  noQuoteEvidence,

  /// The exact and whitespace-normalized scans found nothing and the
  /// fuzzy pass (when it ran) found nothing within its distance.
  quoteNotFound,

  /// The anchor's stored bounds fall outside the identity-matched
  /// target text — a corrupt or tampered anchor.
  anchorRangeOutOfBounds,

  /// The identity-matched target text no longer contains the carried
  /// quote at the stored bounds — the anchor's evidence contradicts
  /// the text its own digest pins.
  quoteMismatch,
}

/// Why a resolution could not complete.
enum AnchorUnsupportedReason {
  /// The scan budget ([AnchorLimits.maxScanCodeUnits] worth of code
  /// units) ran out before the target sections were fully searched.
  scanWorkExceeded,

  /// The fuzzy pass exhausted its gram-scan, verification, or
  /// candidate-window budget before all targets could be checked.
  fuzzyWorkExceeded,
}

/// Why the resolution reported an identity/revision incompatibility.
enum AnchorIncompatibilityKind {
  /// The target declares another publication id. Similar metadata
  /// never proves the same work; migration across publications is not
  /// an operation this API performs.
  publicationMismatch,

  /// Same publication, different revision: source revision, reading
  /// order, extraction profile or text revision disagree. The listed
  /// fields name the differences.
  revisionMismatch,
}

/// One re-found occurrence of the selection in a target snapshot.
final class AnchorCandidate {
  /// Creates a candidate.
  const AnchorCandidate({
    required this.range,
    required this.contextScore,
    required this.basis,
    this.editDistance,
  });

  /// The candidate's range, bound to the target snapshot.
  final CanonicalTextRange range;

  /// How much of the anchor's before/after context agrees around the
  /// occurrence (matched code units).
  final int contextScore;

  /// What evidence produced the candidate.
  final AnchorMatchBasis basis;

  /// The measured edit distance for a fuzzy candidate; null otherwise.
  final int? editDistance;

  @override
  String toString() =>
      'AnchorCandidate($range, context: $contextScore, basis: ${basis.name}'
      '${editDistance == null ? '' : ', distance: $editDistance'})';
}

/// The outcome of one resolution: exactly one of resolved, ambiguous,
/// missing, incompatibleRevision or unsupported.
sealed class AnchorResolution {
  const AnchorResolution();
}

/// The selection re-anchored to a target snapshot.
final class AnchorResolved extends AnchorResolution {
  /// Creates a resolved outcome.
  const AnchorResolved({
    required this.range,
    required this.basis,
    required this.verified,
    this.contextScore = 0,
    this.editDistance,
  });

  /// The selection's new range, bound to the resolved target snapshot.
  final CanonicalTextRange range;

  /// What evidence backs the position.
  final AnchorMatchBasis basis;

  /// Whether the position is verified: true only for
  /// [AnchorMatchBasis.identityReuse], where the full identity tuple
  /// matched. Migrated or recovered positions are evidence-backed but
  /// never verified.
  final bool verified;

  /// How much of the anchor's context agrees around the new position.
  final int contextScore;

  /// The edit distance for a fuzzy resolution; null otherwise.
  final int? editDistance;

  @override
  String toString() =>
      'AnchorResolved($range, basis: ${basis.name}, verified: $verified'
      '${editDistance == null ? '' : ', distance: $editDistance'})';
}

/// The evidence cannot distinguish the candidates: an indistinguishable
/// tie stays ambiguous even when one candidate appears earlier in the
/// reading order.
final class AnchorAmbiguous extends AnchorResolution {
  /// Creates an ambiguous outcome; [candidates] are in reading order.
  const AnchorAmbiguous({required this.candidates, required this.basis, this.truncated = false});

  /// The tied candidates, capped at [AnchorLimits.maxCandidates] and
  /// ordered by section, then start.
  final List<AnchorCandidate> candidates;

  /// What evidence produced the candidates.
  final AnchorMatchBasis basis;

  /// Whether more tied candidates existed than the limit reports.
  final bool truncated;

  @override
  String toString() =>
      'AnchorAmbiguous(${candidates.length} candidates'
      '${truncated ? ', truncated' : ''}, basis: ${basis.name})';
}

/// The selection is not in the target text.
final class AnchorMissing extends AnchorResolution {
  /// Creates a missing outcome.
  const AnchorMissing({required this.reason, this.fuzzySkipped = false});

  /// Why nothing was found.
  final AnchorMissingReason reason;

  /// Whether the fuzzy pass was skipped for its size bound (a longer
  /// quote) — the missing verdict then covers the exact
  /// and normalized passes only.
  final bool fuzzySkipped;

  @override
  String toString() => 'AnchorMissing(${reason.name}${fuzzySkipped ? ', fuzzy skipped' : ''})';
}

/// The anchor's identity cannot be reused against the target, and the
/// requested policy does not authorize (or cannot perform) migration.
final class AnchorIncompatibleRevision extends AnchorResolution {
  /// Creates the incompatibility outcome.
  const AnchorIncompatibleRevision({required this.kind, required this.differingFields});

  /// Which kind of incompatibility: another publication, or another
  /// revision of the same one.
  final AnchorIncompatibilityKind kind;

  /// The identity fields that disagree, named for diagnostics
  /// (`sourceRevision`, `readingOrderRevision`, `textProfileId`,
  /// `textRevision`, …).
  final List<String> differingFields;

  @override
  String toString() => 'AnchorIncompatibleRevision(${kind.name}, fields: $differingFields)';
}

/// The resolution could not run to a verdict within its declared
/// limits — reported instead of a pretend `missing`.
final class AnchorUnsupported extends AnchorResolution {
  /// Creates the unsupported outcome.
  const AnchorUnsupported({required this.reason});

  /// Why the resolution stopped.
  final AnchorUnsupportedReason reason;

  @override
  String toString() => 'AnchorUnsupported(${reason.name})';
}
