import 'dart:math' as math;

import '../entities/pdf_layout.dart';

/// One candidate rule grouped per orientation, after collinear
/// merging: horizontal rules carry their y position, vertical rules
/// their x position.
final class _Ruling {
  const _Ruling(this.position, this.start, this.end);

  final double position;
  final double start;
  final double end;

  double get length => end - start;
}

/// Table detection over a page's ruling lines and words, ported from
/// Tabula's `BasicExtractionAlgorithm` and
/// `SpreadsheetExtractionAlgorithm` with the whitespace-aligned
/// fallback the spreadsheet algorithm uses when a page carries no
/// rulings:
///
/// * `spreadsheet` — a complete lattice of horizontal and vertical
///   rulings; cells are the lattice intersections.
/// * `basic` — vertical rulings define the columns, text baselines
///   the rows.
/// * `aligned-columns` — no rulings; column edges are x positions
///   repeated across text rows.
///
/// One table region per page: multi-table pages are a documented
/// limitation. Every refusal comes back as a typed
/// [PdfTableUnsupported] diagnosis, never as a silently empty page.
abstract final class PdfTableDetector {
  const PdfTableDetector._();

  /// Minimum rule length in points to count as table material.
  static const _minRuleLength = 15;

  /// Minimum rows and columns for a detected table.
  static const _minRows = 2;
  static const _minColumns = 2;

  /// Minimum vertical-band width (fraction of page width) between two
  /// aligned column edges.
  static const _minGutterFraction = 0.03;

  /// Detection input caps (the interpreter already caps rules at 4096;
  /// segmentation caps words at 5000).
  static const _maxRules = 2048;
  static const _maxWords = 5000;

  /// Detects at most one table region on the page. Exactly one side
  /// of the result is non-null: the region when the page yields a
  /// table, the diagnosis when a table-shaped area was refused. Both
  /// null only for a page with neither rules nor enough words to try.
  static (PdfTableRegion?, PdfTableUnsupported?) detect({
    required final List<PdfRuleLine> rules,
    required final List<PdfWord> words,
    required final double pageWidth,
    required final double pageHeight,
  }) {
    final usableRules = rules.length > _maxRules ? rules.sublist(0, _maxRules) : rules;
    final usableWords = words.length > _maxWords ? words.sublist(0, _maxWords) : words;
    final (horizontal, vertical) = _splitRules(usableRules);
    final textArea = _textArea(usableWords);

    final lattice = _detectLattice(horizontal, vertical, usableWords);
    if (lattice != null) return lattice;

    final basic = _detectBasic(vertical, usableWords);
    if (basic != null) return basic;

    final aligned = _detectAlignedColumns(usableWords, pageWidth);
    if (aligned != null) return aligned;

    // A page with neither ruling evidence nor an aligned grid is just
    // a plain page — not a refused table. The explicit diagnosis is
    // for pages whose rulings promised a lattice none of the
    // algorithms could accept.
    if (horizontal.isEmpty && vertical.isEmpty) return (null, null);
    if (textArea == null) return (null, null);
    final allRotated = usableWords.isNotEmpty && usableWords.every((final word) => word.rotated);

    return (
      null,
      PdfTableUnsupported(
        x: textArea.$1,
        y: textArea.$2,
        width: textArea.$3 - textArea.$1,
        height: textArea.$4 - textArea.$2,
        reason: allRotated ? 'rotated-rows' : 'too-few-cells',
      ),
    );
  }

  static (List<_Ruling>, List<_Ruling>) _splitRules(final List<PdfRuleLine> rules) {
    final horizontal = <_Ruling>[];
    final vertical = <_Ruling>[];
    for (final rule in rules) {
      if (rule.isHorizontal) {
        horizontal.add(_Ruling(rule.y0, rule.x0, rule.x1));
      } else if (rule.isVertical) {
        vertical.add(_Ruling(rule.x0, rule.y0, rule.y1));
      }
    }

    return (_mergeCollinear(horizontal), _mergeCollinear(vertical));
  }

  /// Merges collinear rules whose extents meet or overlap into maximal
  /// spans — a table's border is usually drawn as many short strokes.
  static List<_Ruling> _mergeCollinear(final List<_Ruling> rules) {
    if (rules.isEmpty) return const [];
    final sorted = List<_Ruling>.of(rules)
      ..sort((final a, final b) {
        final dp = a.position.compareTo(b.position);
        return dp != 0 ? dp : a.start.compareTo(b.start);
      });

    final merged = <_Ruling>[];
    var position = sorted.first.position;
    var start = sorted.first.start;
    var end = sorted.first.end;
    for (var i = 1; i < sorted.length; i++) {
      final next = sorted[i];
      if ((next.position - position).abs() <= 1.5 && next.start <= end + 2) {
        start = math.min(start, next.start);
        end = math.max(end, next.end);
      } else {
        if (end - start >= _minRuleLength) merged.add(_Ruling(position, start, end));
        position = next.position;
        start = next.start;
        end = next.end;
      }
    }
    if (end - start >= _minRuleLength) merged.add(_Ruling(position, start, end));

    return merged;
  }

