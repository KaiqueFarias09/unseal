import '../../../foundation/entities/entities.dart';
import '../../../foundation/text/html_escape.dart';
import '../entities/pdf_page.dart';
import '../entities/pdf_page_text.dart';

/// Tuned constants, values and roles carried over from reflow.py.
const int _pageScanCount = 20;
const int _lineScanCount = 2;
const double _paraFactor = 1.8;
const double _centerFactor = 0.15;
const double _sameSpace = 3.0;
const double _sameIndent = 2.0;

// reflow.py probes these with re.match — anchored at the string
// start — so every alternative carries its own anchor here.
final RegExp _pageNumberPattern = RegExp(
  r'^(.*\d+\s+\w+\s+\d+.*)|^(\s*\d+\s+.*)|^\s*[ivxlcIVXLC]+\s*$',
);
final RegExp _fixedLineNumberPattern = RegExp(r'(^.+[^0-9])\d+\s*$');

/// Reflows extracted PDF pages into standalone HTML documents.
///
/// Implements PDF reflow with tuned constants for font-size statistics,
/// automatic header/footer removal,
/// margin/indent clustering, paragraph
/// coalescing with line unwrapping, alignment and heading
/// detection — adapted to this package's per-page-section model
/// (each page is one section, so cross-page merges become
/// continuation styling instead of re-sectioning).
///
/// The canonical-text invariant rules the output: the visible text
/// of a page's HTML, read through `documentText`, is exactly the
/// page's canonical stream (its lines joined with `\n`). Paragraphs
/// keep the intra-paragraph `\n` separators inside one text node —
/// CSS collapses them into spaces visually — and blocks are
/// separated by literal newlines between tags, so the reflowed
/// reading mode, the facsimile text layer, search and annotations
/// all address the same character space.
///
/// The document-global decisions are factored into [PdfReflowPlan]:
/// [PdfReflowPlan.scan] computes the plan, [PdfReflow.applyWithPlan]
/// renders pages under it, and [PdfReflow.apply] stays the eager
/// whole-document facade (one pass, same bytes as
/// scan + applyWithPlan over the same pages).
class PdfReflow {
  const PdfReflow._();

  /// Builds one reflowed HTML document per page, aligned with
  /// [pageTexts] and [pages] (same length, same order), together
  /// with the post-reflow canonical page texts — the line set the
  /// HTML actually shows (dropped header/footer lines, for one) —
  /// so search, annotations and the facsimile text layer address
  /// exactly the text the reflow renders.
  static (List<TextFile>, List<PdfPageText>) apply(
    final List<PdfPageText> pageTexts,
    final List<PdfPage> pages,
  ) {
    return _render(_Document(pageTexts, pages));
  }

  /// Builds the same output as [apply] for the pages given, using a
  /// plan computed elsewhere by [PdfReflowPlan.scan].
  ///
  /// [firstPageNumber] is the 1-based number of the first page in
  /// [pageTexts]/[pages]: per-page decisions key off the page's
  /// absolute number (odd/even margin statistics, the `page_N`
  /// anchors and file names, and the plan's continuation flags), so
  /// rendering a slice — a single page, in the lazy path — must know
  /// where the slice starts.
  ///
  /// [computeContinuations] replaces the plan's precomputed
  /// continuation marks with a fresh decision over the consecutive
  /// pairs inside the slice, exactly the pass the full pipeline runs —
  /// the lazy reader's way to learn whether page i continues page i−1
  /// when the slice carries both pages. Every input of that decision
  /// is pair-local except the document statistics, which arrive with
  /// [plan], so the verdict matches the whole-document pass.
  static (List<TextFile>, List<PdfPageText>) applyWithPlan(
    final List<PdfPageText> pageTexts,
    final List<PdfPage> pages,
    final PdfReflowPlan plan, {
    final int firstPageNumber = 1,
    final bool computeContinuations = false,
  }) {
    return _render(
      _Document.withPlan(
        pageTexts,
        pages,
        plan,
        firstPageNumber: firstPageNumber,
        computeContinuations: computeContinuations,
      ),
    );
  }

  static (List<TextFile>, List<PdfPageText>) _render(final _Document document) {
    return (
      <TextFile>[
        for (var i = 0; i < document.pages.length; i++)
          TextFile(
            content: document.pages[i].render(document.pages[i].number),
            name: 'page_${document.pages[i].number}.html',
            type: 'html',
            path: 'page_${document.pages[i].number}.html',
          ),
      ],
      <PdfPageText>[
        for (var i = 0; i < document.pages.length; i++) document.pages[i].canonicalText(),
      ],
    );
  }
}

/// The document-global reflow decisions every page's render depends
/// on: the repeated header/footer cuts, the dominant font size, the
/// document-level margin/spacing statistics and the cross-page
/// paragraph continuation marks.
///
/// [PdfReflowPlan.scan] derives the plan by running the global
/// passes over the pages it is given. The header/footer cut only
/// samples the first [_pageScanCount] pages — everything else
/// (dominant font, statistics, continuations) is genuinely
/// whole-document, so a plan built from a partial page sample is
/// faithful only when that sample is the whole document or the
/// globals happen to coincide. Per-page work stays per-page: the
/// plan carries nothing a single page could compute for itself.
final class PdfReflowPlan {
  const PdfReflowPlan._(
    this.headerSkip,
    this.footerSkip,
    this.dominantFontSize,
    this.stats,
    this.continuationPages,
  );

