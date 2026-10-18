import '../../foundation/spatial/spatial_rect.dart';
import 'page_exception.dart';

/// A parsed PAGE XML document: the sidecar's metadata and its page with
/// positioned content.
///
/// The model keeps the format's own detail — native polygons, baselines,
/// reading order groups, TextEquiv alternatives with confidence and
/// language — that the shared spatial contract deliberately leaves out.
/// PAGE 2019 coordinates are integer pixel positions on the page image
/// (top-left origin per the schema), so no unit or scale step exists.
final class PageXmlDocument {
  /// Creates a document from validated parts.
  const PageXmlDocument({
    this.pcGtsId,
    required this.creator,
    this.created,
    this.lastChange,
    this.comments,
    required this.page,
  });

  /// The root's `pcGtsId`, when declared.
  final String? pcGtsId;

  /// The `Metadata/Creator` value; blank when the sidecar declares an
  /// empty creator.
  final String creator;

  /// The `Metadata/Created` timestamp, verbatim, when declared.
  final String? created;

  /// The `Metadata/LastChange` timestamp, verbatim, when declared.
  final String? lastChange;

  /// The optional `Metadata/Comments` value.
  final String? comments;

  /// The one page the PcGts document describes.
  final PageXmlPage page;
}

/// One PAGE page: declared image identity and dimensions, orientation
/// and confidence figures, its regions in stored order, and the
/// optional reading order.
final class PageXmlPage {
  /// Creates a page; [ArgumentError] reports non-positive dimensions.
  PageXmlPage({
    required this.imageFilename,
    required this.width,
    required this.height,
    this.xResolution,
    this.yResolution,
    this.resolutionUnit,
    this.orientation,
    this.confidence,
    this.type,
    this.primaryLanguage,
    this.border,
    this.printSpace,
    this.readingOrder,
    required this.regions,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError.value('$width×$height', 'width, height', 'Must be positive');
    }
    final value = confidence;
    if (value != null && (value < 0 || value > 1)) {
      throw ArgumentError.value(value, 'confidence', 'Must lie in 0..1');
    }
  }

  /// The source image's declared filename (`imageFilename`).
  final String imageFilename;

  /// The declared image width in pixels (`imageWidth`).
  final int width;

  /// The declared image height in pixels (`imageHeight`).
  final int height;

  /// The declared horizontal resolution, when present.
  final double? xResolution;

  /// The declared vertical resolution, when present.
  final double? yResolution;

  /// The resolution unit (`PPI`, `PPCM`, `other`), when declared.
  final String? resolutionUnit;

  /// The page-level orientation hint in degrees, when declared. This is
  /// a display-space correction value: coordinates stay in page space.
  final double? orientation;

  /// The page confidence (0–1), when declared.
  final double? confidence;

  /// The declared page type token, when declared.
  final String? type;

  /// The page's primary language token, when declared.
  final String? primaryLanguage;

  /// The page border polygon, when declared.
  final PageXmlPolygon? border;

  /// The print space polygon, when declared.
  final PageXmlPolygon? printSpace;

  /// The reading order, when the page declares one.
  final PageXmlReadingOrder? readingOrder;

  /// The page's regions in stored order; the reading order re-sequences
  /// them for reading.
  final List<PageXmlRegion> regions;

  /// The page orientation as the shared projection's rotation: the
  /// declared orientation when it is an exact multiple of 90 degrees,
  /// normalized into 0..359, and 0 otherwise — fractional skew stays a
  /// display concern and the projection never invents a rotation.
  int get rotation {
    final value = orientation;
    if (value == null || value % 90 != 0) return 0;

    return ((value.round() % 360) + 360) % 360;
  }

  /// The regions in reading order: the declared
  /// [readingOrder]'s text regions in index sequence, followed by the
  /// text regions it does not mention, in stored order. Returns the
  /// stored order when the page declares no reading order.
  List<PageXmlRegion> regionsInReadingOrder() {
    final order = readingOrder;
    if (order == null) return regions;
    final refs = order.regionRefs();
    final byId = {for (final region in regions) region.id: region};
    final ordered = <PageXmlRegion>[];
    final seen = <String>{};
    for (final ref in refs) {
      final region = byId[ref];
      if (region == null || region.kind != PageXmlRegionKind.text || !seen.add(ref)) continue;
      ordered.add(region);
    }
    for (final region in regions) {
      if (region.kind == PageXmlRegionKind.text && seen.add(region.id)) {
        ordered.add(region);
      }
    }

    return ordered;
  }
}

