import 'dart:math' as math;
import 'dart:typed_data';

import '../../../foundation/entities/book/book.dart';
import '../../../foundation/entities/book/reading_order_item.dart';
import '../../../foundation/entities/file/text_file.dart';
import '../../../foundation/text/canonical_document_text.dart';
import '../../../foundation/text/canonical_text_range.dart';
import '../../../foundation/text/canonical_text_snapshot.dart';
import '../../../foundation/text/publication_revision.dart';
import '../../../foundation/text/revision_digest.dart';
import '../../../foundation/text/section_occurrence.dart';
import '../../../foundation/text/text_profile.dart';
import 'anchor_limits.dart';
import 'anchor_resolution.dart';
import 'annotation_anchor.dart';

/// The extraction profile of the plain canonical section text the
/// generic capture/resolve helpers mint: the document-text scanner's
/// output (markup stripped, entities decoded, whitespace kept). PDF
/// sections use their reading mode's own profile instead — capture
/// them through `PdfPageStructure` snapshots, whose canonical profile
/// binds the reflow plan revision.
final TextProfile documentTextProfile = TextProfile.of(
  algorithm: 'document-text',
  options: const <String, String>{},
  planRevision: RevisionDigest.textRevision('unseal document-text extraction 1'),
);

/// The durable annotations facade: capture a selection as an anchor
/// bound to publication identity and revisions, then resolve the
/// anchor against revised targets — reporting `resolved`, `ambiguous`,
/// `missing`, `incompatibleRevision` or `unsupported`, never guessing.
///
/// Capture and resolve are pure functions over materialized snapshots;
/// no book parsing, I/O or worker transport hides behind them. The v1
/// annotation codecs and the `relocateTextLocator` helper stay
/// untouched and independent — the anchor envelope is additive and
/// never reinterpreted by, and never reinterprets, the v1 payloads.
abstract final class DurableAnnotations {
  const DurableAnnotations._();

  /// Captures an anchor over [snapshot]'s materialized text; see
  /// [AnnotationAnchor.capture] for the contract. The section text
  /// itself never enters the anchor — identity, revisions, bounds and
  /// the bounded quote/context evidence do.
  static AnnotationAnchor capture({
    required final CanonicalTextSnapshot snapshot,
    required final int start,
    required final int end,
    final String? annotationId,
    final AnchorLimits limits = const AnchorLimits(),
  }) {
    return AnnotationAnchor.capture(
      snapshot: snapshot,
      start: start,
      end: end,
      annotationId: annotationId,
      limits: limits,
    );
  }

  /// Captures the anchor for a section of [book] under [identity]:
  /// mints the canonical snapshot of `book.readingOrder[sectionIndex]`
  /// (see [sectionSnapshot]) and cuts [start]..[end] from its text.
  ///
  /// PDF books should capture through their reading mode's
  /// `PdfPageStructure` canonical snapshot instead — the generic
  /// document-text profile does not describe either PDF mode.
  static AnnotationAnchor captureInSection(
    final Book book, {
    required final int sectionIndex,
    required final int start,
    required final int end,
    required final PublicationRevision identity,
    final String? annotationId,
    final AnchorLimits limits = const AnchorLimits(),
  }) {
    final snapshot = sectionSnapshot(book, sectionIndex: sectionIndex, identity: identity);

    return AnnotationAnchor.capture(
      snapshot: snapshot,
      start: start,
      end: end,
      annotationId: annotationId,
      limits: limits,
    );
  }

