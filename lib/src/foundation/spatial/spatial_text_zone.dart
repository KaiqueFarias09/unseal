import 'spatial_rect.dart';

/// The hierarchy levels DjVu hidden text and ALTO share.
///
/// The format-specific levels between them — DjVu columns, paragraphs and
/// characters, ALTO non-text blocks — stay in their features. This union
/// carries the levels both formats attach positioned text to.
enum SpatialZoneKind {
  /// A block-level area: a DjVu region, an ALTO text block.
  region,

  /// One line of text inside a region.
  line,

  /// One word inside a line.
  word;

  /// Whether zones of this kind nest directly inside zones of [parent].
  bool nestsIn(final SpatialZoneKind parent) {
    switch (this) {
      case SpatialZoneKind.region:
        return false;
      case SpatialZoneKind.line:
        return parent == SpatialZoneKind.region;
      case SpatialZoneKind.word:
        return parent == SpatialZoneKind.line;
    }
  }
}

/// One positioned text zone: a hierarchy [kind], a rectangle in the page's
/// canonical top-left space, and the UTF-16 code-unit range it selects in
/// the page's canonical text.
///
/// Ranges are inclusive start, exclusive end — the same convention search,
/// locators, anchors and the canonical snapshot contract use. [confidence]
/// carries OCR word confidence when the source declared one (ALTO `WC`,
/// 0–1); DjVu native zones have none and stay null instead of inventing a
/// value.
final class SpatialTextZone {
  /// Creates a zone; [ArgumentError] reports inverted ranges and
  /// confidences outside 0–1.
  SpatialTextZone({
    required this.kind,
    required this.rect,
    required this.textStart,
    required this.textEnd,
    this.confidence,
  }) {
    if (textStart < 0) {
      throw ArgumentError.value(textStart, 'textStart', 'Must be non-negative');
    }
    if (textEnd < textStart) {
      throw ArgumentError.value(textEnd, 'textEnd', 'Must not precede textStart');
    }
    final value = confidence;
    if (value != null && (value < 0 || value > 1)) {
      throw ArgumentError.value(value, 'confidence', 'Must lie in 0..1');
    }
  }

  /// The hierarchy level this zone occupies.
  final SpatialZoneKind kind;

  /// The zone's rectangle in the page's top-left space and unit.
  final SpatialRect rect;

  /// The first UTF-16 code unit the zone selects.
  final int textStart;

  /// One past the last UTF-16 code unit the zone selects.
  final int textEnd;

  /// The OCR confidence in 0–1, or null when the source declares none.
  final double? confidence;

  /// The zone's text length in UTF-16 code units.
  int get utf16Length => textEnd - textStart;

  @override
  bool operator ==(final Object other) =>
      other is SpatialTextZone &&
      other.kind == kind &&
      other.rect == rect &&
      other.textStart == textStart &&
      other.textEnd == textEnd &&
      other.confidence == confidence;

  @override
  int get hashCode => Object.hash(kind, rect, textStart, textEnd, confidence);

  @override
  String toString() =>
      'SpatialTextZone(${kind.name}, ${rect.x},${rect.y} ${rect.width}×${rect.height}, '
      '$textStart..$textEnd)';
}
