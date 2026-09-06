/// The extracted content of one PDF page: canonical text lines and
/// image placements, in the page's top-left pixel space (points).
///
/// The line list doubles as the page's canonical text space: the
/// lines, read in order and joined with `\n`, are the exact text
/// both reading modes derive from — the reflowed HTML groups them
/// without touching a character, the facsimile text layer spans them
/// one box per line — so selection, search hits and highlight
/// offsets agree across modes by construction.
class PdfPageText {
  /// Creates a page's extracted text.
  const PdfPageText({required this.lines, this.images = const <PdfImageBox>[]});

  /// The text lines in reading order (top to bottom, left to right).
  final List<PdfTextLine> lines;

  /// Image placements on the page, in reading order.
  final List<PdfImageBox> images;

  /// The canonical text stream of the page.
  String get text => lines.map((final line) => line.text).join('\n');

  /// Whether the page yielded any visible text.
  bool get isEmpty => lines.every((final line) => line.text.isEmpty);
}

/// One line of text: the canonical unit the extractor emits.
///
/// Runs that share a baseline merge into one line, with a space
/// inserted wherever the gap between runs exceeds a fraction of the
/// font size — that join, done once here, is what both reading modes
/// then consume unchanged.
class PdfTextLine {
  /// Creates a text line.
  const PdfTextLine({
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.fontSize,
    this.rotated = false,
  });

  /// The canonical text of the line (trimmed, join spaces inside).
  final String text;

  /// Left edge in top-left page points.
  final double x;

  /// Top edge in top-left page points.
  final double y;

  /// Line width in points.
  final double width;

  /// Line height in points (the tallest run's font size).
  final double height;

  /// The dominant font size in points.
  final double fontSize;

  /// Whether the text renders on a non-horizontal baseline.
  final bool rotated;

  /// Right edge in points.
  double get right => x + width;

  /// Bottom edge in points.
  double get bottom => y + height;
}

/// An image placement on the page.
class PdfImageBox {
  /// Creates an image box.
  const PdfImageBox({
    required this.name,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.path = '',
  });

  /// The resource name the content stream drew (`/XObject` entry).
  final String name;

  /// Left edge in top-left page points.
  final double x;

  /// Top edge in top-left page points.
  final double y;

  /// Width in points.
  final double width;

  /// Height in points.
  final double height;

  /// The extracted file path when the image left a readable file
  /// (JPEG passthrough); empty when the codec stayed unsupported.
  final String path;
}
