import 'pdf_page_text.dart';

/// The layout extraction of one page: the plain text extraction plus
/// the primitives the structure layer segments — per-character-derived
/// words and the page's axis-aligned ruling lines.
///
/// Words derive from glyph advances and font metrics, never from
/// dividing a line's width by its character count. Rules come from
/// stroked segments and hairline rectangles the content stream draws.
final class PdfPageLayoutExtraction {
  /// Creates a page's layout extraction.
  const PdfPageLayoutExtraction({required this.pageText, required this.words, required this.rules});

  /// The plain text extraction: the same output `extract` produces.
  final PdfPageText pageText;

  /// The page's words in reading order.
  final List<PdfWord> words;

  /// The page's axis-aligned ruling lines.
  final List<PdfRuleLine> rules;
}

/// The visible geometry of one page and the way back to the document's
/// own coordinates.
///
/// Widths, heights and boxes in this package's layout model use the
/// cropped, rotated page space: origin at the top-left corner, points
/// as units, dimensions as declared by the page's crop box. The
/// affine [transform] maps that space back to the original PDF user
/// space (`[a b c d e f]`, `x' = a·x + c·y + e`), so a consumer can
/// reconcile a highlighted box with annotations in raw PDF
/// coordinates.
final class PdfPageGeometry {
  /// Builds the geometry of a page with the given visible dimensions,
  /// `/Rotate` value and crop box (user-space `[x0, y0, x1, y1]`).
  factory PdfPageGeometry({
    required final double width,
    required final double height,
    required final int rotation,
    required final List<double> cropBox,
  }) {
    final x0 = cropBox[0];
    final y1 = cropBox[3];
    final boxWidth = cropBox[2] - cropBox[0];
    final boxHeight = cropBox[3] - cropBox[1];
    final List<double> transform = switch (rotation % 360) {
      90 => <double>[0, 1, 1, 0, x0, y1 - boxHeight],
      180 => <double>[-1, 0, 0, 1, x0 + boxWidth, y1 - boxHeight],
      270 => <double>[0, -1, -1, 0, x0 + boxWidth, y1],
      _ => <double>[1, 0, 0, -1, x0, y1],
    };

    return PdfPageGeometry._(
      width: width,
      height: height,
      rotation: rotation,
      transform: transform,
    );
  }

  const PdfPageGeometry._({
    required this.width,
    required this.height,
    required this.rotation,
    required this.transform,
  });

  /// Rebuilds a geometry from its parts without recomputing the
  /// affine — the wire decoder's path. [transform] is the page→user
  /// affine `[a b c d e f]`.
  const PdfPageGeometry.raw({
    required this.width,
    required this.height,
    required this.rotation,
    required this.transform,
  });

  /// The visible width in points (rotated page space).
  final double width;

  /// The visible height in points (rotated page space).
  final double height;

  /// The page's `/Rotate` value in degrees.
  final int rotation;

  /// The affine page→user transform, `[a b c d e f]`.
  final List<double> transform;

  /// Whether [toPdfPoint] is defined: the transform has a non-degenerate
  /// determinant (a zero-area crop box makes it degenerate).
  bool get transformInvertible =>
      (transform[0] * transform[3] - transform[1] * transform[2]).abs() > 1e-12;

  /// Maps a page-space point to the original PDF user space.
  ///
  /// Throws [StateError] when [transformInvertible] is false.
  (double, double) toPdfPoint(final double x, final double y) {
    if (!transformInvertible) {
      throw StateError('Page geometry transform is degenerate (zero-area crop box)');
    }

    return (
      transform[0] * x + transform[2] * y + transform[4],
      transform[1] * x + transform[3] * y + transform[5],
    );
  }

  /// Maps a page-space direction (a unit advance vector) back to user
  /// space, without the translation.
  (double, double) toPdfVector(final double dx, final double dy) {
    return (transform[0] * dx + transform[2] * dy, transform[1] * dx + transform[3] * dy);
  }
}

