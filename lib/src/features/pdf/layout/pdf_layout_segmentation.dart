import 'dart:math' as math;

import '../entities/pdf_layout.dart';

/// One segmented text line: words grouped by nearest-neighbor
/// orientation and baseline proximity (the Docstrum bottom-up pass,
/// adapted from letter components to word components).
final class PdfSegmentLine {
  /// Builds a line from its words and derives the bbox.
  PdfSegmentLine(this.words)
    : x = words.map((final word) => word.x).reduce(math.min),
      y = words.map((final word) => word.y).reduce(math.min),
      right = words.map((final word) => word.right).reduce(math.max),
      bottom = words.map((final word) => word.bottom).reduce(math.max),
      height = words.map((final word) => word.height).reduce(math.max);

  /// The line's words in reading order along the line's direction.
  final List<PdfWord> words;

  /// Left edge in top-left page points.
  final double x;

  /// Top edge in top-left page points.
  final double y;

  /// Right edge in top-left page points.
  final double right;

  /// Bottom edge in top-left page points.
  final double bottom;

  /// The tallest word's height.
  final double height;

  /// The line's width in points.
  double get width => right - x;

  /// The line's text: its words joined with single spaces.
  String get text => words.map((final word) => word.text).join(' ');

  /// Whether any word renders along a non-horizontal direction.
  bool get rotated => words.any((final word) => word.rotated);
}

/// One segmented block: lines merged by vertical proximity and
/// horizontal overlap, the Docstrum block pass.
final class PdfSegmentBlock {
  /// Builds a block from its lines and derives the bbox.
  PdfSegmentBlock(this.lines)
    : x = lines.map((final line) => line.x).reduce(math.min),
      y = lines.map((final line) => line.y).reduce(math.min),
      right = lines.map((final line) => line.right).reduce(math.max),
      bottom = lines.map((final line) => line.bottom).reduce(math.max);

  /// The block's lines in reading order.
  final List<PdfSegmentLine> lines;

  /// Left edge in top-left page points.
  final double x;

  /// Top edge in top-left page points.
  final double y;

  /// Right edge in top-left page points.
  final double right;

  /// Bottom edge in top-left page points.
  final double bottom;

  /// The block's width in points.
  double get width => right - x;

  /// The block's height in points.
  double get height => bottom - y;

  /// The block's text: its lines joined with `\n`.
  String get text => lines.map((final line) => line.text).join('\n');
}

/// Words to lines to blocks, ported from PdfPig's
/// `DocumentLayoutAnalysis` (Docstrum bottom-up segmentation) adapted
/// to word components: nearest neighbors estimate the dominant
/// orientation, then transitive closure groups words into lines, and
/// lines merge into blocks by vertical proximity and horizontal
/// overlap.
///
/// All stages are bounded: a page beyond the word cap segments what
/// fits and the structure layer reports the rest — bounded work,
/// never a hang.
abstract final class PdfLayoutSegmentation {
  const PdfLayoutSegmentation._();

  /// Nearest neighbors per word the orientation estimate reads.
  static const _neighbors = 4;

  /// The hard cap on segmented words per page.
  static const maxWords = 5000;

  /// The hard cap on merged blocks per page.
  static const maxBlocks = 400;

  /// Angle bins of the orientation histogram (30° each).
  static const _angleBins = 12;

  /// Segments [words] into lines and blocks. Words may arrive in any
  /// order; the result is not yet reading order.
  static (List<PdfSegmentLine>, List<PdfSegmentBlock>) segment(final List<PdfWord> words) {
    if (words.isEmpty) return (const [], const []);

    final usable = words.length > maxWords ? words.sublist(0, maxWords) : words;
    final lines = _linesFromWords(usable);

    return (lines, _blocksFromLines(lines));
  }

