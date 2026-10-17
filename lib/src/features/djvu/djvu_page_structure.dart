import '../../foundation/spatial/spatial_rect.dart';
import '../../foundation/spatial/spatial_text_page.dart';
import '../../foundation/spatial/spatial_text_zone.dart';
import '../../foundation/spatial/spatial_unit.dart';
import '../../foundation/spatial/spatial_zone_lookup.dart';
import '../../foundation/text/canonical_text_snapshot.dart';
import '../../foundation/text/publication_revision.dart';
import '../../foundation/text/revision_digest.dart';
import '../../foundation/text/section_occurrence.dart';
import '../../foundation/text/text_profile.dart';
import 'djvu_text.dart';

/// The extraction profile of DjVu hidden text: the page's TXTz/TXTa zone
/// text rendered with the positional separator convention. The profile is
/// stable for the format's whole contract — the hidden text is stored, not
/// computed, so no plan revision can change its shape.
final TextProfile djvuHiddenTextProfile = TextProfile.of(
  algorithm: 'djvu.hidden-text',
  options: const <String, String>{},
  planRevision: RevisionDigest.textRevision('unseal djvu hidden-text extraction 1'),
);

/// The stable spatial structure of one DjVu page's hidden text: the zone
/// hierarchy with its coordinates, and the canonical text the zones bind
/// to.
///
/// Three views live here, per the PDF structure's separation:
///
/// * the **native tree** ([nativeRoot]) keeps the stored TXTz shapes —
///   DjVu coordinates (bottom-left origin, y upward), all seven zone
///   types, and the stored UTF-8 ranges;
/// * the **shared projection** ([spatialPage]) flattens the text-bearing
///   levels (region/line/word) into the foundation spatial contract —
///   top-left origin, integer-exact rectangles, UTF-16 ranges;
/// * the **canonical text** ([canonicalText]) is the rendered zone text
///   the UTF-16 ranges address, one snapshot under
///   [djvuHiddenTextProfile].
///
/// Zone coordinates follow the reference tools' convention: the values
/// `djvutxt` and `djvused print-txt` report for the same file, which are
/// the stored page-space coordinates, not a rotated display transform.
/// The INFO rotation stays available as [rotation] metadata.
final class DjvuPageStructure {
  /// Builds the structure of one page from its parsed parts.
  DjvuPageStructure({
    required this.pageIndex,
    required this.pageCount,
    required this.width,
    required this.height,
    required this.dpi,
    required this.rotation,
    required this.chunk,
    required this.readingOrderPaths,
  }) {
    if (pageIndex < 0 || pageIndex >= pageCount) {
      throw ArgumentError.value(pageIndex, 'pageIndex', 'Outside the document page count');
    }
    if (pageCount < 1) {
      throw ArgumentError.value(pageCount, 'pageCount', 'Must be positive');
    }
  }

  /// Rebuilds a structure from already-validated parts — the wire
  /// decoder's path.
  factory DjvuPageStructure.restore({
    required final int pageIndex,
    required final int pageCount,
    required final int width,
    required final int height,
    required final int dpi,
    required final int rotation,
    required final DjvuTextChunk chunk,
    required final List<(String, bool)> readingOrderPaths,
  }) {
    return DjvuPageStructure(
      pageIndex: pageIndex,
      pageCount: pageCount,
      width: width,
      height: height,
      dpi: dpi,
      rotation: rotation,
      chunk: chunk,
      readingOrderPaths: readingOrderPaths,
    );
  }

  /// The zero-based page index this structure describes.
  final int pageIndex;

  /// The document's page count.
  final int pageCount;

  /// Original page width, in pixels.
  final int width;

  /// Original page height, in pixels.
  final int height;

  /// Source resolution in dots per inch.
  final int dpi;

  /// Clockwise rotation in degrees from the INFO flags.
  final int rotation;

  /// The page's decoded hidden-text chunk: canonical text and native zone
  /// tree.
  final DjvuTextChunk chunk;

  /// The document reading order the occurrence revision digests.
  final List<(String, bool)> readingOrderPaths;

  /// The page's canonical text: the hidden text rendered with the
  /// positional separator convention, in UTF-16 code units.
  String get canonicalText => chunk.text;

  /// The resource path of this page (`text/page_N.html`, 1-based — the
  /// parser's reading-order convention).
  String get resourcePath => 'text/page-${pageIndex + 1}.html';

  /// The page zone's decoded subtree, or null when the chunk carries text
  /// without zone records.
  DjvuTextZone? get nativeRoot => chunk.root;