  /// Resolves [anchor] against [targets] — the destination's section
  /// snapshots in reading order — under [policy].
  ///
  /// Outcomes, exactly one per call:
  ///
  /// * [AnchorResolved] — the selection re-anchored. Verified only on
  ///   identity reuse; migration and recovery positions are
  ///   evidence-backed and report `verified: false`.
  /// * [AnchorAmbiguous] — indistinguishable candidates tie at the top
  ///   evidence level. A tie stays ambiguous even when one candidate
  ///   appears earlier in the reading order.
  /// * [AnchorMissing] — no target carries the selection (or the
  ///   anchor's own evidence contradicts it).
  /// * [AnchorIncompatibleRevision] — the identity cannot be reused
  ///   and the policy does not authorize (or cannot perform) the
  ///   migration.
  /// * [AnchorUnsupported] — the declared limits stopped the search
  ///   before a verdict was possible.
  static AnchorResolution resolve({
    required final AnnotationAnchor anchor,
    required final List<CanonicalTextSnapshot> targets,
    final AnchorPolicy policy = AnchorPolicy.verifiedReuse,
    final AnchorLimits limits = const AnchorLimits(),
  }) {
    limits.requireValid();
    if (targets.isEmpty) {
      return const AnchorMissing(reason: AnchorMissingReason.noTargets);
    }

    // Identity pass: the full tuple decides verified reuse. It comes
    // before any policy dispatch — an exact revision match resolves
    // under every policy, and nothing runs "by proximity" first.
    for (final target in targets) {
      if (!_sameIdentity(anchor, target)) continue;

      if (anchor.end > target.utf16Length) {
        return const AnchorMissing(reason: AnchorMissingReason.anchorRangeOutOfBounds);
      }
      if (target.text.substring(anchor.start, anchor.end) != anchor.quote.exact) {
        return const AnchorMissing(reason: AnchorMissingReason.quoteMismatch);
      }

      return AnchorResolved(
        range: CanonicalTextRange(snapshot: target, start: anchor.start, end: anchor.end),
        basis: AnchorMatchBasis.identityReuse,
        verified: true,
      );
    }

    final mismatch = _incompatibility(anchor, targets);
    final migrationAllowed =
        policy == AnchorPolicy.contextRecovery ||
        (policy == AnchorPolicy.explicitMigration &&
            mismatch.kind == AnchorIncompatibilityKind.revisionMismatch);
    if (!migrationAllowed) {
      return mismatch;
    }

    return _anchorByEvidence(anchor, targets, limits);
  }

  /// Resolves [anchor] against a whole [book] under [identity]:
  /// [sectionSnapshots] builds the targets, then [resolve] runs. For
  /// PDF books pass the per-mode snapshots directly to [resolve]
  /// instead — the generic profile here does not describe PDF modes.
  static AnchorResolution resolveInBook(
    final AnnotationAnchor anchor,
    final Book book, {
    required final PublicationRevision identity,
    final AnchorPolicy policy = AnchorPolicy.verifiedReuse,
    final AnchorLimits limits = const AnchorLimits(),
  }) {
    return resolve(
      anchor: anchor,
      targets: sectionSnapshots(book, identity: identity),
      policy: policy,
      limits: limits,
    );
  }

  /// Mints the canonical snapshot of one section of [book] under
  /// [identity]: the section's document text (the scanner's canonical
  /// space) bound to the reading-order occurrence and the
  /// [documentTextProfile] (or the explicit [profile]).
  ///
  /// Throws [RangeError] for a section outside the reading order. An
  /// empty section produces no snapshot anywhere in this API — the
  /// common snapshot contract requires non-empty text.
  static CanonicalTextSnapshot sectionSnapshot(
    final Book book, {
    required final int sectionIndex,
    required final PublicationRevision identity,
    final TextProfile? profile,
  }) {
    final order = book.readingOrder;
    if (sectionIndex < 0 || sectionIndex >= order.length) {
      throw RangeError.index(sectionIndex, order, 'sectionIndex');
    }
    final item = order[sectionIndex];
    final file = _contentFile(book, item.name);
    if (file == null) {
      throw StateError('Reading-order item ${item.name} has no content file in this book');
    }

    return CanonicalTextSnapshot(
      identity: identity,
      occurrence: SectionOccurrence(
        sectionIndex: sectionIndex,
        resourcePath: item.name,
        readingOrderRevision: _readingOrderRevision(order),
      ),
      profile: profile ?? documentTextProfile,
      text: documentTextOf(file),
    );
  }

  /// Mints the canonical snapshots of every non-empty section of
  /// [book], in reading order — the target list [resolve] expects.
  static List<CanonicalTextSnapshot> sectionSnapshots(
    final Book book, {
    required final PublicationRevision identity,
    final TextProfile? profile,
  }) {
    final order = book.readingOrder;
    final orderRevision = _readingOrderRevision(order);
    final snapshots = <CanonicalTextSnapshot>[];
    for (var sectionIndex = 0; sectionIndex < order.length; sectionIndex++) {
      final item = order[sectionIndex];
      final file = _contentFile(book, item.name);
      if (file == null) continue;
      final text = documentTextOf(file);
      if (text.isEmpty) continue;

      snapshots.add(
        CanonicalTextSnapshot(
          identity: identity,
          occurrence: SectionOccurrence(
            sectionIndex: sectionIndex,
            resourcePath: item.name,
            readingOrderRevision: orderRevision,
          ),
          profile: profile ?? documentTextProfile,
          text: text,
        ),
      );
    }

    return snapshots;
  }