  /// The page's text bounding box, or null when there is nothing to
  /// detect in.
  static (double, double, double, double)? _textArea(final List<PdfWord> words) {
    if (words.isEmpty) return null;
    var x0 = double.infinity;
    var y0 = double.infinity;
    var x1 = double.negativeInfinity;
    var y1 = double.negativeInfinity;
    for (final word in words) {
      x0 = math.min(x0, word.x);
      y0 = math.min(y0, word.y);
      x1 = math.max(x1, word.right);
      y1 = math.max(y1, word.bottom);
    }

    return (x0, y0, x1, y1);
  }

  /// SpreadsheetExtractionAlgorithm: cluster the rulings into distinct
  /// row/column positions, then accept the grid when every interior
  /// cell is bounded by rulings that span it.
  static (PdfTableRegion?, PdfTableUnsupported?)? _detectLattice(
    final List<_Ruling> horizontal,
    final List<_Ruling> vertical,
    final List<PdfWord> words,
  ) {
    if (horizontal.length < _minRows + 1 || vertical.length < _minColumns + 1) {
      return null;
    }
    final rows = List<_Ruling>.of(horizontal)
      ..sort((final a, final b) => a.position.compareTo(b.position));
    final columns = List<_Ruling>.of(vertical)
      ..sort((final a, final b) => a.position.compareTo(b.position));

    final cells = <List<PdfTableCell>>[];
    var bounded = 0;
    var total = 0;
    for (var r = 0; r < rows.length - 1; r++) {
      final top = rows[r].position;
      final bottom = rows[r + 1].position;
      if (bottom - top < 2) continue;
      final row = <PdfTableCell>[];
      for (var c = 0; c < columns.length - 1; c++) {
        final left = columns[c].position;
        final right = columns[c + 1].position;
        if (right - left < 2) continue;
        total++;
        // The bounding rulings must actually span this cell.
        final topSpanned = rows[r].start <= left + 1 && rows[r].end >= right - 1;
        final bottomSpanned = rows[r + 1].start <= left + 1 && rows[r + 1].end >= right - 1;
        final leftSpanned = columns[c].start <= top + 1 && columns[c].end >= bottom - 1;
        final rightSpanned = columns[c + 1].start <= top + 1 && columns[c + 1].end >= bottom - 1;
        if (!(topSpanned && bottomSpanned && leftSpanned && rightSpanned)) continue;
        bounded++;

        final inside = _wordsIn(words, left, top, right, bottom);
        row.add(
          PdfTableCell(
            row: row.length,
            column: c,
            text: inside.map((final word) => word.text).join(' '),
            x: left,
            y: top,
            width: right - left,
            height: bottom - top,
            ranges: const [],
          ),
        );
      }
      if (row.isNotEmpty) cells.add(row);
    }

    if (cells.length < _minRows ||
        cells.fold<int>(0, (final max, final row) => math.max(max, row.length)) < _minColumns) {
      return null;
    }
    if (bounded < total * 0.9) return null;

    final gridTop = rows.first.position;
    final gridBottom = rows.last.position;
    final gridLeft = columns.first.position;
    final gridRight = columns.last.position;

    // Text crossing a lattice edge means the grid would mix content.
    for (final word in words) {
      if (word.x < gridLeft || word.right > gridRight) continue;
      if (word.y < gridTop || word.bottom > gridBottom) continue;
      if (_crossesAny(word, rows, columns)) {
        return (
          null,
          PdfTableUnsupported(
            x: gridLeft,
            y: gridTop,
            width: gridRight - gridLeft,
            height: gridBottom - gridTop,
            reason: 'text-spans-grid',
          ),
        );
      }
    }

    return (_regionOf(cells, 'spreadsheet'), null);
  }

  static bool _crossesAny(
    final PdfWord word,
    final List<_Ruling> rows,
    final List<_Ruling> columns,
  ) {
    for (final row in rows) {
      if (word.y < row.position &&
          word.bottom > row.position &&
          word.right > row.start &&
          word.x < row.end) {
        return true;
      }
    }
    for (final column in columns) {
      if (word.x < column.position &&
          word.right > column.position &&
          word.bottom > column.start &&
          word.y < column.end) {
        return true;
      }
    }

    return false;
  }