  /// The native tree's zones in depth-first stored order.
  List<DjvuTextZone> get nativeZones => _nativeZones ??= _flattenNative();

  /// Whether the page carries zone records at all.
  bool get hasZones => chunk.root != null;

  late List<DjvuTextZone>? _nativeZones;

  /// The shared spatial projection of the page, or null when the page has
  /// no zones. Rectangles convert to the canonical top-left origin; the
  /// region/line/word levels DjVu and ALTO share are kept, while column,
  /// paragraph and character levels stay native-only.
  SpatialTextPage? get spatialPage {
    if (chunk.root == null) return null;

    return _spatialPage ??= _buildSpatialPage();
  }

  late SpatialTextPage? _spatialPage;

  /// Range queries over [spatialPage]'s zones, or null when the page has
  /// no zones.
  SpatialZoneLookup? get lookup {
    final page = spatialPage;
    if (page == null) return null;

    return _lookup ??= SpatialZoneLookup(page);
  }

  late SpatialZoneLookup? _lookup;

  /// The canonical snapshot of the page's hidden text under
  /// [djvuHiddenTextProfile].
  CanonicalTextSnapshot snapshot({required final PublicationRevision identity}) {
    return CanonicalTextSnapshot(
      identity: identity,
      occurrence: _occurrence(),
      profile: djvuHiddenTextProfile,
      text: canonicalText,
    );
  }

  /// Whether `[start, end)` addresses the canonical text — the guard
  /// anchor capture and zone mapping run before trusting a range.
  bool verifiesRange(final int start, final int end) =>
      start >= 0 && start <= end && end <= canonicalText.length;

  SectionOccurrence _occurrence() {
    return SectionOccurrence(
      sectionIndex: pageIndex,
      resourcePath: resourcePath,
      readingOrderRevision: RevisionDigest.readingOrderRevision(readingOrderPaths),
    );
  }

  List<DjvuTextZone> _flattenNative() {
    final root = chunk.root;
    if (root == null) return const <DjvuTextZone>[];
    final result = <DjvuTextZone>[root];
    for (var i = 0; i < result.length; i++) {
      result.addAll(result[i].children);
    }

    return result;
  }

  SpatialTextPage _buildSpatialPage() {
    final zones = <SpatialTextZone>[];
    // The shared projection keeps strictly nested region>line>word
    // shapes. Files that skip a level (a region's words without lines)
    // keep those shapes on the native tree; the projection drops them
    // instead of failing a parse the reference tools accept.
    var regionOpen = false;
    var lineOpen = false;
    void project(final DjvuTextZone zone) {
      switch (zone.type) {
        case djvuZoneTypeRegion:
          _addZone(zones, zone, SpatialZoneKind.region);
          regionOpen = true;
          lineOpen = false;
        case djvuZoneTypeLine when regionOpen:
          _addZone(zones, zone, SpatialZoneKind.line);
          lineOpen = true;
        case djvuZoneTypeWord when lineOpen:
          _addZone(zones, zone, SpatialZoneKind.word);
      }
      for (final child in zone.children) {
        project(child);
      }
    }

    final root = chunk.root!;
    project(root);
    if (zones.isEmpty) {
      // A tree without any region/line/word record has no shared
      // projection; its shapes remain visible on the native tree.
      return _emptyPage();
    }

    return SpatialTextPage(
      width: width.toDouble(),
      height: height.toDouble(),
      unit: SpatialUnit.pixel,
      rotation: rotation,
      textLength: canonicalText.length,
      provenance: const SpatialTextProvenance(
        origin: SpatialTextOrigin.native,
        hasConfidence: false,
      ),
      zones: zones,
    );
  }

  void _addZone(final List<SpatialTextZone> zones, final DjvuTextZone zone, final SpatialZoneKind kind) {
    zones.add(
      SpatialTextZone(
        kind: kind,
        rect: SpatialRect(
          x: zone.xmin.toDouble(),
          y: (height - zone.ymax).toDouble(),
          width: (zone.xmax - zone.xmin).toDouble(),
          height: (zone.ymax - zone.ymin).toDouble(),
        ),
        textStart: zone.utf16Start,
        textEnd: zone.utf16End,
      ),
    );
  }

  SpatialTextPage _emptyPage() {
    return SpatialTextPage(
      width: width.toDouble(),
      height: height.toDouble(),
      unit: SpatialUnit.pixel,
      rotation: rotation,
      textLength: canonicalText.length,
      provenance: const SpatialTextProvenance(
        origin: SpatialTextOrigin.native,
        hasConfidence: false,
      ),
      zones: const <SpatialTextZone>[],
    );
  }
}