  static TextFile? _contentFile(final Book book, final String path) {
    for (final candidate in book.files.html) {
      if (candidate.path == path) return candidate;
    }

    return null;
  }
}

/// Whether [anchor] and [target] carry the same full identity tuple —
/// publication revision, occurrence, profile and text revision, every
/// field compared including explicit nulls.
bool _sameIdentity(final AnnotationAnchor anchor, final CanonicalTextSnapshot target) {
  return anchor.identity == target.identity &&
      anchor.occurrence == target.occurrence &&
      anchor.profile == target.profile &&
      anchor.textRevision == target.textRevision;
}

String _readingOrderRevision(final List<ReadingOrderItem> order) {
  return RevisionDigest.readingOrderRevision([
    for (final entry in order) (entry.name, entry.isHtml),
  ]);
}

/// Classifies why the anchor's identity does not match the target
/// list, naming the differing fields for diagnostics.
AnchorIncompatibleRevision _incompatibility(
  final AnnotationAnchor anchor,
  final List<CanonicalTextSnapshot> targets,
) {
  CanonicalTextSnapshot? representative;
  for (final target in targets) {
    if (target.occurrence.sectionIndex == anchor.occurrence.sectionIndex) {
      representative = target;
      break;
    }
  }
  final target = representative ?? targets.first;

  if (anchor.identity.publicationId != target.identity.publicationId) {
    return const AnchorIncompatibleRevision(
      kind: AnchorIncompatibilityKind.publicationMismatch,
      differingFields: ['publicationId'],
    );
  }

  final differing = <String>[
    if (anchor.identity.editionId != target.identity.editionId) 'editionId',
    if (anchor.identity.sourceRevision != target.identity.sourceRevision) 'sourceRevision',
    if (anchor.identity.sourceEvidence != target.identity.sourceEvidence) 'sourceEvidence',
    if (anchor.occurrence.readingOrderRevision != target.occurrence.readingOrderRevision)
      'readingOrderRevision',
    if (anchor.profile != target.profile) 'textProfileId',
    if (anchor.textRevision != target.textRevision) 'textRevision',
  ];

  return AnchorIncompatibleRevision(
    kind: AnchorIncompatibilityKind.revisionMismatch,
    differingFields: differing,
  );
}

/// The evidence ladder: exact quote scan, whitespace-normalized scan,
/// bounded fuzzy pass. Each level runs only when the previous found
/// nothing; each level's tie at the top stays ambiguous; exhausting
/// the scan budget before any verdict reports `unsupported` instead of
/// a pretend `missing`.
AnchorResolution _anchorByEvidence(
  final AnnotationAnchor anchor,
  final List<CanonicalTextSnapshot> targets,
  final AnchorLimits limits,
) {
  if (anchor.quote.exact.isEmpty) {
    return const AnchorMissing(reason: AnchorMissingReason.noQuoteEvidence);
  }

  var budget = limits.maxScanCodeUnits;

  final exact = _scanPass(anchor: anchor, targets: targets, limits: limits, budget: budget);
  if (exact.collector.tieCount > 0) return exact.outcome();
  if (exact.budgetExhausted) {
    return const AnchorUnsupported(reason: AnchorUnsupportedReason.scanWorkExceeded);
  }
  budget = exact.remainingBudget;

  final normalized = _normalizedPass(
    anchor: anchor,
    targets: targets,
    limits: limits,
    budget: budget,
  );
  if (normalized.collector.tieCount > 0) return normalized.outcome();
  if (normalized.budgetExhausted) {
    return const AnchorUnsupported(reason: AnchorUnsupportedReason.scanWorkExceeded);
  }

  var fuzzySkipped = anchor.quote.exact.length > limits.maxFuzzyQuoteLength;
  if (!fuzzySkipped) {
    final (outcome, workExhausted) = _fuzzyPass(anchor: anchor, targets: targets, limits: limits);
    if (outcome.collector.tieCount > 0) {
      final candidates = outcome.collector.candidates;
      if (outcome.collector.tieCount == 1) {
        final candidate = candidates.single;

        return AnchorResolved(
          range: candidate.range,
          basis: AnchorMatchBasis.fuzzy,
          verified: false,
          contextScore: candidate.contextScore,
          editDistance: candidate.editDistance,
        );
      }

      return AnchorAmbiguous(
        candidates: candidates,
        basis: AnchorMatchBasis.fuzzy,
        truncated: outcome.collector.tieCount > candidates.length,
      );
    }
    fuzzySkipped = workExhausted;
  }

  return AnchorMissing(reason: AnchorMissingReason.quoteNotFound, fuzzySkipped: fuzzySkipped);
}