  /// Runs the global reflow passes over [pageTexts]/[pages] and
  /// captures every decision the per-page render consumes.
  static PdfReflowPlan scan(final List<PdfPageText> pageTexts, final List<PdfPage> pages) {
    final document = _Document(pageTexts, pages);

    return document.plan;
  }

  /// Everything at or above this top edge is a running header line.
  final double headerSkip;

  /// Everything at or below this top edge is a running footer line.
  final double footerSkip;

  /// The font size carrying the most characters document-wide; a
  /// line's `em` size is its font size relative to this.
  final double dominantFontSize;

  /// The document-level statistics (dominant top, odd/even margins
  /// and indents, page right, line/paragraph space, page bottom)
  /// the per-page passes read.
  final PdfReflowStats stats;

  /// 1-based numbers of pages whose first paragraph continues the
  /// previous page's last paragraph.
  final Set<int> continuationPages;
}

/// Finds repeated top and bottom lines without coupling the document's
/// pipeline to the details of page-number matching.
final class _HeaderFooterScanner {
  _HeaderFooterScanner(this._pages);

  final List<_Page> _pages;
  final _EdgeMatches _head = _EdgeMatches();
  final _EdgeMatches _foot = _EdgeMatches();

  (double, double) scan() {
    if (_pages.length < 2) {
      return (0, 0);
    }

    var scanned = 0;
    for (final page in _pages) {
      _scanPage(page);
      scanned++;
      if (scanned >= _pageScanCount) {
        break;
      }
    }

    final needed = scanned / 2;
    final header = _skipFor(_head, needed, isHeader: true);
    final footer = _skipFor(_foot, needed, isHeader: false);

    return (header, footer);
  }

  void _scanPage(final _Page page) {
    _head.scanPage(page, fromTop: true);
    _foot.scanPage(page, fromTop: false);
  }

  double _skipFor(final _EdgeMatches matches, final double needed, {required final bool isHeader}) {
    final index = matches.bestIndex(needed);
    if (matches.page == 0 || matches.page > _pages.length || !matches.hasMatch(index, needed)) {
      return 0;
    }

    final lines = _pages[matches.page - 1].lines;
    if (lines.length <= index) {
      return 0;
    }

    return isHeader ? lines[index].bottom + 1 : lines[lines.length - 1 - index].top - 1;
  }
}

final class _EdgeMatches {
  final List<String> _text = List<String>.filled(_lineScanCount, '');
  final List<int> _exact = List<int>.filled(_lineScanCount, 0);
  final List<int> _numbered = List<int>.filled(_lineScanCount, 0);
  final List<int> _fixed = List<int>.filled(_lineScanCount, 0);
  int page = 0;
  String _fixedPrefix = '';

  void scanPage(final _Page pageData, {required final bool fromTop}) {
    if (pageData.lines.isEmpty) {
      return;
    }
    for (var index = 0; index < _lineScanCount; index++) {
      final lineIndex = fromTop ? index : pageData.lines.length - 1 - index;
      if (!_isInEdge(pageData, lineIndex, fromTop)) {
        break;
      }
      _record(index, pageData.number, pageData.lines[lineIndex].text);
    }
  }

  bool _isInEdge(final _Page pageData, final int index, final bool fromTop) {
    if (index < 0 || index >= pageData.lines.length) {
      return false;
    }

    final line = pageData.lines[index];

    return fromTop ? line.top <= pageData.height / 2 : line.top >= pageData.height / 2;
  }

  void _record(final int index, final int pageNumber, final String value) {
    if (_text[index].isEmpty) {
      _text[index] = value;

      return;
    }
    if (_text[index] == value) {
      _exact[index]++;
      page = page == 0 ? pageNumber : page;

      return;
    }
    if (_pageNumberPattern.hasMatch(value)) {
      _numbered[index]++;
      page = page == 0 ? pageNumber : page;

      return;
    }

    final fixed = _fixedLineNumberPattern.firstMatch(value);
    if (fixed == null || fixed.group(1)!.isEmpty) {
      return;
    }

    final prefix = fixed.group(1)!;
    if (_fixedPrefix.isEmpty) {
      _fixedPrefix = prefix;
    } else if (_fixedPrefix == prefix) {
      _fixed[index]++;
      page = page == 0 ? pageNumber : page;
    }
  }

  int bestIndex(final double needed) {
    var result = 0;
    for (var index = 0; index < _lineScanCount; index++) {
      if (hasMatch(index, needed)) {
        result = index;
      }
    }

    return result;
  }

  bool hasMatch(final int index, final double needed) {
    return _exact[index] > needed || _numbered[index] > needed || _fixed[index] > needed;
  }
}

final class _IndentClusters {
  _IndentClusters(final Map<double, int> values) : _working = Map<double, int>.of(values);

  final Map<double, int> _working;

  double mostPopular() {
    var best = 0.0;
    var bestCount = 0;
    _working.forEach((final value, final count) {
      if (count > 0 && bestCount <= count) {
        bestCount = count;
        best = value;
      }
    });

    return best;
  }

