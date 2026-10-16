import 'dart:math' as math;

import '../entities/pdf_layout.dart';
import 'pdf_layout_segmentation.dart';

/// One detected column: its x span and the blocks inside it.
typedef _PdfColumnGroup = (double, double, List<PdfSegmentBlock>);

/// The page's reading order: a recursive XY-cut over segmented blocks —
/// empty horizontal bands split the page into stacked regions first,
/// then each region splits into columns across empty vertical gutters —
/// with header/footer roles from the reflow plan's cuts.
///
/// A content block crossing a candidate gutter vetoes the column split
/// for its region (single-column layouts stay single-column); running
/// headers and footers may cross gutters. Ambiguous layouts keep
/// geometric order rather than guessing.
abstract final class PdfReadingOrder {
  const PdfReadingOrder._();

  /// The hard cap on detected columns per page region.
  static const maxColumns = 6;

  /// A vertical gap larger than this multiple of the median block
  /// height starts a new horizontal region.
  static const _regionGapFactor = 2.0;

  /// An empty vertical band must be this wide (fraction of page width)
  /// to split columns.
  static const _minGutterFraction = 0.03;

  /// Computes the reading order of [blocks]; returns the ordered
  /// blocks (the input list order is untouched) and the column
  /// regions of the widest multi-column region (empty on single-column
  /// pages).
  static (List<PdfSegmentBlock>, List<PdfColumnRegion>) order(
    final List<PdfSegmentBlock> blocks, {
    required final double pageWidth,
    final double headerSkip = 0,
    final double footerSkip = 0,
  }) {
    if (blocks.isEmpty) return (const [], const []);

    PdfBlockRole roleOf(final PdfSegmentBlock block) {
      final middle = block.y + block.height / 2;
      if (headerSkip > 0 && middle < headerSkip) return PdfBlockRole.header;
      if (footerSkip > 0 && middle > footerSkip) return PdfBlockRole.footer;

      return PdfBlockRole.content;
    }

    final ordered = <PdfSegmentBlock>[];
    var widestColumns = <PdfColumnRegion>[];
    for (final region in _horizontalRegions(blocks)) {
      final (regionOrder, columns) = _orderRegion(region, pageWidth, roleOf);
      ordered.addAll(regionOrder);
      if (columns.length > widestColumns.length) widestColumns = columns;
    }

    return (ordered, widestColumns);
  }

  /// Splits [blocks] into stacked horizontal regions wherever the
  /// vertical gap between consecutive blocks exceeds
  /// [_regionGapFactor] × the median block height.
  static List<List<PdfSegmentBlock>> _horizontalRegions(final List<PdfSegmentBlock> blocks) {
    final sorted = List<PdfSegmentBlock>.of(blocks)..sort((final a, final b) => a.y.compareTo(b.y));
    final heights = List<double>.of(sorted.map((final block) => block.height))..sort();
    final medianHeight = heights[heights.length ~/ 2];
    final threshold = _regionGapFactor * medianHeight;

    final regions = <List<PdfSegmentBlock>>[];
    var current = <PdfSegmentBlock>[sorted.first];
    var bottom = sorted.first.bottom;
    for (final block in sorted.skip(1)) {
      if (block.y - bottom > threshold) {
        regions.add(current);
        current = <PdfSegmentBlock>[];
      }
      current.add(block);
      bottom = math.max(bottom, block.bottom);
    }
    regions.add(current);

    return regions;
  }

  /// Orders one horizontal region: column split when an empty gutter
  /// separates the blocks, top-to-bottom order otherwise.
  static (List<PdfSegmentBlock>, List<PdfColumnRegion>) _orderRegion(
    final List<PdfSegmentBlock> region,
    final double pageWidth,
    final PdfBlockRole Function(PdfSegmentBlock) roleOf,
  ) {
    final columns = _detectColumns(region, pageWidth, roleOf);
    void sortByY(final List<PdfSegmentBlock> group) {
      group.sort((final a, final b) {
        final dy = a.y.compareTo(b.y);
        return dy != 0 ? dy : a.x.compareTo(b.x);
      });
    }

    if (columns.length < 2) {
      final ordered = List<PdfSegmentBlock>.of(region);
      sortByY(ordered);

      return (ordered, const <PdfColumnRegion>[]);
    }

    final ordered = <PdfSegmentBlock>[];
    final columnRegions = <PdfColumnRegion>[];
    for (final (start, end, members) in columns) {
      sortByY(members);
      ordered.addAll(members);
      columnRegions.add(
        PdfColumnRegion(
          x: start,
          width: end - start,
          blockIndexes: List<int>.generate(
            members.length,
            (final i) => ordered.length - members.length + i,
          ),
        ),
      );
    }

    return (ordered, columnRegions);
  }

  /// Column detection inside one horizontal region: consecutive block
  /// edges define candidate bands; a band wider than
  /// [_minGutterFraction] of the page that no content block overlaps
  /// is a gutter. Header and footer blocks may overlap gutters.
  static List<_PdfColumnGroup> _detectColumns(
    final List<PdfSegmentBlock> region,
    final double pageWidth,
    final PdfBlockRole Function(PdfSegmentBlock) roleOf,
  ) {
    if (pageWidth <= 0 || region.length < 2) return const <_PdfColumnGroup>[];
    final left = region.map((final block) => block.x).reduce(math.min);
    final right = region.map((final block) => block.right).reduce(math.max);

    bool overlapsBand(final PdfSegmentBlock block, final double a, final double b) {
      if (block.x >= b || block.right <= a) return false;

      return roleOf(block) == PdfBlockRole.content;
    }

    final minGutter = _minGutterFraction * pageWidth;
    final edges = <double>{
      for (final block in region) ...<double>[block.x, block.right],
    }.where((final edge) => edge > left && edge < right).toList()..sort();

    final gutters = <(double, double)>[];
    for (var i = 0; i < edges.length - 1; i++) {
      final (a, b) = (edges[i], edges[i + 1]);
      if (b - a < minGutter) continue;
      final overlapped = region.any((final block) => overlapsBand(block, a, b));
      if (!overlapped) {
        gutters.add((a, b));
        if (gutters.length >= maxColumns - 1) break;
      }
    }
    if (gutters.isEmpty) return const <_PdfColumnGroup>[];

    // Columns are the spans between the gutters, bounded by the
    // region's own text extent.
    final columns = <_PdfColumnGroup>[];
    var cursor = left;
    for (final (a, b) in gutters) {
      final members = <PdfSegmentBlock>[];
      for (final block in region) {
        final center = (block.x + block.right) / 2;
        if (center >= cursor && center < a) members.add(block);
      }
      if (members.isEmpty) return const <_PdfColumnGroup>[];
      columns.add((cursor, a, members));
      cursor = b;
    }
    final tail = <PdfSegmentBlock>[];
    for (final block in region) {
      final center = (block.x + block.right) / 2;
      if (center >= cursor && center <= right) tail.add(block);
    }
    if (tail.isEmpty) return const <_PdfColumnGroup>[];
    columns.add((cursor, right, tail));

    return columns;
  }
}
