/// The stable source-space position vocabulary for PDF pages: an
/// anchor format that survives reading-mode switches and reopenings,
/// and the mapping outcomes that reconcile it with a canonical text.
///
/// A source range addresses one extraction line (zero-based) by index
/// plus UTF-16 bounds inside that line. It is stable for the same file
/// revision under the same extractor — it is never an offset derived
/// from the reflow, whose statistics differ between the full
/// extraction and the sampled session plan.
library;

/// The source-space anchor: page, line and bounds inside the line's
/// text.
final class PdfSourceRange {
  /// Creates a source range; [ArgumentError] reports negative values.
  PdfSourceRange({
    required this.pageIndex,
    required this.lineIndex,
    required this.start,
    required this.end,
    this.expectedLineText,
  }) {
    if (pageIndex < 0) {
      throw ArgumentError.value(pageIndex, 'pageIndex', 'Must be zero-based and non-negative');
    }
    if (lineIndex < 0) {
      throw ArgumentError.value(lineIndex, 'lineIndex', 'Must be zero-based and non-negative');
    }
    if (start < 0) {
      throw ArgumentError.value(start, 'start', 'Must be non-negative');
    }
    if (end < start) {
      throw ArgumentError.value(end, 'end', 'Must not precede the inclusive start');
    }
  }

  /// The zero-based page index.
  final int pageIndex;

  /// The zero-based index into the page's extraction line list.
  final int lineIndex;

  /// The inclusive first code unit of the line's text.
  final int start;

  /// The exclusive end inside the line's text.
  final int end;

  /// The line text the anchor was minted against, when the minter kept
  /// it: mapping verifies the current extraction still carries the
  /// same line, so an extraction change answers `missing` instead of
  /// silently pointing elsewhere.
  final String? expectedLineText;

  /// The code-unit length of the range.
  int get length => end - start;

  @override
  String toString() => 'PdfSourceRange(page $pageIndex, line $lineIndex, $start..$end)';
}

/// One mapped position: an offset range in a target text.
final class PdfMappedPosition {
  /// Creates a mapped position.
  const PdfMappedPosition({required this.offset, required this.length});

  /// The inclusive first code unit of the target text.
  final int offset;

  /// The code-unit length.
  final int length;

  /// The exclusive end.
  int get end => offset + length;

  @override
  String toString() => 'PdfMappedPosition($offset..$end)';
}

/// Why a source range did not map to a canonical position.
enum PdfPositionMissingReason {
  /// The range addresses another page than the structure's.
  pageMismatch,

  /// The line index is past the page's extraction line count.
  lineIndexOutOfRange,

  /// The bounds fall outside the line's text.
  boundsOutOfRange,

  /// The anchor's expected line text does not match the current
  /// extraction — the document or the extractor changed.
  textMismatch,

  /// The line was cut by the reflow (a running header or footer) in
  /// the profile the target text was produced under.
  lineDroppedByReflow,

  /// The target text does not contain the line.
  targetTextMismatch,
}

/// Why a mapping cannot be computed at all.
enum PdfPositionUnsupportedReason {
  /// The structure was built without a canonical form (source-only),
  /// so there is nothing to map into.
  noCanonicalProfile,
}

/// Sealed mapping outcomes: exactly one per query, with its reason.
sealed class PdfPositionMapping {
  const PdfPositionMapping();
}

/// The range resolved to a canonical offset range.
final class PdfPositionMapped extends PdfPositionMapping {
  /// Creates a mapped outcome.
  const PdfPositionMapped({required this.position});

  /// The position in the target text.
  final PdfMappedPosition position;

  @override
  String toString() => 'PdfPositionMapped($position)';
}

/// The target text carries the line more than once and the available
/// evidence cannot pick one occurrence. The candidates come back in
/// target order.
final class PdfPositionAmbiguous extends PdfPositionMapping {
  /// Creates an ambiguous outcome.
  const PdfPositionAmbiguous({required this.candidates});

  /// Every position the line text matches in the target.
  final List<PdfMappedPosition> candidates;

  @override
  String toString() => 'PdfPositionAmbiguous(${candidates.length} candidates)';
}

/// The anchor does not resolve in the target, for the reason carried.
final class PdfPositionMissing extends PdfPositionMapping {
  /// Creates a missing outcome.
  const PdfPositionMissing({required this.reason});

  /// Why the anchor is missing.
  final PdfPositionMissingReason reason;

  @override
  String toString() => 'PdfPositionMissing(${reason.name})';
}

/// The mapping cannot be computed for the reason carried.
final class PdfPositionUnsupported extends PdfPositionMapping {
  /// Creates an unsupported outcome.
  const PdfPositionUnsupported({required this.reason});

  /// Why mapping is unsupported.
  final PdfPositionUnsupportedReason reason;

  @override
  String toString() => 'PdfPositionUnsupported(${reason.name})';
}
