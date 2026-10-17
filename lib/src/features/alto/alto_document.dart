import '../../foundation/spatial/spatial_rect.dart';
import '../../foundation/spatial/spatial_unit.dart';

/// A parsed ALTO document: the OCR sidecar's declared description, pages,
/// and positioned content.
///
/// The model keeps the format's own detail — non-text blocks, character
/// confidences, substitution pairs — that the shared spatial contract
/// deliberately leaves out. Coordinates stay in the document's declared
/// [unit]; nothing converts implicitly.
final class AltoDocument {
  /// Creates a document from validated parts.
  const AltoDocument({
    required this.version,
    required this.unit,
    required this.pages,
    this.softwareName,
    this.softwareVersion,
    this.sourceImageName,
  });

  /// The ALTO major version the root namespace declares: `2`, `3`, or `4`.
  final int version;

  /// The `MeasurementUnit` every coordinate on every page uses.
  final SpatialUnit unit;

  /// The OCR software's own name, when the document declares one.
  final String? softwareName;

  /// The OCR software's own version, when the document declares one.
  final String? softwareVersion;

  /// The source image's file name, when `sourceImageInformation` carries
  /// one.
  final String? sourceImageName;

  /// The document's pages, in stored order.
  final List<AltoPage> pages;
}

/// One ALTO page: declared dimensions, quality figures, and its blocks.
final class AltoPage {
  /// Creates a page; [ArgumentError] reports non-positive dimensions.
  AltoPage({
    this.id,
    required this.width,
    required this.height,
    this.printedImageNumber,
    this.confidence,
    this.accuracy,
    this.quality,
    required this.blocks,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError.value('$width×$height', 'width, height', 'Must be positive');
    }
  }

  /// The page's `ID`, when declared.
  final String? id;

  /// The declared page width, in the document's unit.
  final double width;

  /// The declared page height, in the document's unit.
  final double height;

  /// The physical page sequence number, when declared.
  final int? printedImageNumber;

  /// The page confidence (`PC`, 0–1), when declared.
  final double? confidence;

  /// The declared OCR accuracy percentage, when declared.
  final double? accuracy;

  /// The declared quality value, when declared.
  final String? quality;

  /// The page's blocks, in stored order.
  final List<AltoBlock> blocks;
}

/// The block kinds the supported ALTO subset distinguishes.
enum AltoBlockKind {
  /// A `TextBlock`: positioned text lines.
  text,

  /// A `ComposedBlock`: nested sub-blocks.
  composed,

  /// An `Illustration`: a non-text image area.
  illustration,

  /// A `GraphicalElement`: rule lines and similar non-text drawing.
  graphicalElement,
}

/// One ALTO block with its rectangle and, for text blocks, its lines.
final class AltoBlock {
  /// Creates a block; [ArgumentError] reports a negative size.
  const AltoBlock({
    required this.kind,
    this.id,
    required this.rect,
    this.rotation,
    this.blockTags,
    required this.lines,
    required this.children,
  });

  /// Which element the block came from.
  final AltoBlockKind kind;

  /// The block's `ID`, when declared.
  final String? id;

  /// The block's rectangle, in the document's unit, top-left origin.
  final SpatialRect rect;

  /// The declared content rotation in degrees, when declared.
  final double? rotation;

  /// The declared `TAGREFS` values, verbatim.
  final List<String>? blockTags;

  /// The text lines; empty for non-text blocks.
  final List<AltoLine> lines;

  /// The composed block's children; empty otherwise.
  final List<AltoBlock> children;
}

/// One ALTO `TextLine` with its strings.
final class AltoLine {
  /// Creates a line; [ArgumentError] reports a negative size.
  const AltoLine({this.id, required this.rect, this.confidence, required this.strings});

  /// The line's `ID`, when declared.
  final String? id;

  /// The line's rectangle, in the document's unit, top-left origin.
  final SpatialRect rect;

  /// The line's word confidence (`WC`, 0–1), when declared.
  final double? confidence;

  /// The line's strings, in stored order (spaces are not strings).
  final List<AltoString> strings;
}

/// One ALTO `String`: a recognized word with its geometry, content, and
/// confidence figures.
final class AltoString {
  /// Creates a string; [ArgumentError] reports a negative size or a
  /// confidence outside 0–1.
  AltoString({
    this.id,
    required this.rect,
    required this.content,
    this.confidence,
    this.characterConfidences,
    this.substitutionType,
    this.substitutionContent,
  }) {
    final value = confidence;
    if (value != null && (value < 0 || value > 1)) {
      throw ArgumentError.value(value, 'confidence', 'Must lie in 0..1');
    }
  }

  /// The string's `ID`, when declared.
  final String? id;

  /// The string's rectangle, in the document's unit, top-left origin.
  final SpatialRect rect;

  /// The recognized text (`CONTENT`).
  final String content;

  /// The word confidence (`WC`, 0–1), when declared.
  final double? confidence;

  /// The per-character confidence codes (`CC`), verbatim, when declared.
  final String? characterConfidences;

  /// The substitution kind (`SUBS_TYPE`), when declared.
  final String? substitutionType;

  /// The substitution content (`SUBS_CONTENT`), when declared.
  final String? substitutionContent;
}