/// The shared scan-pass result: the top-tied candidates (capped), how
/// many candidates reached the top tie, and the budget state.
final class _ScanOutcome {
  _ScanOutcome(this.collector, this.budgetExhausted, this.remainingBudget);

  final _CandidateCollector collector;
  final bool budgetExhausted;
  final int remainingBudget;

  AnchorResolution outcome() {
    if (collector.tieCount == 1) {
      final candidate = collector.candidates.single;

      return AnchorResolved(
        range: candidate.range,
        basis: collector.basis,
        verified: false,
        contextScore: candidate.contextScore,
        editDistance: candidate.editDistance,
      );
    }

    return AnchorAmbiguous(
      candidates: collector.candidates,
      basis: collector.basis,
      truncated: collector.tieCount > collector.candidates.length,
    );
  }
}

/// Finds every exact occurrence of the quote, scoring the anchor's
/// context agreement around each. The best-scoring occurrences are the
/// candidates; an exact tie at the top is an ambiguity.
_ScanOutcome _scanPass({
  required final AnnotationAnchor anchor,
  required final List<CanonicalTextSnapshot> targets,
  required final AnchorLimits limits,
  required final int budget,
}) {
  final quote = anchor.quote;
  final collector = _CandidateCollector(limits, (final candidate) => -candidate.contextScore);
  var exhausted = false;
  var remaining = budget;

  for (final target in targets) {
    if (remaining <= 0) {
      exhausted = true;
      break;
    }
    remaining -= target.text.length;
    final text = target.text;
    var from = 0;
    while (true) {
      final start = text.indexOf(quote.exact, from);
      if (start < 0) break;
      collector.offer(
        AnchorCandidate(
          range: CanonicalTextRange(
            snapshot: target,
            start: start,
            end: start + quote.exact.length,
          ),
          contextScore: _contextScore(text, start, start + quote.exact.length, quote),
          basis: AnchorMatchBasis.exact,
        ),
      );
      from = start + 1;
    }
  }

  return _ScanOutcome(collector, exhausted, math.max(0, remaining));
}

/// Re-finds the quote after re-wrapping: both sides are normalized by
/// collapsing whitespace runs to single spaces (trimming the ends),
/// and the normalized match maps back through a per-unit projection
/// onto the canonical UTF-16 offsets, so the resolved range covers the
/// original text — its whitespace run included.
_ScanOutcome _normalizedPass({
  required final AnnotationAnchor anchor,
  required final List<CanonicalTextSnapshot> targets,
  required final AnchorLimits limits,
  required final int budget,
}) {
  final quote = anchor.quote;
  final normalizedQuote = _NormalizedText(quote.exact);
  final collector = _CandidateCollector(
    limits,
    (final candidate) => -candidate.contextScore,
    AnchorMatchBasis.whitespaceNormalized,
  );
  var exhausted = false;
  var remaining = budget;

  for (final target in targets) {
    if (remaining <= 0) {
      exhausted = true;
      break;
    }
    remaining -= target.text.length;
    final normalizedText = _NormalizedText(target.text);
    var from = 0;
    while (true) {
      final start = normalizedText.text.indexOf(normalizedQuote.text, from);
      if (start < 0) break;
      final canonicalStart = normalizedText.canonicalStart(start);
      final canonicalEnd = normalizedText.canonicalEnd(start + normalizedQuote.text.length);
      collector.offer(
        AnchorCandidate(
          range: CanonicalTextRange(snapshot: target, start: canonicalStart, end: canonicalEnd),
          contextScore: _contextScore(target.text, canonicalStart, canonicalEnd, quote),
          basis: AnchorMatchBasis.whitespaceNormalized,
        ),
      );
      from = start + 1;
    }
  }

  return _ScanOutcome(collector, exhausted, math.max(0, remaining));
}