  /// Docstrum line building: k-nearest-neighbor angle histogram for
  /// the dominant orientation, then transitive closure of the
  /// same-line relation.
  static List<PdfSegmentLine> _linesFromWords(final List<PdfWord> words) {
    final n = words.length;
    final parent = List<int>.generate(n, (final i) => i);
    int find(final int i) => parent[i] == i ? i : (parent[i] = find(parent[i]));
    void union(final int a, final int b) {
      final (ra, rb) = (find(a), find(b));
      if (ra != rb) parent[rb] = ra;
    }

    // Dominant ORIENTATION from the nearest-neighbor angle histogram,
    // folded to a half turn (a neighbor pair votes the same
    // orientation whether it sits left or right) — the Docstrum
    // construction. Horizontal body text lands near 0; rotated pages
    // or sideways text land on their own dominant angle.
    final histogram = List<double>.filled(_angleBins, 0);
    for (var i = 0; i < n; i++) {
      final distances = <(double, int)>[];
      for (var j = 0; j < n; j++) {
        if (i == j) continue;
        final d = words[i].distanceToCenterSquared(
          words[j].x + words[j].width / 2,
          words[j].y + words[j].height / 2,
        );
        distances.add((d, j));
        if (distances.length > _neighbors * 4) {
          distances.sort((final a, final b) => a.$1.compareTo(b.$1));
          distances.removeRange(_neighbors, distances.length);
        }
      }
      distances.sort((final a, final b) => a.$1.compareTo(b.$1));
      for (var k = 0; k < distances.length && k < _neighbors; k++) {
        final other = words[distances[k].$2];
        final angle = math.atan2(
          other.y + other.height / 2 - (words[i].y + words[i].height / 2),
          other.x + other.width / 2 - (words[i].x + words[i].width / 2),
        );
        final orientation = (angle + math.pi) % math.pi;
        final bin = (orientation / math.pi * _angleBins).floor() % _angleBins;
        histogram[bin] += 1;
      }
    }
    var bestBin = 0;
    for (var bin = 0; bin < _angleBins; bin++) {
      // The half-turn space is circular: smooth with adjacent bins.
      final smoothed =
          histogram[(bin - 1) % _angleBins] +
          2 * histogram[bin] +
          histogram[(bin + 1) % _angleBins];
      final bestSmoothed =
          histogram[(bestBin - 1) % _angleBins] +
          2 * histogram[bestBin] +
          histogram[(bestBin + 1) % _angleBins];
      if (smoothed > bestSmoothed) bestBin = bin;
    }
    // Refine the peak to the cluster's axial mean over the peak bin
    // and its neighbors (weights 1-2-1, wrap-around), computed in
    // doubled-angle space so the 0/180° wrap cannot cancel itself.
    var sumSin2 = 0.0;
    var sumCos2 = 0.0;
    for (var k = -1; k <= 1; k++) {
      final bin = (bestBin + k + _angleBins) % _angleBins;
      final weight = k == 0 ? 2.0 : 1.0;
      final center = (bin + 0.5) / _angleBins * math.pi;
      sumSin2 += weight * math.sin(2 * center);
      sumCos2 += weight * math.cos(2 * center);
    }
    var orientation = math.atan2(sumSin2, sumCos2) / 2;
    if (orientation < 0) orientation += math.pi;
    // Resolve orientation to the reading direction (rightward for
    // horizontal text).
    if (math.cos(orientation) < 0) orientation -= math.pi;
    final (dirX, dirY) = (math.cos(orientation), math.sin(orientation));

    // Same-line relation: near the dominant orientation, small
    // perpendicular offset, along-axis gap within a word-run's reach.
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        final a = words[i];
        final b = words[j];
        final ax = a.x + a.width / 2;
        final ay = a.y + a.height / 2;
        final bx = b.x + b.width / 2;
        final by = b.y + b.height / 2;
        final along = (bx - ax) * dirX + (by - ay) * dirY;
        final perpendicular = -(bx - ax) * dirY + (by - ay) * dirX;
        final smallerHeight = a.height < b.height ? a.height : b.height;
        final smallerSize = a.fontSize < b.fontSize ? a.fontSize : b.fontSize;
        if (along.abs() > 3 * smallerSize + 0.9 * smallerHeight) continue;
        // The perpendicular slack grows with the gap: a coarse (±7.5°)
        // dominant angle must not split a long line.
        if (perpendicular.abs() > 0.45 * smallerHeight + 0.12 * along.abs()) {
          continue;
        }
        union(i, j);
      }
    }

    final groups = <int, List<PdfWord>>{};
    for (var i = 0; i < n; i++) {
      groups.putIfAbsent(find(i), () => <PdfWord>[]).add(words[i]);
    }

    final lines = <PdfSegmentLine>[];
    for (final group in groups.values) {
      group.sort((final a, final b) {
        final pa = a.x * dirX + a.y * dirY;
        final pb = b.x * dirX + b.y * dirY;

        return pa.compareTo(pb);
      });
      lines.add(PdfSegmentLine(group));
    }

    return lines;
  }

  /// Docstrum block building: consecutive lines merge when they sit
  /// close vertically (inside a paragraph's leading) and overlap
  /// horizontally — the same perception the reflow's paragraph
  /// coalescing uses, kept independent of the reflow itself.
  static List<PdfSegmentBlock> _blocksFromLines(final List<PdfSegmentLine> lines) {
    final order = List<PdfSegmentLine>.of(lines)
      ..sort((final a, final b) {
        final dy = a.y.compareTo(b.y);
        return dy != 0 ? dy : a.x.compareTo(b.x);
      });

    final parent = List<int>.generate(order.length, (final i) => i);
    int find(final int i) => parent[i] == i ? i : (parent[i] = find(parent[i]));
    void union(final int a, final int b) {
      final (ra, rb) = (find(a), find(b));
      if (ra != rb) parent[rb] = ra;
    }

    const blockGapFactor = 1.55;
    for (var i = 0; i < order.length; i++) {
      for (var j = i + 1; j < order.length; j++) {
        final a = order[i];
        final b = order[j];
        if (a.rotated != b.rotated) continue;
        final overlap = _horizontalOverlap(a, b);
        if (overlap <= 0) continue;
        final smaller = a.width < b.width ? a.width : b.width;
        if (overlap < 0.25 * smaller) continue;
        final gap = b.y - a.bottom;
        final leading = a.height > b.height ? a.height : b.height;
        if (gap < -0.45 * leading || gap > blockGapFactor * leading) continue;
        union(i, j);
      }
    }

    final groups = <int, List<PdfSegmentLine>>{};
    for (var i = 0; i < order.length; i++) {
      groups.putIfAbsent(find(i), () => <PdfSegmentLine>[]).add(order[i]);
    }

    final blocks = groups.values.map(PdfSegmentBlock.new).toList();
    if (blocks.length > maxBlocks) {
      // Merge the smallest blocks into the first until the cap holds:
      // bounded output, order still resolved later.
      blocks.sort((final a, final b) => a.lines.length.compareTo(b.lines.length));
      while (blocks.length > maxBlocks) {
        final smallest = blocks.removeLast();
        blocks[0] = PdfSegmentBlock([...blocks[0].lines, ...smallest.lines]);
      }
    }

    return blocks;
  }

  static double _horizontalOverlap(final PdfSegmentLine a, final PdfSegmentLine b) {
    final left = a.x > b.x ? a.x : b.x;
    final right = a.right < b.right ? a.right : b.right;

    return right - left;
  }
}