  (double, double, int) clusterAround(final double center) {
    var low = center;
    var high = center;
    var total = 0;
    _working.forEach((final value, final count) {
      if (count > 0 && (center - value).abs() <= _sameIndent) {
        if (value < low) low = value;
        if (value > high) high = value;
        total += count;
        _working[value] = -count;
      }
    });

    return (low, high, total);
  }
}

/// The whole-document reflow state and pipeline.
final class _Document {
  /// The full pipeline: every global pass runs over the pages given.
  _Document(
    final List<PdfPageText> pageTexts,
    final List<PdfPage> pages, {
    final int firstPageNumber = 1,
  }) {
    _buildPages(pageTexts, pages, firstPageNumber);
    if (this.pages.isEmpty) return;

    _collectFontStatistics();
    _findHeaderFooter();
    _removeHeaderFooter();
    for (final page in this.pages) {
      page.reorderColumns();
    }
    for (final page in this.pages) {
      page.findMargins(
        tops,
        page.number.isOdd ? indentsOdd : indentsEven,
        lineSpaces,
        bottoms,
        rights,
      );
    }
    _setupStats();
    for (final page in this.pages) {
      page.secondPass(stats);
    }
    _markContinuations(stats);
  }

  /// The plan-driven pipeline: the global decisions arrive with
  /// [plan], so only per-page work runs — the path a lazy reader
  /// takes when pages materialize one at a time. With
  /// [computeContinuations] the slice's own consecutive pairs get a
  /// fresh continuation pass (under the plan's statistics) instead of
  /// the plan's precomputed marks.
  _Document.withPlan(
    final List<PdfPageText> pageTexts,
    final List<PdfPage> pages,
    final PdfReflowPlan plan, {
    final int firstPageNumber = 1,
    final bool computeContinuations = false,
  }) {
    _buildPages(pageTexts, pages, firstPageNumber);
    if (this.pages.isEmpty) return;

    headerSkip = plan.headerSkip;
    footerSkip = plan.footerSkip;
    _applyPlanFontStatistics(plan);
    _removeHeaderFooter();
    for (final page in this.pages) {
      page.reorderColumns();
    }
    for (final page in this.pages) {
      page.secondPass(plan.stats);
    }
    if (computeContinuations) {
      _markContinuations(plan.stats);
    } else {
      _applyPlanContinuations(plan);
    }
  }

  /// The plan capturing everything this document computed globally.
  PdfReflowPlan get plan => PdfReflowPlan._(headerSkip, footerSkip, dominantFontSize, stats, <int>{
    for (final page in pages)
      if (page.lines.isNotEmpty && page.lines.first.continuesPreviousPage) page.number,
  });

  void _buildPages(
    final List<PdfPageText> pageTexts,
    final List<PdfPage> pages,
    final int firstPageNumber,
  ) {
    for (var i = 0; i < pageTexts.length && i < pages.length; i++) {
      this.pages.add(_Page(firstPageNumber + i, pages[i].width, pages[i].height, pageTexts[i]));
    }
  }

  /// Applies [plan]'s dominant font size — the second half of
  /// [_collectFontStatistics], with the document-wide vote already
  /// taken.
  void _applyPlanFontStatistics(final PdfReflowPlan plan) {
    for (final page in pages) {
      for (final line in page.lines) {
        line.fontSizeEm = (line.fontSize / plan.dominantFontSize * 100).round() / 100;
      }
    }
    // Part 0 keeps the paragraph's own em; merged parts already
    // carry the em they joined with.
    for (final page in pages) {
      for (final line in page.lines) {
        line.syncFirstPartEm();
      }
    }
  }

  /// Applies the plan's continuation marks: the merge decision was
  /// made document-wide, so a page only honors the verdict about its
  /// own first paragraph.
  void _applyPlanContinuations(final PdfReflowPlan plan) {
    for (final page in pages) {
      if (page.lines.isEmpty || !plan.continuationPages.contains(page.number)) continue;

      final first = page.lines.first;
      first.continuesPreviousPage = true;
      first.indented = 0;
    }
  }

  final List<_Page> pages = <_Page>[];

  final Map<double, int> tops = <double, int>{};
  final Map<double, int> indentsOdd = <double, int>{};
  final Map<double, int> indentsEven = <double, int>{};
  final Map<double, int> lineSpaces = <double, int>{};
  final Map<double, int> bottoms = <double, int>{};
  final Map<double, int> rights = <double, int>{};

  double dominantFontSize = 12;

  final PdfReflowStats stats = PdfReflowStats();

  double headerSkip = 0;
  double footerSkip = 0;

  void _collectFontStatistics() {
    // The font size carrying the most characters becomes 1em
    // (reflow.py FontSizeStats: later entries win ties).
    final charsBySize = <double, int>{};
    for (final page in pages) {
      for (final line in page.lines) {
        charsBySize.update(
          line.fontSize,
          (final value) => value + line.text.length,
          ifAbsent: () => line.text.length,
        );
      }
    }

    var best = -1;
    charsBySize.forEach((final size, final chars) {
      if (chars >= best) {
        best = chars;
        dominantFontSize = size;
      }
    });
    if (best < 0) dominantFontSize = 12;
    for (final page in pages) {
      for (final line in page.lines) {
        line.fontSizeEm = (line.fontSize / dominantFontSize * 100).round() / 100;
      }
    }
    // Part 0 keeps the paragraph's own em; merged parts already
    // carry the em they joined with.
    for (final page in pages) {
      for (final line in page.lines) {
        line.syncFirstPartEm();
      }
    }
  }

