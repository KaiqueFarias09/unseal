import '../header/pdf_object.dart';

/// One PDF page: geometry, rotation and the raw resources dictionary.
///
/// Boxes follow the PDF `/MediaBox` convention — `[x0, y0, x1, y1]`
/// in user-space points with the origin at the bottom-left corner.
/// Text extraction converts to the top-left pixel space the reflow
/// heuristics expect; the raw boxes stay here for consumers that
/// need the document's own geometry (the viewer's facsimile mode).
class PdfPage {
  /// Creates a [PdfPage].
  const PdfPage({
    required this.objectNumber,
    required this.mediaBox,
    this.cropBox,
    this.rotate = 0,
    this.resources,
  });

  /// The object number of the page dictionary, or 0 for inline
  /// (non-referenced) pages. Outline destinations resolve against it.
  final int objectNumber;

  /// `[x0, y0, x1, y1]` in user-space points.
  final List<double> mediaBox;

  /// The `/CropBox` when the page carries one, in the same space.
  final List<double>? cropBox;

  /// The `/Rotate` value in degrees (0, 90, 180, 270; clockwise).
  final int rotate;

  /// The effective `/Resources` dictionary (possibly inherited), as
  /// parsed — references inside stay unresolved until extraction.
  final PdfObject? resources;

  /// The visible width in points (crop box preferred).
  double get width => (cropBox ?? mediaBox)[2] - (cropBox ?? mediaBox)[0];

  /// The visible height in points (crop box preferred).
  double get height => (cropBox ?? mediaBox)[3] - (cropBox ?? mediaBox)[1];
}