/// The fifteen region kinds the PAGE 2019 schema defines.
enum PageXmlRegionKind {
  /// A `TextRegion`: positioned text with lines and words.
  text,

  /// An `ImageRegion`: a raster image area.
  image,

  /// A `LineDrawingRegion`: line-art drawing.
  lineDrawing,

  /// A `GraphicRegion`: generic graphic content.
  graphic,

  /// A `TableRegion`: tabular structure.
  table,

  /// A `ChartRegion`: chart or diagram content.
  chart,

  /// A `MapRegion`: map content.
  map,

  /// A `SeparatorRegion`: rule lines between content.
  separator,

  /// A `MathsRegion`: mathematical formula content.
  maths,

  /// A `ChemRegion`: chemical structure content.
  chem,

  /// A `MusicRegion`: musical notation content.
  music,

  /// An `AdvertRegion`: advertisement content.
  advert,

  /// A `NoiseRegion`: erroneously detected content.
  noise,

  /// An `UnknownRegion`: content the producer could not classify.
  unknown,

  /// A `CustomRegion`: producer-defined content.
  custom;

  /// The element local name this kind parses from.
  String get elementName => switch (this) {
    PageXmlRegionKind.text => 'TextRegion',
    PageXmlRegionKind.image => 'ImageRegion',
    PageXmlRegionKind.lineDrawing => 'LineDrawingRegion',
    PageXmlRegionKind.graphic => 'GraphicRegion',
    PageXmlRegionKind.table => 'TableRegion',
    PageXmlRegionKind.chart => 'ChartRegion',
    PageXmlRegionKind.map => 'MapRegion',
    PageXmlRegionKind.separator => 'SeparatorRegion',
    PageXmlRegionKind.maths => 'MathsRegion',
    PageXmlRegionKind.chem => 'ChemRegion',
    PageXmlRegionKind.music => 'MusicRegion',
    PageXmlRegionKind.advert => 'AdvertRegion',
    PageXmlRegionKind.noise => 'NoiseRegion',
    PageXmlRegionKind.unknown => 'UnknownRegion',
    PageXmlRegionKind.custom => 'CustomRegion',
  };
}

/// One region of any kind, with its native polygon. Text regions carry
/// their lines, language and reading-order attributes; the other kinds
/// stay geometry-only.
final class PageXmlRegion {
  /// Creates a region; text regions must own their id because reading
  /// order references address them by id.
  const PageXmlRegion({
    required this.kind,
    required this.id,
    required this.polygon,
    this.orientation,
    this.readingOrientation,
    this.textType,
    this.primaryLanguage,
    this.secondaryLanguage,
    this.readingDirection,
    this.textLineOrder,
    this.continuation,
    this.custom,
    this.text,
    this.lines = const <PageXmlTextLine>[],
  });

  /// Which region element this parsed.
  final PageXmlRegionKind kind;

  /// The region's `id` (schema-required).
  final String id;

  /// The region's native polygon.
  final PageXmlPolygon polygon;

  /// The region's orientation hint in degrees, when declared.
  final double? orientation;

  /// The text region's reading orientation hint, when declared.
  final double? readingOrientation;

  /// The text region's nature token (`paragraph`, `heading`, …), when
  /// declared.
  final String? textType;

  /// The text region's primary language token, when declared.
  final String? primaryLanguage;

  /// The text region's secondary language token, when declared.
  final String? secondaryLanguage;

  /// The declared reading direction token, when declared.
  final String? readingDirection;

  /// The declared text line order token, when declared.
  final String? textLineOrder;

  /// Whether the region continues another region, when declared.
  final bool? continuation;

  /// The `custom` attribute, verbatim, when declared.
  final String? custom;

  /// The region-level text content, when the sidecar declares any.
  final PageXmlTextContent? text;

  /// The text region's lines in stored order; empty for other kinds.
  final List<PageXmlTextLine> lines;
}

/// One `TextLine`: native polygon, optional baseline, language, and
/// its words in stored order.
final class PageXmlTextLine {
  /// Creates a line.
  const PageXmlTextLine({
    required this.id,
    required this.polygon,
    this.baseline,
    this.primaryLanguage,
    this.readingDirection,
    this.index,
    this.text,
    this.words = const <PageXmlWord>[],
  });

  /// The line's `id` (schema-required).
  final String id;