/// One word on the page: characters grouped by real glyph advances and
/// spacing, with the geometry those metrics establish.
///
/// Rotated words keep their advance [directionX]/[directionY] (a unit
/// vector in page space) — the axis-aligned box alone loses the text
/// direction.
final class PdfWord {
  /// Creates a word.
  const PdfWord({
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.fontSize,
    this.rotated = false,
    this.directionX = 1,
    this.directionY = 0,
  });

  /// The word's characters.
  final String text;

  /// Left edge in top-left page points.
  final double x;

  /// Top edge in top-left page points.
  final double y;

  /// Width in points.
  final double width;

  /// Height in points.
  final double height;

  /// The dominant font size in points.
  final double fontSize;

  /// Whether the word renders along a non-horizontal direction.
  final bool rotated;

  /// The advance direction's x component (unit vector, page space).
  final double directionX;

  /// The advance direction's y component (unit vector, page space).
  final double directionY;

  /// Right edge in points.
  double get right => x + width;

  /// Bottom edge in points.
  double get bottom => y + height;

  /// The squared distance from the point to this word's center, for
  /// nearest-neighbor segmentation.
  double distanceToCenterSquared(final double px, final double py) {
    final cx = x + width / 2;
    final cy = y + height / 2;
    final dx = px - cx;
    final dy = py - cy;

    return dx * dx + dy * dy;
  }
}

/// One axis-aligned ruling line in top-left page points — the input
/// table detection clusters into lattices.
final class PdfRuleLine {
  /// Creates a rule line; the endpoints order themselves.
  factory PdfRuleLine({
    required final double x0,
    required final double y0,
    required final double x1,
    required final double y1,
  }) {
    return PdfRuleLine._(
      x0: x0 <= x1 ? x0 : x1,
      y0: y0 <= y1 ? y0 : y1,
      x1: x0 <= x1 ? x1 : x0,
      y1: y0 <= y1 ? y1 : y0,
    );
  }

  const PdfRuleLine._({required this.x0, required this.y0, required this.x1, required this.y1});

  /// Left endpoint x.
  final double x0;

  /// Top endpoint y.
  final double y0;

  /// Right endpoint x.
  final double x1;

  /// Bottom endpoint y.
  final double y1;

  /// Whether the rule runs horizontally (zero vertical extent).
  bool get isHorizontal => (y1 - y0).abs() < 1e-6;

  /// Whether the rule runs vertically (zero horizontal extent).
  bool get isVertical => (x1 - x0).abs() < 1e-6;

  /// The rule's length in points.
  double get length => isHorizontal ? x1 - x0 : y1 - y0;

  /// The rule's fixed coordinate: y for horizontal rules, x for
  /// vertical ones.
  double get position => isHorizontal ? y0 : x0;
}

/// The editorial role a block plays on the page.
enum PdfBlockRole {
  /// Body content.
  content,

  /// A running header line above the document's header cut.
  header,

  /// A running footer line below the document's footer cut.
  footer,
}

/// One block of text: words the segmentation joined into lines and the
/// block's bbox, role and reading-order position.
///
/// [sourceLineIndexes] preserves provenance: which of the page's
/// source lines (the extraction's own line list) the block's text came
/// from, so a block never silently rewrites the canonical text.
final class PdfTextBlock {
  /// Creates a block.
  const PdfTextBlock({
    required this.index,
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.role,
    required this.sourceLineIndexes,
  });

  /// The block's position in the page's reading order.
  final int index;

  /// The block's text: its lines joined with `\n`.
  final String text;

  /// Left edge in top-left page points.
  final double x;

  /// Top edge in top-left page points.
  final double y;

  /// Width in points.
  final double width;

  /// Height in points.
  final double height;

  /// The editorial role the block plays.
  final PdfBlockRole role;

  /// The source line indexes the block's lines came from, in the
  /// block's own order.
  final List<int> sourceLineIndexes;