  /// BasicExtractionAlgorithm: vertical rulings define the columns;
  /// text baselines between them define the rows.
  static (PdfTableRegion?, PdfTableUnsupported?)? _detectBasic(
    final List<_Ruling> vertical,
    final List<PdfWord> words,
  ) {
    if (vertical.length < _minColumns + 1) return null;

    final columns = List<_Ruling>.of(vertical)
      ..sort((final a, final b) => a.position.compareTo(b.position));
    final gridLeft = columns.first.position;
    final gridRight = columns.last.position;
    final gridTop = columns.map((final rule) => rule.start).reduce(math.min);
    final gridBottom = columns.map((final rule) => rule.end).reduce(math.max);
    final inside = _wordsIn(words, gridLeft, gridTop, gridRight, gridBottom);
    if (inside.length < _minRows * _minColumns) return null;

    final rows = _rowBands(inside);
    if (rows.length < _minRows) return null;

    final cells = <List<PdfTableCell>>[];
    for (var r = 0; r < rows.length; r++) {
      final (top, bottom) = rows[r];
      final row = <PdfTableCell>[];
      for (var c = 0; c < columns.length - 1; c++) {
        final left = columns[c].position;
        final right = columns[c + 1].position;
        final wordsInCell = _wordsIn(inside, left, top, right, bottom);
        row.add(
          PdfTableCell(
            row: r,
            column: c,
            text: wordsInCell.map((final word) => word.text).join(' '),
            x: left,
            y: top,
            width: right - left,
            height: bottom - top,
            ranges: const [],
          ),
        );
      }
      cells.add(row);
    }

    return (_regionOf(cells, 'basic'), null);
  }

  /// The no-rulings fallback: column edges are word-start x positions
  /// repeated across rows, and every adjacent column pair must show a
  /// real horizontal gutter in most rows — prose text lines touch, a
  /// tabbed grid does not.
  static (PdfTableRegion?, PdfTableUnsupported?)? _detectAlignedColumns(
    final List<PdfWord> words,
    final double pageWidth,
  ) {
    if (words.length < _minRows * _minColumns) return null;

    var rows = _rowBands(words);
    if (rows.length < _minRows) return null;
    rows = _contiguousRows(rows);

    // Candidate column edges: word starts (left-aligned columns), clustered.
    final starts = <double>[
      for (final word in words)
        if (!word.rotated) word.x,
    ]..sort();
    final aligned = <double>[];
    var runStart = 0;
    for (var i = 1; i <= starts.length; i++) {
      if (i == starts.length || starts[i] - starts[runStart] > 4) {
        if (i - runStart >= _minRows + 1) {
          var sum = 0.0;
          for (var j = runStart; j < i; j++) {
            sum += starts[j];
          }
          aligned.add(sum / (i - runStart));
        }
        if (i < starts.length) runStart = i;
      }
    }
    if (aligned.length < _minColumns + 1) return null;
    // Adjacent edges closer than a gutter are one ragged column.
    final gutters = <double>[aligned.first];
    for (final edge in aligned.skip(1)) {
      if (edge - gutters.last >= _minGutterFraction * pageWidth) gutters.add(edge);
    }
    if (gutters.length < _minColumns + 1) return null;

    // The last column's right edge is where its words actually end.
    var gridRight = gutters.last;
    var lastExtent = gutters.last;
    for (final word in words) {
      if (word.x + word.width / 2 >= gutters.last) {
        lastExtent = math.max(lastExtent, word.right);
      }
    }
    if (lastExtent - gutters.last >= _minGutterFraction * pageWidth) {
      gutters.add(lastExtent);
    }
    if (gutters.last - gutters.first > 0.95 * pageWidth) return null;

    final gridLeft = gutters.first;
    gridRight = gutters.last;
    final cells = <List<PdfTableCell>>[];
    var gutterEvidence = 0;
    var gutterChecks = 0;
    for (var r = 0; r < rows.length; r++) {
      final (top, bottom) = rows[r];
      final rowWords = _wordsIn(words, gridLeft, top, gridRight, bottom);
      final row = <PdfTableCell>[];
      for (var c = 0; c < gutters.length - 1; c++) {
        final inCell = _wordsIn(rowWords, gutters[c], top, gutters[c + 1], bottom);
        row.add(
          PdfTableCell(
            row: r,
            column: c,
            text: inCell.map((final word) => word.text).join(' '),
            x: gutters[c],
            y: top,
            width: gutters[c + 1] - gutters[c],
            height: bottom - top,
            ranges: const [],
          ),
        );
      }
      // The row's words must actually leave gutters between columns.
      final lastWordRight = _lastWordRight(rowWords, gutters, gutters.length - 1);
      for (var c = 0; c < gutters.length - 1; c++) {
        final nextFirstLeft = _firstWordLeft(rowWords, gutters, c + 1);
        if (nextFirstLeft == null) continue;
        final prevRight = lastWordRight(c);
        if (prevRight == null) continue;
        gutterChecks++;
        if (nextFirstLeft - prevRight > 6) gutterEvidence++;
      }
      cells.add(row);
    }
    if (gutterChecks == 0 || gutterEvidence < gutterChecks * 2 / 3) return null;
    final filledRows = cells
        .where((final row) => row.where((final cell) => cell.text.isNotEmpty).length >= 2)
        .length;
    if (filledRows < _minRows) return null;

    return (
      PdfTableRegion(
        x: gridLeft,
        y: rows.first.$1,
        width: gridRight - gridLeft,
        height: rows.last.$2 - rows.first.$1,
        rows: cells,
        hasRulingLines: false,
        algorithm: 'aligned-columns',
      ),
      null as PdfTableUnsupported?,
    );
  }