/// The corrected-edition pass, the bounded port of Hypothesis's fuzzy
/// anchoring: sampled exact grams of the quote seed candidate windows
/// per alignment; each window is verified with a free-start edit
/// distance capped at [AnchorLimits.maxFuzzyEditDistance]; the
/// smallest distance (then the best context) wins, and a tie on both
/// stays ambiguous. Total work is bounded by
/// [AnchorLimits.maxFuzzyWork] DP cells plus the gram scans.
(_ScanOutcome, bool workExhausted) _fuzzyPass({
  required final AnnotationAnchor anchor,
  required final List<CanonicalTextSnapshot> targets,
  required final AnchorLimits limits,
}) {
  final quote = anchor.quote.exact;
  final maxDistance = limits.maxFuzzyEditDistance;
  final collector = _CandidateCollector(
    limits,
    (final candidate) => (candidate.editDistance ?? 0) * 0x10000 - candidate.contextScore,
    AnchorMatchBasis.fuzzy,
  );
  final grams = _sampledGrams(quote);
  final verifier = _FuzzyVerifier(quote, maxDistance);
  var work = limits.maxFuzzyWork;
  var exhausted = false;

  for (final target in targets) {
    if (work <= 0) {
      exhausted = true;
      break;
    }
    final text = target.text;

    // Seed: every exact gram hit votes an alignment start s = hit −
    // gram position; a real match keeps its grams within ±k of s.
    final alignments = <int>[];
    for (final gram in grams) {
      work -= text.length;
      var from = 0;
      while (true) {
        final hit = text.indexOf(gram.text, from);
        if (hit < 0) break;
        alignments.add(hit - gram.position);
        from = hit + 1;
        // Pathologically repetitive text drowns the pass in votes;
        // the cap keeps the list bounded and skips this target.
        if (alignments.length > limits.maxCandidates * 8) break;
      }
      if (work <= 0 || alignments.length > limits.maxCandidates * 8) break;
    }
    final votesCapped = alignments.length > limits.maxCandidates * 8;
    if (work <= 0 && alignments.isEmpty) {
      exhausted = true;
      break;
    }
    if (votesCapped) continue;

    alignments.sort();
    _clusterWindows(
      alignments: alignments,
      maxDistance: maxDistance,
      minVotes: grams.length == 1 ? 1 : 2,
      quoteLength: quote.length,
      textLength: text.length,
      window: (final from, final to) {
        if (exhausted) return;
        work -= (to - from) * (quote.length + 1);
        if (work < 0) {
          exhausted = true;

          return;
        }
        final match = verifier.verify(text, from, to);
        if (match == null) return;
        collector.offer(
          AnchorCandidate(
            range: CanonicalTextRange(snapshot: target, start: match.start, end: match.end),
            contextScore: _contextScore(text, match.start, match.end, anchor.quote),
            basis: AnchorMatchBasis.fuzzy,
            editDistance: match.distance,
          ),
        );
      },
    );
  }

  return (_ScanOutcome(collector, false, 0), exhausted);
}

/// Groups sorted alignment votes into candidate windows — votes within
/// `2k+1` of each other share an alignment — and hands each window's
/// text bounds to [window]. A single-gram quote (a short quote)
/// accepts one vote; otherwise a cluster needs two gram hits to cut
/// noise.
void _clusterWindows({
  required final List<int> alignments,
  required final int maxDistance,
  required final int minVotes,
  required final int quoteLength,
  required final int textLength,
  required final void Function(int from, int to) window,
}) {
  var clusterStart = 0;
  var clusterMax = 0;
  var clusterVotes = 0;

  void flush() {
    if (clusterVotes < minVotes) return;
    final from = math.max(0, clusterStart - maxDistance);
    final to = math.min(textLength, clusterMax + quoteLength + maxDistance);
    if (from < to) window(from, to);
  }

  for (final alignment in alignments) {
    if (clusterVotes == 0) {
      clusterStart = alignment;
      clusterMax = alignment;
      clusterVotes = 1;
      continue;
    }
    if (alignment - clusterStart <= 2 * maxDistance + 1) {
      clusterVotes++;
      if (alignment > clusterMax) clusterMax = alignment;
      continue;
    }
    flush();
    clusterStart = alignment;
    clusterMax = alignment;
    clusterVotes = 1;
  }
  flush();
}

