/// Finite work and size limits for durable anchors, declared before any
/// allocation happens.
///
/// Every bound is a positive integer: public entry points validate the
/// set through [requireValid] before relying on it, so a hostile
/// payload or an adversarial resolution can never drive unbounded
/// work — scans stop at the work budget, candidate lists cap their
/// length, and codec imports reject payloads above the size cap.
/// Raising a limit is the caller's explicit decision.
final class AnchorLimits {
  /// Creates a limits set; [requireValid] rejects non-positive bounds
  /// before any work relies on them.
  const AnchorLimits({
    this.maxQuoteLength = 4096,
    this.maxContextLength = 512,
    this.maxCandidates = 32,
    this.maxScanCodeUnits = 8000000,
    this.maxFuzzyQuoteLength = 256,
    this.maxFuzzyEditDistance = 8,
    this.maxFuzzyWork = 2000000,
    this.maxPayloadCodeUnits = 1048576,
    this.maxSelectorLength = 65536,
  });

  /// Throws [ArgumentError] when any bound is non-positive; public
  /// entry points call this first.
  void requireValid() {
    void check(final int value, final String name) {
      if (value <= 0) {
        throw ArgumentError.value(value, name, 'Must be positive');
      }
    }

    check(maxQuoteLength, 'maxQuoteLength');
    check(maxContextLength, 'maxContextLength');
    check(maxCandidates, 'maxCandidates');
    check(maxScanCodeUnits, 'maxScanCodeUnits');
    check(maxFuzzyQuoteLength, 'maxFuzzyQuoteLength');
    check(maxFuzzyEditDistance, 'maxFuzzyEditDistance');
    check(maxFuzzyWork, 'maxFuzzyWork');
    check(maxPayloadCodeUnits, 'maxPayloadCodeUnits');
    check(maxSelectorLength, 'maxSelectorLength');
  }

  /// The longest quoted selection a capture accepts. Longer selections
  /// fail the capture instead of silently degrading the anchor's
  /// evidence — the exact quote is what migration re-finds.
  final int maxQuoteLength;

  /// How much surrounding context (before and after, each) a capture
  /// keeps. Capture truncates longer context; import rejects payloads
  /// whose context exceeds the bound.
  final int maxContextLength;

  /// The most candidates an ambiguous resolution reports. Ties beyond
  /// the cap stay detected (the count keeps growing) but only the first
  /// — in reading order — enter the outcome, flagged truncated.
  final int maxCandidates;

  /// Total code units the exact and whitespace-normalized scans may
  /// read across all target sections of one resolution. Exhausting the
  /// budget reports `unsupported` instead of a pretend `missing`.
  final int maxScanCodeUnits;

  /// The longest quote the fuzzy pass accepts. Longer quotes anchor
  /// only exactly or whitespace-normalized — the fuzzy window grows
  /// with the quote, so the pass declares its own size bound.
  final int maxFuzzyQuoteLength;

  /// The edit distance the fuzzy pass tolerates between the quote and
  /// a candidate window (corrected typos, small re-wordings).
  final int maxFuzzyEditDistance;

  /// Dynamic-programming cells the fuzzy pass may fill per resolution.
  /// Exhausting the budget reports `unsupported`; an incomplete
  /// search cannot certify a unique candidate or absence.
  final int maxFuzzyWork;

  /// The longest serialized anchor payload an import accepts, in UTF-16
  /// code units of the JSON text.
  final int maxPayloadCodeUnits;

  /// The longest single string inside a W3C selector payload an import
  /// accepts (exact/prefix/suffix texts), in UTF-16 code units.
  final int maxSelectorLength;

  @override
  String toString() =>
      'AnchorLimits(quote: $maxQuoteLength, context: $maxContextLength, '
      'candidates: $maxCandidates, scan: $maxScanCodeUnits, '
      'fuzzy: ≤$maxFuzzyEditDistance @ $maxFuzzyQuoteLength, '
      'payload: $maxPayloadCodeUnits)';
}