  /// The rightmost word end of one grid column in the current row's
  /// word set, or null when that column is empty.
  static double? Function(int) _lastWordRight(
    final List<PdfWord> rowWords,
    final List<double> gutters,
    final int columnCount,
  ) {
    double? lastWordRight(final int column) {
      if (column < 0 || column >= columnCount) return null;
      double? right;
      for (final word in rowWords) {
        final center = word.x + word.width / 2;
        if (center >= gutters[column] && center < gutters[column + 1]) {
          right = right == null ? word.right : math.max(right, word.right);
        }
      }

      return right;
    }

    return lastWordRight;
  }

  static double? _firstWordLeft(
    final List<PdfWord> rowWords,
    final List<double> gutters,
    final int column,
  ) {
    if (column >= gutters.length) return null;
    double? left;
    for (final word in rowWords) {
      final center = word.x + word.width / 2;
      if (center >= gutters[column] && center < gutters[column + 1]) {
        left = left == null ? word.x : math.min(left, word.x);
      }
    }

    return left;
  }

  /// Keeps the leading run of rows whose vertical pitch stays within
  /// 1.6× the median pitch — a table keeps its rhythm; prose that
  /// starts below the grid breaks it and falls off.
  static List<(double, double)> _contiguousRows(final List<(double, double)> rows) {
    if (rows.length < 2) return rows;
    final pitches = <double>[for (var i = 1; i < rows.length; i++) rows[i].$1 - rows[i - 1].$1]
      ..sort();
    final medianPitch = pitches[pitches.length ~/ 2];

    final kept = <(double, double)>[rows.first];
    for (var i = 1; i < rows.length; i++) {
      if (rows[i].$1 - rows[i - 1].$1 > 1.6 * medianPitch) break;
      kept.add(rows[i]);
    }

    return kept;
  }

  /// Groups [words] into row bands by baseline proximity: words whose
  /// vertical centers sit within half a line height of the band's top
  /// share a row. Rotated words poison the row model and drop out —
  /// a page of rotated rows fails the minimum and stays undetected.
  static List<(double, double)> _rowBands(final List<PdfWord> words) {
    final sorted = List<PdfWord>.of(words)
      ..sort((final a, final b) => (a.y + a.height / 2).compareTo(b.y + b.height / 2));
    final bands = <(double, double)>[];
    var anchor = double.nan;
    var bandBottom = double.negativeInfinity;
    for (final word in sorted) {
      if (word.rotated) continue;
      final center = word.y + word.height / 2;
      if (anchor.isNaN || center - anchor > 0.5 * word.height) {
        if (!anchor.isNaN) bands.add((anchor - 0.2, bandBottom + 0.2));
        anchor = word.y;
        bandBottom = word.bottom;
      } else {
        bandBottom = math.max(bandBottom, word.bottom);
      }
    }
    if (!anchor.isNaN) bands.add((anchor - 0.2, bandBottom + 0.2));

    return bands;
  }

  static List<PdfWord> _wordsIn(
    final List<PdfWord> words,
    final double left,
    final double top,
    final double right,
    final double bottom,
  ) {
    return <PdfWord>[
      for (final word in words)
        if (word.x + word.width / 2 >= left &&
            word.x + word.width / 2 < right &&
            word.y + word.height / 2 >= top &&
            word.y + word.height / 2 < bottom)
          word,
    ];
  }

  static PdfTableRegion _regionOf(final List<List<PdfTableCell>> cells, final String algorithm) {
    var x0 = double.infinity;
    var y0 = double.infinity;
    var x1 = double.negativeInfinity;
    var y1 = double.negativeInfinity;
    for (final row in cells) {
      for (final cell in row) {
        x0 = math.min(x0, cell.x);
        y0 = math.min(y0, cell.y);
        x1 = math.max(x1, cell.right);
        y1 = math.max(y1, cell.bottom);
      }
    }

    return PdfTableRegion(
      x: x0,
      y: y0,
      width: x1 - x0,
      height: y1 - y0,
      rows: cells,
      hasRulingLines: algorithm != 'aligned-columns',
      algorithm: algorithm,
    );
  }
}