/// Counts how much of the anchor's context agrees around the range
/// [start, end): the matched suffix of `quote.before` plus the matched
/// prefix of `quote.after`, in code units.
int _contextScore(final String text, final int start, final int end, final AnchorQuote quote) {
  var score = 0;
  final maxBefore = math.min(quote.before.length, start);
  for (var i = 1; i <= maxBefore; i++) {
    if (text.codeUnitAt(start - i) != quote.before.codeUnitAt(quote.before.length - i)) break;
    score++;
  }

  final maxAfter = math.min(quote.after.length, text.length - end);
  for (var i = 0; i < maxAfter; i++) {
    if (text.codeUnitAt(end + i) != quote.after.codeUnitAt(i)) break;
    score++;
  }

  return score;
}

/// Keeps only the candidates tied at the best level, capped at the
/// limit, counting every candidate that reached the tie. The level
/// function ranks candidates: exact/normalized passes rank by context
/// score alone, the fuzzy pass by distance first and context second.
final class _CandidateCollector {
  _CandidateCollector(this.limits, this._levelOf, [this._basis = AnchorMatchBasis.exact]);

  final AnchorLimits limits;
  final AnchorMatchBasis _basis;
  final int Function(AnchorCandidate candidate) _levelOf;
  final List<AnchorCandidate> _candidates = [];
  var _bestLevel = 0x7FFFFFFFFFFFFFFF;
  var _tieCount = 0;

  AnchorMatchBasis get basis => _basis;

  List<AnchorCandidate> get candidates => _candidates;

  int get tieCount => _tieCount;

  void offer(final AnchorCandidate candidate) {
    final level = _levelOf(candidate);
    if (level > _bestLevel) return;
    if (level < _bestLevel) {
      _bestLevel = level;
      _candidates.clear();
      _tieCount = 0;
    }
    _tieCount++;
    if (_candidates.length < limits.maxCandidates) {
      _candidates.add(candidate);
    }
  }
}

/// Up to eight evenly sampled exact grams of the quote, used as
/// alignment seeds by the fuzzy pass.
final class _Gram {
  const _Gram(this.position, this.text);

  final int position;
  final String text;
}

List<_Gram> _sampledGrams(final String quote) {
  const gramLength = 8;
  const maxGrams = 8;
  if (quote.length <= gramLength) {
    return [_Gram(0, quote)];
  }
  final lastStart = quote.length - gramLength;
  final grams = <_Gram>[];
  for (var i = 0; i < maxGrams; i++) {
    final position = (i * lastStart) ~/ (maxGrams - 1);
    final gram = _Gram(position, quote.substring(position, position + gramLength));
    if (grams.isEmpty || grams.last.position != position) grams.add(gram);
  }

  return grams;
}

/// The whitespace-normalized view of one text plus the projection back
/// to its canonical UTF-16 offsets: every normalized code unit
/// remembers the canonical span it came from, so a normalized match
/// converts into the exact original range (a collapsed whitespace run
/// stays inside the resolved range).
final class _NormalizedText {
  _NormalizedText(final String source) {
    final units = StringBuffer();
    final starts = <int>[];
    final ends = <int>[];
    var index = 0;
    while (index < source.length) {
      if (_isAsciiWhitespace(source.codeUnitAt(index))) {
        var runEnd = index;
        while (runEnd < source.length && _isAsciiWhitespace(source.codeUnitAt(runEnd))) {
          runEnd++;
        }
        units.write(' ');
        starts.add(index);
        ends.add(runEnd);
        index = runEnd;
        continue;
      }
      units.writeCharCode(source.codeUnitAt(index));
      starts.add(index);
      ends.add(index + 1);
      index++;
    }

    var from = 0;
    while (from < starts.length && ends[from] - starts[from] > 1) {
      // Leading whitespace run (the collapsed space).
      from++;
    }
    var to = starts.length;
    while (to > from && ends[to - 1] - starts[to - 1] > 1) {
      // Trailing whitespace run.
      to--;
    }
    final trimmed = units.toString().substring(from, to);

    text = trimmed;
    canonicalStarts = starts.sublist(from, to);
    canonicalEnds = ends.sublist(from, to);
  }