  /// The line's native polygon.
  final PageXmlPolygon polygon;

  /// The line's baseline polyline, when declared.
  final PageXmlBaseline? baseline;

  /// The line's primary language token, when declared.
  final String? primaryLanguage;

  /// The declared reading direction token, when declared.
  final String? readingDirection;

  /// The line's position within its region, when declared.
  final int? index;

  /// The line-level text content, when the sidecar declares any.
  final PageXmlTextContent? text;

  /// The line's words in stored order.
  final List<PageXmlWord> words;
}

/// One `Word`: native polygon, language, and its text content.
final class PageXmlWord {
  /// Creates a word.
  const PageXmlWord({
    required this.id,
    required this.polygon,
    this.language,
    this.readingDirection,
    this.text,
  });

  /// The word's `id` (schema-required).
  final String id;

  /// The word's native polygon.
  final PageXmlPolygon polygon;

  /// The word's language token, when declared.
  final String? language;

  /// The declared reading direction token, when declared.
  final String? readingDirection;

  /// The word's text content, when the sidecar declares any.
  final PageXmlTextContent? text;
}

/// A native PAGE polygon: the stored integer point list and the
/// geometry confidence when the sidecar declares one.
///
/// The points travel exactly as stored. The bounding box is the
/// explicitly derived projection: computed on demand from the points,
/// never a second stored geometry.
final class PageXmlPolygon {
  /// Creates a polygon; [ArgumentError] reports an empty point list.
  // ignore: matching the other validating constructors, this one is not
  // const because it validates its arguments.
  PageXmlPolygon({required this.points, this.confidence}) {
    if (points.isEmpty) {
      throw ArgumentError.value(points, 'points', 'PAGE polygons carry at least one point');
    }
    final value = confidence;
    if (value != null && (value < 0 || value > 1)) {
      throw ArgumentError.value(value, 'confidence', 'Must lie in 0..1');
    }
  }

  /// The stored `(x, y)` points in image pixel coordinates.
  final List<(int, int)> points;

  /// The polygon confidence (0–1), when declared.
  final double? confidence;

  /// The derived bounding box: `(x, y, width, height)` over the stored
  /// points — the projection the shared spatial contract carries.
  (int, int, int, int) get boundingBox {
    var minX = points.first.$1;
    var minY = points.first.$2;
    var maxX = minX;
    var maxY = minY;
    for (final (x, y) in points) {
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }

    return (minX, minY, maxX - minX, maxY - minY);
  }

  /// The derived bounding box as a shared rectangle in pixel space.
  SpatialRect get boundingRect {
    final (x, y, width, height) = boundingBox;

    return SpatialRect(
      x: x.toDouble(),
      y: y.toDouble(),
      width: width.toDouble(),
      height: height.toDouble(),
    );
  }
}

/// A `Baseline` polyline: the stored points and its confidence when
/// declared.
final class PageXmlBaseline {
  /// Creates a baseline; [ArgumentError] reports fewer than two points.
  PageXmlBaseline({required this.points, this.confidence}) {
    if (points.length < 2) {
      throw ArgumentError.value(points, 'points', 'A baseline carries at least two points');
    }
    final value = confidence;
    if (value != null && (value < 0 || value > 1)) {
      throw ArgumentError.value(value, 'confidence', 'Must lie in 0..1');
    }
  }

  /// The stored `(x, y)` baseline points in image pixel coordinates.
  final List<(int, int)> points;

  /// The baseline confidence (0–1), when declared.
  final double? confidence;
}

/// One `TextEquiv` alternative: the Unicode text the schema requires,
/// the optional plain-text variant, the declared order index, and the
/// declared confidence.
final class PageXmlTextEquiv {
  /// Creates an alternative; [ArgumentError] reports confidence
  /// outside 0–1.
  PageXmlTextEquiv({required this.unicode, this.plainText, this.index, this.confidence}) {
    final value = confidence;
    if (value != null && (value < 0 || value > 1)) {
      throw ArgumentError.value(value, 'confidence', 'Must lie in 0..1');
    }
  }

  /// The Unicode content of this alternative (schema-required).
  final String unicode;

  /// The optional simple-form variant.
  final String? plainText;

  /// The declared sort index; the schema reads the lowest index as the
  /// main content. Null when the sidecar declares none.
  final int? index;

  /// The declared confidence (0–1), when present.
  final double? confidence;
}