  /// Scans the first [_pageScanCount] pages for repeated header and
  /// footer lines — identical text, page-number patterns or a fixed
  /// prefix plus a number — and requires more than half the scanned
  /// pages to agree (reflow.py `find_header_footer`).
  void _findHeaderFooter() {
    final (header, footer) = _HeaderFooterScanner(pages).scan();
    headerSkip = header;
    footerSkip = footer;
  }

  void _removeHeaderFooter() {
    for (final page in pages) {
      page.lines.removeWhere((final line) {
        return (headerSkip > 0 && line.top < headerSkip) ||
            (footerSkip > 0 && line.top > footerSkip);
      });
    }
  }

  /// The document-level statistics reflow.py `setup_stats` derives:
  /// dominant top, odd/even left-and-indent clusters, page right,
  /// line and paragraph spacing, document bottom.
  void _setupStats() {
    var topCount = 0;
    tops.forEach((final top, final count) {
      if (topCount < count) {
        topCount = count;
        stats.top = top;
      }
    });

    _setIndents(indentsOdd, true);
    _setIndents(indentsEven, false);

    rights.forEach((final value, final count) {
      if (stats.right < value) stats.right = value;
    });

    // No-indent heuristic: when the indent sits over 10% of the
    // line width away from the left margin, treat indent values as
    // noise (documents that indent nothing).
    if (stats.right > stats.leftMinOdd &&
        stats.indentMinOdd - stats.leftMinOdd > (stats.right - stats.leftMinOdd) * 0.10) {
      stats.indentMinOdd = stats.indentMaxOdd = stats.leftMinOdd;
      stats.indentMinEven = stats.indentMaxEven = stats.leftMinEven;
    }

    // Line space = most popular inter-line gap (clusters within
    // SAME_SPACE merge); paragraph space = the next cluster, capped
    // and back-filled by PARA_FACTOR.
    final gaps = lineSpaces.keys.toList()..sort();
    var lineK = 0.0;
    var lineC = 0;
    for (final gap in gaps) {
      if (lineK == 0) {
        lineK = gap;
        lineC = lineSpaces[gap]!;
      } else if ((lineK - gap).abs() <= _sameSpace) {
        if (gap > lineK) lineK = gap;
        if (lineSpaces[gap]! < lineC) lineC = lineSpaces[gap]!;
      } else {
        break;
      }
    }

    var paraK = 0.0;
    for (final gap in gaps) {
      if (lineSpaces[gap]! >= lineC) continue;
      if (paraK == 0) {
        paraK = gap;
      } else if ((paraK - gap).abs() <= _sameSpace) {
        if (gap > paraK) paraK = gap;
      } else {
        break;
      }
    }

    if (paraK == 0 || paraK == lineK) paraK = (lineK * _paraFactor).roundToDouble();
    if (lineK > paraK) {
      final swap = paraK;
      paraK = lineK;
      lineK = swap;
    }
    stats.lineSpace = lineK;
    stats.paraSpace = paraK > lineK * _paraFactor ? (lineK * _paraFactor).roundToDouble() : paraK;

    bottoms.forEach((final bottom, final count) {
      if (bottom > stats.bottom) stats.bottom = bottom;
    });
  }

  /// The three-cluster indent analysis of reflow.py `set_indents`:
  /// most-popular left, most-popular indent, and the rarer third
  /// cluster that sometimes is the true indent.
  void _setIndents(final Map<double, int> indents, final bool odd) {
    final clusters = _IndentClusters(indents);
    final (leftLow, leftHigh, _) = clusters.clusterAround(clusters.mostPopular());
    var (indentLow, indentHigh, indentCount) = clusters.clusterAround(clusters.mostPopular());
    final (thirdLow, thirdHigh, thirdCount) = clusters.clusterAround(clusters.mostPopular());
    if (thirdLow > 0 &&
        thirdLow < indentLow &&
        thirdLow > leftLow &&
        thirdCount > indentCount / 2) {
      indentLow = thirdLow;
      indentHigh = thirdHigh;
    }
    if (indentLow == 0) {
      indentLow = leftHigh + _sameIndent + 1;
      indentHigh = indentLow;
    }
    var marginLow = leftLow;
    var marginHigh = leftHigh == 0 ? leftLow : leftHigh;
    if (marginLow > indentLow) {
      final swapLow = indentLow;
      final swapHigh = indentHigh;
      indentLow = marginLow;
      indentHigh = marginHigh;
      marginLow = swapLow;
      marginHigh = swapHigh == 0 ? swapLow : swapHigh;
    }

    if (odd) {
      stats.leftMinOdd = marginLow;
      stats.leftMaxOdd = marginHigh;
      stats.indentMinOdd = indentLow;
      stats.indentMaxOdd = indentHigh == 0 ? indentLow : indentHigh;
    } else {
      stats.leftMinEven = marginLow;
      stats.leftMaxEven = marginHigh;
      stats.indentMinEven = indentLow;
      stats.indentMaxEven = indentHigh == 0 ? indentLow : indentHigh;
    }
  }