  late final String text;
  late final List<int> canonicalStarts;
  late final List<int> canonicalEnds;

  int canonicalStart(final int normalizedOffset) => canonicalStarts[normalizedOffset];

  int canonicalEnd(final int normalizedEnd) => canonicalEnds[normalizedEnd - 1];

  static bool _isAsciiWhitespace(final int unit) {
    return (unit >= 0x09 && unit <= 0x0D) || unit == 0x20;
  }
}

/// One fuzzy match inside a target text: canonical range and measured
/// edit distance.
final class _FuzzyMatch {
  const _FuzzyMatch(this.start, this.end, this.distance);

  final int start;
  final int end;
  final int distance;
}

/// The free-start edit-distance verifier: quote versus a text window,
/// distances saturated one past the cap, parent pointers recovering
/// the matched range.
final class _FuzzyVerifier {
  _FuzzyVerifier(this.quote, this.maxDistance)
    : _rowCapacity = quote.length + 4 * maxDistance + 2,
      _distances = Int32List(2 * (quote.length + 4 * maxDistance + 2)),
      _parents = Uint8List((quote.length + 1) * (quote.length + 4 * maxDistance + 2));

  final String quote;
  final int maxDistance;

  /// Row stride upper bound: windows are capped at
  /// `quote.length + 4 * maxDistance` code units.
  final int _rowCapacity;
  final Int32List _distances;
  final Uint8List _parents;

  /// Matches [quote] inside `text[from..to)` allowing up to
  /// [maxDistance] edits, free start; null when the window's best
  /// distance exceeds the cap. Callers keep the window inside
  /// `quote.length + 4 * maxDistance` so the flat buffers fit.
  _FuzzyMatch? verify(final String text, final int from, final int to) {
    final windowLength = to - from;
    final rowLength = windowLength + 1;
    var previousBase = 0;
    var currentBase = _rowCapacity;

    for (var j = 0; j <= windowLength; j++) {
      _distances[previousBase + j] = 0;
    }

    var bestDistance = maxDistance + 1;
    var bestEnd = -1;
    for (var i = 1; i <= quote.length; i++) {
      _distances[currentBase] = i;
      var rowMin = i;
      final quoteUnit = quote.codeUnitAt(i - 1);
      for (var j = 1; j <= windowLength; j++) {
        final cell = currentBase + j;
        var value = _distances[previousBase + j - 1];
        var parent = 1;
        if (quoteUnit != text.codeUnitAt(from + j - 1)) value++;
        final upValue = _distances[previousBase + j] + 1;
        if (upValue < value) {
          value = upValue;
          parent = 2;
        }
        final leftValue = _distances[cell - 1] + 1;
        if (leftValue < value) {
          value = leftValue;
          parent = 3;
        }
        if (value > maxDistance + 1) value = maxDistance + 1;
        _distances[cell] = value;
        _parents[i * rowLength + j] = parent;
        if (value < rowMin) rowMin = value;
      }
      if (i == quote.length) {
        for (var j = 0; j <= windowLength; j++) {
          final value = _distances[currentBase + j];
          if (value < bestDistance) {
            bestDistance = value;
            bestEnd = j;
          }
        }
      }
      if (rowMin > maxDistance) return null;
      final swap = previousBase;
      previousBase = currentBase;
      currentBase = swap;
    }

    if (bestEnd < 0 || bestDistance > maxDistance) return null;

    // Backtrack from (m, bestEnd) to row 0; the column there is the
    // matched start.
    var i = quote.length;
    var j = bestEnd;
    while (i > 0) {
      final parent = _parents[i * rowLength + j];
      switch (parent) {
        case 1:
          i--;
          j--;
        case 2:
          i--;
        case 3:
          j--;
        default:
          return null;
      }
    }

    return _FuzzyMatch(from + j, from + bestEnd, bestDistance);
  }
}