  /// Right edge in points.
  double get right => x + width;

  /// Bottom edge in points.
  double get bottom => y + height;
}

/// One detected column region: the page-area the region spans and the
/// blocks it contains, in reading order.
final class PdfColumnRegion {
  /// Creates a column region.
  const PdfColumnRegion({required this.x, required this.width, required this.blockIndexes});

  /// Left edge in top-left page points.
  final double x;

  /// Width in points.
  final double width;

  /// The blocks inside the region, in reading order.
  final List<int> blockIndexes;

  /// Right edge in points.
  double get right => x + width;
}

/// A range inside one source line's text: `[start, end)` in UTF-16
/// code units of the line at [lineIndex]. The unit cells and table
/// regions reference text by.
final class PdfCellRange {
  /// Creates a source-line range.
  const PdfCellRange({required this.lineIndex, required this.start, required this.end});

  /// The page's source line index (into the extraction's line list).
  final int lineIndex;

  /// The inclusive first code unit.
  final int start;

  /// The exclusive end.
  final int end;
}

/// One table cell: its grid position, geometry, text and the ranges of
/// source-line text it covers.
final class PdfTableCell {
  /// Creates a cell.
  const PdfTableCell({
    required this.row,
    required this.column,
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.ranges,
  });

  /// The zero-based row index.
  final int row;

  /// The zero-based column index.
  final int column;

  /// The cell's text: the words it contains, in reading order.
  final String text;

  /// Left edge in top-left page points.
  final double x;

  /// Top edge in top-left page points.
  final double y;

  /// Width in points.
  final double width;

  /// Height in points.
  final double height;

  /// The source-line ranges the cell's words cover.
  final List<PdfCellRange> ranges;

  /// Right edge in points.
  double get right => x + width;

  /// Bottom edge in points.
  double get bottom => y + height;
}

/// One detected table region: cells in a rows-by-columns grid, the
/// detection algorithm that produced it, and whether ruling lines
/// backed the grid.
final class PdfTableRegion {
  /// Creates a table region.
  const PdfTableRegion({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.rows,
    required this.hasRulingLines,
    required this.algorithm,
  });

  /// Left edge in top-left page points.
  final double x;

  /// Top edge in top-left page points.
  final double y;

  /// Width in points.
  final double width;

  /// Height in points.
  final double height;

  /// The table's rows; each row holds its cells in column order.
  final List<List<PdfTableCell>> rows;

  /// Whether ruling lines (not whitespace alignment alone) backed the
  /// detected grid.
  final bool hasRulingLines;

  /// Which detection algorithm found the table: `spreadsheet` (a
  /// complete ruling lattice), `basic` (vertical rulings plus text
  /// rows) or `aligned-columns` (the whitespace fallback).
  final String algorithm;

  /// Right edge in points.
  double get right => x + width;

  /// Bottom edge in points.
  double get bottom => y + height;

  /// The table's cell count across all rows.
  int get cellCount => rows.fold(0, (final sum, final row) => sum + row.length);
}

/// A table-shaped area the detector refused to call a table, with the
/// reason. Unsupported is a diagnosis, never a silently empty result.
final class PdfTableUnsupported {
  /// Creates an unsupported-table diagnosis.
  const PdfTableUnsupported({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.reason,
  });

  /// Left edge in top-left page points.
  final double x;

  /// Top edge in top-left page points.
  final double y;

  /// Width in points.
  final double width;

  /// Height in points.
  final double height;

  /// Why the area is not reported as a table: `rotated-rows` (the
  /// candidate rows do not run horizontally), `text-spans-grid` (text
  /// crosses the detected lattice, so cells would mix), `too-few-cells`
  /// (fewer than two rows and two columns) or `no-rulings-or-columns`
  /// (neither ruling lines nor aligned columns found).
  final String reason;

  /// Right edge in points.
  double get right => x + width;

  /// Bottom edge in points.
  double get bottom => y + height;
}