  /// Cross-page paragraph continuation (the merge decision of
  /// reflow.py `merge_pages`, restyled): when the previous page's
  /// last paragraph runs to the bottom and the next page starts
  /// flush-left mid-sentence, the next page's first paragraph is
  /// marked as a continuation — it keeps its own page (sections are
  /// 1:1 with pages) but renders unindented and flush to the top.
  ///
  /// [statistics] are the document-level stats the decision reads:
  /// the full pipeline passes its own, the plan-driven pipeline the
  /// plan's — identical objects in the eager path.
  void _markContinuations(final PdfReflowStats statistics) {
    const orphanLines = 5;

    if (statistics.lineSpace <= 0) return;
    final orphanSpace = statistics.bottom - orphanLines * statistics.lineSpace;
    for (var i = 1; i < pages.length; i++) {
      final previous = pages[i - 1];
      final next = pages[i];
      if (previous.lines.isEmpty || next.lines.isEmpty) continue;

      final last = previous.lines.last;
      final first = next.lines.first;
      if (last.bottom <= orphanSpace) continue;
      if (first.tag != 'p' || first.left >= previous.statsLeftMin + first.averageCharacterWidth) {
        continue;
      }

      final lastSpare = previous.textWidth - last.finalWidth;
      final firstWord = RegExp(r'^([^ ]+)\s').firstMatch(first.text);
      // The first word of the next page as a pixel width; a
      // lowercase ending (or start) short-circuits to "merges".
      var mergedLen = firstWord == null
          ? 0.0
          : firstWord.group(1)!.length * first.averageCharacterWidth;
      if (RegExp(r'.*[a-z,-]\s*$').hasMatch(last.parts.last.text) ||
          RegExp(r'^\s*[a-z,-]').hasMatch(first.text)) {
        mergedLen = first.right;
      }

      if (first.top <= statistics.top + previous.averageTextHeight && !(lastSpare > mergedLen)) {
        first.continuesPreviousPage = true;
        first.indented = 0;
      }
    }
  }
}

/// Document-level statistics shared by the per-page passes.
///
/// The pipeline fills these once per document (per plan scan) and
/// every page's render then reads them.
final class PdfReflowStats {
  /// The most popular first-line top across pages.
  double top = 0;

  /// The lowest line bottom seen across pages.
  double bottom = 0;

  /// The rightmost line edge seen across pages.
  double right = 0;

  /// The most popular inter-line gap.
  double lineSpace = 0;

  /// The paragraph-separation gap derived from the remaining gap
  /// clusters, capped and back-filled from [lineSpace].
  double paraSpace = 0;

  /// Odd pages: the left-margin cluster.
  double leftMinOdd = 0;

  /// Odd pages: the left-margin cluster's upper bound.
  double leftMaxOdd = 0;

  /// Odd pages: the indent cluster.
  double indentMinOdd = 0;

  /// Odd pages: the indent cluster's upper bound.
  double indentMaxOdd = 0;

  /// Even pages: the left-margin cluster.
  double leftMinEven = 0;

  /// Even pages: the left-margin cluster's upper bound.
  double leftMaxEven = 0;

  /// Even pages: the indent cluster.
  double indentMinEven = 0;

  /// Even pages: the indent cluster's upper bound.
  double indentMaxEven = 0;
}

/// One page under reflow: its working lines and derived margins.
final class _Page {
  _Page(this.number, this.width, this.height, final PdfPageText pageText)
    : images = List<PdfImageBox>.of(pageText.images),
      contentStreamCount = pageText.contentStreamCount,
      skippedContentStreams = pageText.skippedContentStreams {
    for (final line in pageText.lines) {
      if (line.text.trim().isEmpty) continue;
      lines.add(_Line.of(line));
      final last = lines.last;
      if (last.left < leftMargin) leftMargin = last.left;
      if (last.right > rightMargin) rightMargin = last.right;
    }
    if (lines.isEmpty) {
      leftMargin = 0;
      rightMargin = 0;
    }
    averageTextHeight = lines.isEmpty
        ? 0
        : lines.map((final line) => line.height).reduce((final a, final b) => a + b) / lines.length;
  }

  final int number;
  final double width;
  final double height;

  final List<_Line> lines = <_Line>[];
  final List<PdfImageBox> images;
  final int contentStreamCount;
  final int skippedContentStreams;
  bool columnOrderApplied = false;

