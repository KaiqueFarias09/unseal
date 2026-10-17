import 'spatial_text_zone.dart';
import 'spatial_unit.dart';

/// Where a spatial text page's zones came from.
enum SpatialTextOrigin {
  /// The publication's own positioned text (DjVu hidden text).
  native,

  /// Text imported from an external OCR document (ALTO).
  importedOcr;
}

/// The provenance of a spatial text page: its [origin], the OCR software
/// when the source names one, and whether the source declared confidence
/// values at all.
///
/// `hasConfidence` stays separate from the per-zone nullable values so an
/// all-null confidence on an imported page reads as "the source omitted
/// them", never as "the import dropped them".
final class SpatialTextProvenance {
  /// Creates a provenance record.
  const SpatialTextProvenance({
    required this.origin,
    required this.hasConfidence,
    this.softwareName,
    this.softwareVersion,
  });

  /// Where the zones came from.
  final SpatialTextOrigin origin;

  /// The OCR software's own name, when the source declares one.
  final String? softwareName;

  /// The OCR software's own version, when the source declares one.
  final String? softwareVersion;

  /// Whether the source declared any confidence values.
  final bool hasConfidence;

  @override
  bool operator ==(final Object other) =>
      other is SpatialTextProvenance &&
      other.origin == origin &&
      other.softwareName == softwareName &&
      other.softwareVersion == softwareVersion &&
      other.hasConfidence == hasConfidence;

  @override
  int get hashCode => Object.hash(origin, softwareName, softwareVersion, hasConfidence);

  @override
  String toString() =>
      'SpatialTextProvenance(${origin.name}, $softwareName $softwareVersion, '
      'confidence: $hasConfidence)';
}

/// One page of positioned text: the shared shape DjVu hidden text and
/// imported ALTO both project onto.
///
/// [zones] holds the page's region/line/word zones in depth-first reading
/// order — each region is followed by its lines, each line by its words.
/// Zone text ranges address the canonical UTF-16 text this page is bound
/// to; the page itself stores only [textLength] so ranges can be validated
/// without keeping the text reachable.
final class SpatialTextPage {
  /// Builds a page and validates its zone nesting; [ArgumentError]
  /// reports a malformed hierarchy or ranges beyond [textLength].
  SpatialTextPage({
    required this.width,
    required this.height,
    required this.unit,
    required this.rotation,
    required this.textLength,
    required this.provenance,
    required this.zones,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError.value(
        '$width×$height',
        'width, height',
        'Page dimensions must be positive',
      );
    }
    if (rotation % 90 != 0 || rotation < 0 || rotation >= 360) {
      throw ArgumentError.value(rotation, 'rotation', 'Must be a multiple of 90 degrees');
    }
    final open = <SpatialZoneKind>[];
    for (var i = 0; i < zones.length; i++) {
      final zone = zones[i];
      if (zone.textEnd > textLength) {
        throw ArgumentError.value(
          zone.textEnd,
          'zones[$i].textEnd',
          'Exceeds the bound text length ($textLength)',
        );
      }
      while (open.isNotEmpty && open.last.index >= zone.kind.index) {
        open.removeLast();
      }
      if (open.length != _expectedOpenDepth(zone.kind)) {
        throw ArgumentError.value(
          zone.kind.name,
          'zones[$i].kind',
          'Does not nest inside the hierarchy the preceding zones opened',
        );
      }
      open.add(zone.kind);
    }
  }

  /// The page width, in [unit].
  final double width;

  /// The page height, in [unit].
  final double height;

  /// The unit every coordinate on this page is expressed in.
  final SpatialUnit unit;

  /// The page's rotation in degrees (a multiple of 90).
  final int rotation;

  /// The bound canonical text's UTF-16 length.
  final int textLength;

  /// Where the zones came from and what the source declared.
  final SpatialTextProvenance provenance;

  /// The zones in depth-first reading order.
  final List<SpatialTextZone> zones;

  /// How many parent levels a zone of [kind] must find open: words live
  /// in lines, lines live in regions, regions open at the page level.
  static int _expectedOpenDepth(final SpatialZoneKind kind) => kind.index;

  /// The region whose area this zone was declared in, by the depth-first
  /// ordering's ancestor rule, or null for a region itself.
  SpatialTextZone? regionOf(final SpatialTextZone zone) {
    final index = zones.indexOf(zone);
    if (index < 0) return null;

    return ancestorOf(zones, index, SpatialZoneKind.region);
  }

  /// The nearest zone of [kind] that [zones[index]] nests in, by the
  /// depth-first ordering, or null when no open ancestor of that kind
  /// exists.
  static SpatialTextZone? ancestorOf(
    final List<SpatialTextZone> zones,
    final int index,
    final SpatialZoneKind kind,
  ) {
    if (kind.index >= zones[index].kind.index) return null;
    for (var j = index - 1; j >= 0; j--) {
      if (zones[j].kind == kind) return zones[j];
      if (zones[j].kind.index < kind.index) return null;
    }

    return null;
  }
}