/// The ordered `TextEquiv` set of one region, line, or word, with the
/// declared deterministic choice: the first alternative in document
/// order among those with the lowest index; alternatives without an
/// index sort after every indexed one at equal rank.
final class PageXmlTextContent {
  /// Creates the content set; [ArgumentError] reports an empty list.
  PageXmlTextContent({required this.alternatives})
    : chosen = alternatives.reduce((final best, final candidate) {
        final bestIndex = best.index;
        final candidateIndex = candidate.index;
        if (candidateIndex == null) return best;
        if (bestIndex == null) return candidate;

        return candidateIndex < bestIndex ? candidate : best;
      }) {
    if (alternatives.isEmpty) {
      throw ArgumentError.value(
        alternatives,
        'alternatives',
        'Text content carries at least one TextEquiv',
      );
    }
  }

  /// Every alternative in document order.
  final List<PageXmlTextEquiv> alternatives;

  /// The chosen alternative under the declared policy.
  final PageXmlTextEquiv chosen;

  /// The chosen alternative's Unicode text.
  String get text => chosen.unicode;

  /// The chosen alternative's confidence, when declared.
  double? get confidence => chosen.confidence;
}

/// A page's `ReadingOrder`: the root group tree with validated,
/// deterministic sequencing.
final class PageXmlReadingOrder {
  /// Creates a reading order over its root group; the parser validates
  /// refs, duplicates and cycles before building this.
  const PageXmlReadingOrder({required this.root, required this.confidence});

  /// The root group (`OrderedGroup` or `UnorderedGroup`).
  final PageXmlGroup root;

  /// The reading order's own confidence, when declared.
  final double? confidence;

  /// Every region reference in deterministic traversal order: siblings
  /// with declared indexes sort by index then document order, siblings
  /// without keep document order; groups recurse depth-first.
  List<String> regionRefs() => root.regionRefs();
}

/// One node inside a reading order group tree: a region reference or a
/// nested group. The parse variant decides whether an `index` is
/// required (the indexed group styles) or forbidden (the unordered
/// styles); the model carries it as nullable either way.
sealed class PageXmlOrderNode {
  /// The declared sibling index, when the node's element carries one.
  final int? index;

  /// The node's position among its siblings in document order.
  final int documentOrder;

  /// Creates the node.
  const PageXmlOrderNode({required this.index, required this.documentOrder});
}

/// A reference to one region by id.
final class PageXmlRegionRef extends PageXmlOrderNode {
  /// Creates the reference.
  const PageXmlRegionRef({
    required this.regionRef,
    required super.index,
    required super.documentOrder,
  });

  /// The referenced region's id.
  final String regionRef;
}

/// A nested reading order group, ordered or unordered.
final class PageXmlGroup extends PageXmlOrderNode {
  /// Creates the group.
  const PageXmlGroup({
    required this.id,
    required this.isOrdered,
    required this.items,
    this.regionRef,
    this.caption,
    required super.index,
    required super.documentOrder,
  });

  /// The group's `id` (schema-required).
  final String id;

  /// Whether the group's children sequence by declared index.
  final bool isOrdered;

  /// The group's children in document order; [regionRefs] applies the
  /// deterministic sequencing.
  final List<PageXmlOrderNode> items;

  /// The optional parent-region link of an indexed group.
  final String? regionRef;

  /// The group's caption, when declared.
  final String? caption;

  /// The region references reachable from this group in deterministic
  /// order: indexed siblings sort by index then document order,
  /// unordered siblings keep document order, groups recurse
  /// depth-first.
  List<String> regionRefs() {
    final siblings = List<PageXmlOrderNode>.of(items);
    siblings.sort((final a, final b) {
      final aIndex = a.index;
      final bIndex = b.index;
      if (aIndex != null && bIndex != null) {
        final byIndex = aIndex.compareTo(bIndex);
        if (byIndex != 0) return byIndex;
      } else if (aIndex != null) {
        return -1;
      } else if (bIndex != null) {
        return 1;
      }

      return a.documentOrder.compareTo(b.documentOrder);
    });
    final refs = <String>[];
    for (final node in siblings) {
      if (node is PageXmlRegionRef) {
        refs.add(node.regionRef);
      } else if (node is PageXmlGroup) {
        refs.addAll(node.regionRefs());
      }
    }

    return refs;
  }
}

/// Throws a [PageXmlException] when [condition] does not hold; the
/// parser's shared guard.
void requirePageXml(final bool condition, final String message) {
  if (!condition) throw PageXmlException(message);
}