  /// Reorders clearly separated, text-only columns after the edge-line scan.
  /// Ambiguous layouts keep geometric order rather than guessing.
  void reorderColumns() {
    if (images.isNotEmpty || lines.length < 6 || width <= 0) return;

    final byStart = List<_Line>.of(lines)..sort((final a, final b) => a.left.compareTo(b.left));
    for (var split = 3; split <= byStart.length - 3; split++) {
      final startGap = byStart[split].left - byStart[split - 1].left;
      if (startGap < width * 0.2) continue;

      final rightStart = byStart[split].left;
      final gutter = width * 0.02;
      final left = lines.where((final line) => line.right <= rightStart - gutter).toList();
      final right = lines.where((final line) => line.left >= rightStart).toList();
      if (left.length < 3 || right.length < 3) continue;
      if (left.where((final line) => line.width >= width * 0.12).length < 2 ||
          right.where((final line) => line.width >= width * 0.12).length < 2) {
        continue;
      }

      final firstColumnTop = left.first.top < right.first.top ? left.first.top : right.first.top;
      final lastColumnBottom = <_Line>[
        ...left,
        ...right,
      ].map((final line) => line.bottom).reduce((final a, final b) => a > b ? a : b);
      final columnLines = <_Line>{...left, ...right};
      final spanning = lines.where((final line) => !columnLines.contains(line));
      if (spanning.any(
        (final line) => line.top >= firstColumnTop && line.top <= lastColumnBottom,
      )) {
        continue;
      }

      final overlappingRows = left.where(
        (final line) => right.any(
          (final other) =>
              (line.top - other.top).abs() <=
              (line.height > other.height ? line.height : other.height),
        ),
      );
      if (overlappingRows.length < 2) continue;

      int comparePosition(final _Line a, final _Line b) {
        final vertical = a.top.compareTo(b.top);
        return vertical == 0 ? a.left.compareTo(b.left) : vertical;
      }

      final top = spanning.where((final line) => line.top < firstColumnTop).toList()
        ..sort(comparePosition);
      final bottom = spanning.where((final line) => line.top > lastColumnBottom).toList()
        ..sort(comparePosition);
      left.sort(comparePosition);
      right.sort(comparePosition);
      lines
        ..clear()
        ..addAll(top)
        ..addAll(left)
        ..addAll(right)
        ..addAll(bottom);
      columnOrderApplied = true;
      return;
    }
  }

  double averageTextHeight = 0;
  double leftMargin = double.infinity;
  double rightMargin = 0;

  double statsLeftMin = 0;
  double statsLeftMax = 0;
  double statsIndentMin = 0;
  double statsIndentMax = 0;
  double statsRight = 0;
  double statsMarginPx = 16;

  double get textWidth => rightMargin - leftMargin;

  /// Accumulates the margin/spacing histograms of reflow.py
  /// `find_margins`: first-line tops, inter-line gaps, left indents
  /// (odd/even split), page bottoms and rights.
  void findMargins(
    final Map<double, int> tops,
    final Map<double, int> indents,
    final Map<double, int> lineSpaces,
    final Map<double, int> bottoms,
    final Map<double, int> rights,
  ) {
    var maxBottom = 0.0;
    var maxRight = 0.0;
    var lastTop = 0.0;
    var first = true;
    for (final line in lines) {
      final top = line.top;
      if (first) {
        tops.update(top, (final value) => value + 1, ifAbsent: () => 1);
        first = false;
      } else {
        final space = (top - lastTop).abs();
        if (line.height <= space) {
          lineSpaces.update(space, (final value) => value + 1, ifAbsent: () => 1);
        }
      }
      lastTop = top;
      if (line.bottom > maxBottom) maxBottom = line.bottom;
      if (line.right > maxRight) maxRight = line.right;
      indents.update(line.left, (final value) => value + 1, ifAbsent: () => 1);
    }
    if (maxBottom > 0) bottoms.update(maxBottom, (final value) => value + 1, ifAbsent: () => 1);
    if (maxRight > 0) rights.update(maxRight, (final value) => value + 1, ifAbsent: () => 1);
  }

  /// Paragraph coalescing, alignment and heading detection — the
  /// reflow.py `second_pass` over `coalesce_paras` and
  /// `check_centered`, minus the markup-only conditions.
  void secondPass(final PdfReflowStats stats) {
    if (number.isOdd) {
      statsLeftMin = stats.leftMinOdd;
      statsLeftMax = stats.leftMaxOdd;
      statsIndentMin = stats.indentMinOdd;
      statsIndentMax = stats.indentMaxOdd;
    } else {
      statsLeftMin = stats.leftMinEven;
      statsLeftMax = stats.leftMaxEven;
      statsIndentMin = stats.indentMinEven;
      statsIndentMax = stats.indentMaxEven;
    }
    statsRight = stats.right;
    statsMarginPx = 16;

    _coalesceParagraphs(stats);
    _checkCentered(stats);
  }

  void _coalesceParagraphs(final PdfReflowStats stats) {
    const sectionFactor = 1.3;

    var index = 0;
    _Line? last;
    while (index < lines.length) {
      final line = lines[index];
      if (last != null && _canMerge(last, line, stats)) {
        last.merge(line);
        lines.removeAt(index);
        continue;
      }
      if (line.tag == 'p' &&
          line.indented == 0 &&
          line.align != 'C' &&
          line.left > statsLeftMax + line.averageCharacterWidth) {
        if (statsIndentMin > 0 && statsIndentMin <= line.left && line.left <= statsIndentMax) {
          line.indented = 1;
        } else {
          line.marginLeft = ((line.left - statsLeftMin) / statsMarginPx + 0.5).round();
        }
      }
      if (last != null &&
          stats.paraSpace > 0 &&
          line.bottom - last.bottom > stats.paraSpace * sectionFactor) {
        line.blankLineBefore = true;
      }
      last = line;
      index++;
    }
  }

  bool _canMerge(final _Line first, final _Line second, final PdfReflowStats stats) {
    const lineFactor = 0.2;
    const unwrapFactor = 0.45;

    final sameLeft =
        second.left >= first.lastLeft - _sameIndent && second.left <= first.lastLeft + _sameIndent;
    final leftish =
        (second.left < statsLeftMin + second.averageCharacterWidth &&
            (sameLeft || (second.left < first.lastLeft && first.indented > 0))) ||
        (sameLeft && first.indented == 0 && second.left >= statsIndentMin) ||
        (sameLeft && first.indented == second.indented && second.indented > 1) ||
        (second.left >= first.lastLeft && second.bottom <= first.bottom);

    return leftish &&
        first.bottom + stats.lineSpace + stats.lineSpace * lineFactor >= second.bottom &&
        first.finalWidth > width * unwrapFactor &&
        !_adjacentQuotes(first.parts.last.text, second.text);
  }

  void _checkCentered(final PdfReflowStats stats) {
    const rightFactor = 1.8;

    var first = true;
    var contents = false;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final leftMargin = line.lastLeft;
      final rightMargin = line.bottom - line.top > stats.lineSpace * 2
          ? width - line.lastRight
          : width - line.right;
      final xMargin = index > 0 ? lines[index - 1].lastLeft : null;
      final yMargin = index < lines.length - 1 ? lines[index + 1].lastLeft : null;

      if (RegExp(r'^\s*(table of )?contents\s*$', caseSensitive: false).hasMatch(line.text)) {
        contents = true;
        line.tag = 'h2';
      }
      if ((leftMargin < statsIndentMin || leftMargin > statsIndentMax) &&
          leftMargin > statsLeftMax &&
          leftMargin != xMargin &&
          leftMargin != yMargin &&
          leftMargin >= rightMargin - rightMargin * _centerFactor &&
          leftMargin <= rightMargin + rightMargin * _centerFactor) {
        line.align = 'C';
      } else if (leftMargin > statsIndentMax && leftMargin > rightMargin * rightFactor) {
        line.align = 'R';
      }
      if (!contents) {
        if (RegExp(r'^\s*[iIxXvV]+\s*$').hasMatch(line.text)) {
          line.tag = 'h3';
        } else if (first && line.align == 'C' && RegExp(r'^\s*\d+\s*$').hasMatch(line.text)) {
          line.tag = 'h2';
        } else if (RegExp(r'^\s*part\s[A-Za-z0-9]+$', caseSensitive: false).hasMatch(line.text)) {
          line.tag = 'h1';
        } else if (RegExp(r'^\s*chapter\s', caseSensitive: false).hasMatch(line.text) ||
            RegExp(r'^\s*(prologue|epilogue)\s*$', caseSensitive: false).hasMatch(line.text) ||
            (first &&
                line.align == 'C' &&
                RegExp(r'^\s*[a-z -]+\s*$', caseSensitive: false).hasMatch(line.text)) ||
            (first && RegExp(r'^\s*[A-Z -]+\s*$').hasMatch(line.text))) {
          line.tag = 'h2';
        }
      }
      first = false;
    }
  }

  /// The post-reflow canonical text of this page: the paragraph
  /// parts flattened back to lines (original geometry, original
  /// order) — the exact text stream the rendered HTML carries.
  PdfPageText canonicalText() {
    final lines = <PdfTextLine>[];
    for (final line in this.lines) {
      for (final part in line.parts) {
        lines.add(
          PdfTextLine(
            text: part.text,
            x: part.left,
            y: part.top,
            width: part.width,
            height: part.height,
            fontSize: part.fontSize,
            rotated: part.rotated,
          ),
        );
      }
    }
    if (!columnOrderApplied) {
      lines.sort((final a, final b) {
        final dy = a.y - b.y;

        return dy.abs() < 0.5 ? a.x.compareTo(b.x) : dy.compareTo(0);
      });
    }

    return PdfPageText(
      lines: lines,
      images: images,
      contentStreamCount: contentStreamCount,
      skippedContentStreams: skippedContentStreams,
      columnOrderApplied: columnOrderApplied,
    );
  }

  /// Renders the page's HTML with the canonical-text invariant:
  /// blocks joined by `\n`, paragraph lines joined by `\n` inside
  /// one text node (font-size spans add no characters).
  String render(final int anchor) {
    final blocks = <_Block>[
      for (final line in lines) _Block(top: line.top, left: line.left, line: line),
      for (final image in images)
        if (image.path.isNotEmpty) _Block(top: image.y, left: image.x, image: image),
    ];
    if (!columnOrderApplied) {
      blocks.sort((final a, final b) {
        final dy = a.top - b.top;

        return dy.abs() < 0.5 ? a.left.compareTo(b.left) : dy.compareTo(0);
      });
    }

    final out = StringBuffer();
    if (blocks.isEmpty) {
      // Blank pages keep their page_N anchor reachable from the
      // outline; an empty span carries no text.
      out.write('<span id="page_$anchor"></span>');
    }
    for (var i = 0; i < blocks.length; i++) {
      if (i > 0) out.write('\n');
      final block = blocks[i];
      if (block.line != null) {
        out.write(block.line!.openTag(i == 0 ? anchor : 0));
        block.line!.writeBody(out);
        out.write('</${block.line!.tag}>');
      } else {
        out.write('<div class="elv-pdf-image"><img src="${block.image!.path}" alt=""/></div>');
      }
    }

    return '<!DOCTYPE html><html><head><title></title></head>'
        '<body class="elv-pdf">$out</body></html>';
  }
}

/// A render block: a paragraph line or an image placement.
final class _Block {
  const _Block({required this.top, required this.left, this.line, this.image});

  final double top;
  final double left;
  final _Line? line;
  final PdfImageBox? image;
}

/// One source line kept by a paragraph: its text, em size and the
/// geometry the facsimile text layer positions it by.
final class _Part {
  const _Part(
    this.text,
    this.em,
    this.top,
    this.left,
    this.width,
    this.height,
    this.fontSize,
    this.rotated,
  );

  final String text;
  final double em;
  final double top;
  final double left;
  final double width;
  final double height;
  final double fontSize;
  final bool rotated;
}

/// One mutable working line — a paragraph once coalescing joins it
/// with its continuation lines.
final class _Line {
  _Line.of(final PdfTextLine line)
    : text = line.text,
      top = line.y.roundToDouble(),
      left = line.x.roundToDouble(),
      width = line.width.roundToDouble(),
      height = line.height.roundToDouble(),
      fontSize = line.fontSize,
      rotated = line.rotated,
      parts = <_Part>[
        // The part keeps the unrounded geometry: canonical lines
        // must byte-match the extractor's output, rounding is for
        // reflow decisions only.
        _Part(line.text, 1, line.y, line.x, line.width, line.height, line.fontSize, line.rotated),
      ] {
    right = left + width;
    bottom = top + height;
    finalWidth = right;
    lastLeft = left;
    lastRight = right;
    averageCharacterWidth = width / (text.isEmpty ? 1 : text.length);
    if (averageCharacterWidth < 0.1) averageCharacterWidth = 0.1;
  }

  String text;
  final List<_Part> parts;

  double top;
  double left;
  double width;
  double height;
  late double right;
  late double bottom;

  double fontSize;
  double fontSizeEm = 1;
  final bool rotated;

  String tag = 'p';
  String align = 'L';
  int indented = 0;
  int marginLeft = 0;
  late double lastLeft;
  late double lastRight;
  late double finalWidth;
  late double averageCharacterWidth;
  bool blankLineBefore = false;
  bool continuesPreviousPage = false;

  /// Merges [other] into this paragraph — reflow.py `coalesce`
  /// without the inline-markup handling. The separator stays the
  /// canonical `\n` (rendered as a space by CSS).
  void merge(final _Line other) {
    top = top < other.top ? top : other.top;
    bottom = bottom > other.bottom ? bottom : other.bottom;
    left = left < other.left ? left : other.left;
    right = right > other.right ? right : other.right;
    width += other.width;
    finalWidth = other.left + other.width;
    height = bottom - top;
    fontSize = fontSize > other.fontSize ? fontSize : other.fontSize;
    fontSizeEm = fontSizeEm > other.fontSizeEm ? fontSizeEm : other.fontSizeEm;
    lastLeft = other.left;
    lastRight = other.right;
    text = '$text\n${other.text}';
    parts.addAll(other.parts);
    averageCharacterWidth = width / (text.isEmpty ? 1 : text.length);
    if (averageCharacterWidth < 0.1) averageCharacterWidth = 0.1;
  }

  String openTag(final int anchor) {
    final attributes = StringBuffer();
    if (anchor > 0) attributes.write(' id="page_$anchor"');
    final style = StringBuffer();
    if (continuesPreviousPage) {
      style.write('margin-top:0;text-indent:0;');
    } else if (blankLineBefore) {
      style.write('margin-top:2em;');
    }
    if (align == 'C') {
      style.write('text-align:center;');
    } else if (align == 'R') {
      style.write('text-align:right;');
    } else if (indented > 0) {
      style.write('text-indent:${indented}em;');
    } else if (marginLeft > 0) {
      style.write('margin-left:${marginLeft}em;');
    }
    if (style.isNotEmpty) attributes.write(' style="${style.toString()}"');

    return '<$tag$attributes>';
  }

  /// Records the paragraph's own em on its first part once font
  /// statistics are known.
  void syncFirstPartEm() {
    final first = parts.first;
    if (first.em == 1) {
      parts[0] = _Part(
        first.text,
        fontSizeEm,
        first.top,
        first.left,
        first.width,
        first.height,
        first.fontSize,
        first.rotated,
      );
    }
  }

  void writeBody(final StringBuffer out) {
    for (var i = 0; i < parts.length; i++) {
      if (i > 0) out.write('\n');
      final part = parts[i];
      final escaped = escapeHtml(part.text);
      if (part.em != 0 && part.em != 1) {
        out.write('<span style="font-size:${_formatEm(part.em)}em">$escaped</span>');
      } else {
        out.write(escaped);
      }
    }
  }
}

String _formatEm(final double em) {
  return em == em.roundToDouble() ? em.toInt().toString() : em.toString();
}

bool _adjacentQuotes(final String first, final String second) {
  final lastChar = RegExp(r'.*([^ ])\s*$').firstMatch(first)?.group(1) ?? ' ';
  final firstChar = RegExp(r'\s*([^ ])').firstMatch(second)?.group(1) ?? ' ';

  return (lastChar == '"' && firstChar == '"') ||
      (lastChar == '\u2019' && firstChar == '\u2018') ||
      (lastChar == '\u201D' && firstChar == '\u201C');
}
