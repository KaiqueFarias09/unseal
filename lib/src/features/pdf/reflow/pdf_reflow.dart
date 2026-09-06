import '../../../foundation/entities/entities.dart';
import '../entities/pdf_page.dart';
import '../entities/pdf_page_text.dart';

/// Reflows extracted PDF pages into standalone HTML documents.
///
/// A behavioral re-expression of Calibre's
/// `src/calibre/ebooks/pdf/reflow.py` (GPLv3; ported behavior and
/// tuned constants, no code): font-size statistics, automatic
/// header/footer removal, margin/indent clustering, paragraph
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
    final document = _Document(pageTexts, pages);

    return (
      <TextFile>[
        for (var i = 0; i < pageTexts.length; i++)
          TextFile(
            content: document.pages[i].render(i + 1),
            name: 'page_${i + 1}.html',
            type: 'html',
            path: 'page_${i + 1}.html',
          ),
      ],
      <PdfPageText>[for (var i = 0; i < pageTexts.length; i++) document.pages[i].canonicalText()],
    );
  }
}

/// Tuned constants, values and roles carried over from reflow.py.
const int _pageScanCount = 20;
const int _lineScanCount = 2;
const double _lineFactor = 0.2;
const int _orphanLines = 5;
const double _paraFactor = 1.8;
const double _sectionFactor = 1.3;
const double _rightFactor = 1.8;
const double _centerFactor = 0.15;
const double _sameSpace = 3.0;
const double _sameIndent = 2.0;
const double _unwrapFactor = 0.45;

// reflow.py probes these with re.match — anchored at the string
// start — so every alternative carries its own anchor here.
final RegExp _pageNumberPattern = RegExp(
  r'^(.*\d+\s+\w+\s+\d+.*)|^(\s*\d+\s+.*)|^\s*[ivxlcIVXLC]+\s*$',
);
final RegExp _fixedLineNumberPattern = RegExp(r'(^.+[^0-9])\d+\s*$');

/// The whole-document reflow state and pipeline.
final class _Document {
  _Document(final List<PdfPageText> pageTexts, final List<PdfPage> pages) {
    for (var i = 0; i < pageTexts.length && i < pages.length; i++) {
      this.pages.add(_Page(i + 1, pages[i].width, pages[i].height, pageTexts[i]));
    }
    if (this.pages.isEmpty) return;

    _collectFontStatistics();
    _findHeaderFooter();
    _removeHeaderFooter();
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
    _markContinuations();
  }

  final List<_Page> pages = <_Page>[];

  final Map<double, int> tops = <double, int>{};
  final Map<double, int> indentsOdd = <double, int>{};
  final Map<double, int> indentsEven = <double, int>{};
  final Map<double, int> lineSpaces = <double, int>{};
  final Map<double, int> bottoms = <double, int>{};
  final Map<double, int> rights = <double, int>{};

  double dominantFontSize = 12;

  final _Stats stats = _Stats();

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
    if (pages.length < 2) return;

    final headText = List<String>.filled(_lineScanCount, '');
    final headMatch = List<int>.filled(_lineScanCount, 0);
    final headMatch1 = List<int>.filled(_lineScanCount, 0);
    final headMatch2 = List<int>.filled(_lineScanCount, 0);
    var headPage = 0;
    var fixedHead = '';
    final footText = List<String>.filled(_lineScanCount, '');
    final footMatch = List<int>.filled(_lineScanCount, 0);
    final footMatch1 = List<int>.filled(_lineScanCount, 0);
    final footMatch2 = List<int>.filled(_lineScanCount, 0);
    var footPage = 0;
    var fixedFoot = '';

    var scanned = _pageScanCount;
    for (final page in pages) {
      if (page.lines.isNotEmpty) {
        for (var i = 0; i < _lineScanCount; i++) {
          if (page.lines.length < i + 1 || page.lines[i].top > page.height / 2) break;
          final text = page.lines[i].text;
          if (headText[i].isEmpty) {
            headText[i] = text;
          } else if (headText[i] == text) {
            headMatch[i]++;
            headPage = headPage == 0 ? page.number : headPage;
          } else if (_pageNumberPattern.hasMatch(text)) {
            headMatch1[i]++;
            headPage = headPage == 0 ? page.number : headPage;
          } else {
            final fixed = _fixedLineNumberPattern.firstMatch(text);
            if (fixed != null && fixed.group(1)!.isNotEmpty) {
              if (fixedHead.isEmpty) {
                fixedHead = fixed.group(1)!;
              } else if (fixedHead == fixed.group(1)) {
                headMatch2[i]++;
                headPage = headPage == 0 ? page.number : headPage;
              }
            }
          }
        }
        for (var i = 0; i < _lineScanCount; i++) {
          if (page.lines.length < i + 1 ||
              page.lines[page.lines.length - 1 - i].top < page.height / 2) {
            break;
          }
          final text = page.lines[page.lines.length - 1 - i].text;
          if (footText[i].isEmpty) {
            footText[i] = text;
          } else if (footText[i] == text) {
            footMatch[i]++;
            footPage = footPage == 0 ? page.number : footPage;
          } else if (_pageNumberPattern.hasMatch(text)) {
            footMatch1[i]++;
            footPage = footPage == 0 ? page.number : footPage;
          } else {
            final fixed = _fixedLineNumberPattern.firstMatch(text);
            if (fixed != null && fixed.group(1)!.isNotEmpty) {
              if (fixedFoot.isEmpty) {
                fixedFoot = fixed.group(1)!;
              } else if (fixedFoot == fixed.group(1)) {
                footMatch2[i]++;
                footPage = footPage == 0 ? page.number : footPage;
              }
            }
          }
        }
      }
      if (--scanned < 1) break;
    }
    scanned = scanned > 0 ? _pageScanCount - scanned : _pageScanCount;
    final needed = scanned / 2;

    var headIndex = 0;
    for (var i = 0; i < _lineScanCount; i++) {
      if (headMatch[i] > needed || headMatch1[i] > needed || headMatch2[i] > needed) headIndex = i;
    }
    if (headPage > 0 &&
        headPage <= pages.length &&
        pages[headPage - 1].lines.length > headIndex &&
        (headMatch[headIndex] > needed ||
            headMatch1[headIndex] > needed ||
            headMatch2[headIndex] > needed)) {
      headerSkip = pages[headPage - 1].lines[headIndex].bottom + 1;
    }

    var footIndex = 0;
    for (var i = 0; i < _lineScanCount; i++) {
      if (footMatch[i] > needed || footMatch1[i] > needed || footMatch2[i] > needed) footIndex = i;
    }
    if (footPage > 0 &&
        footPage <= pages.length &&
        pages[footPage - 1].lines.length > footIndex &&
        (footMatch[footIndex] > needed ||
            footMatch1[footIndex] > needed ||
            footMatch2[footIndex] > needed)) {
      final lines = pages[footPage - 1].lines;
      footerSkip = lines[lines.length - 1 - footIndex].top - 1;
    }
  }

  void _removeHeaderFooter() {
    for (final page in pages) {
      page.lines.removeWhere(
        (final line) =>
            (headerSkip > 0 && line.top < headerSkip) || (footerSkip > 0 && line.top > footerSkip),
      );
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
    final working = Map<double, int>.of(indents);

    double mostPopular() {
      var best = 0.0;
      var bestCount = 0;
      working.forEach((final value, final count) {
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
      working.forEach((final value, final count) {
        if (count > 0 && (center - value).abs() <= _sameIndent) {
          if (value < low) low = value;
          if (value > high) high = value;
          total += count;
          working[value] = -count;
        }
      });

      return (low, high, total);
    }

    final (leftLow, leftHigh, _) = clusterAround(mostPopular());
    var (indentLow, indentHigh, indentCount) = clusterAround(mostPopular());
    final (thirdLow, thirdHigh, thirdCount) = clusterAround(mostPopular());
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
  void _markContinuations() {
    if (stats.lineSpace <= 0) return;
    final orphanSpace = stats.bottom - _orphanLines * stats.lineSpace;

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

      if (first.top <= stats.top + previous.averageTextHeight && !(lastSpare > mergedLen)) {
        first.continuesPreviousPage = true;
        first.indented = 0;
      }
    }
  }
}

/// Document-level statistics shared by the per-page passes.
final class _Stats {
  double top = 0;
  double bottom = 0;
  double right = 0;
  double lineSpace = 0;
  double paraSpace = 0;

  double leftMinOdd = 0;
  double leftMaxOdd = 0;
  double indentMinOdd = 0;
  double indentMaxOdd = 0;
  double leftMinEven = 0;
  double leftMaxEven = 0;
  double indentMinEven = 0;
  double indentMaxEven = 0;
}

/// One page under reflow: its working lines and derived margins.
final class _Page {
  _Page(this.number, this.width, this.height, final PdfPageText pageText)
    : images = List<PdfImageBox>.of(pageText.images) {
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
  void secondPass(final _Stats stats) {
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

  void _coalesceParagraphs(final _Stats stats) {
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
          line.bottom - last.bottom > stats.paraSpace * _sectionFactor) {
        line.blankLineBefore = true;
      }
      last = line;
      index++;
    }
  }

  bool _canMerge(final _Line first, final _Line second, final _Stats stats) {
    final sameLeft =
        second.left >= first.lastLeft - _sameIndent && second.left <= first.lastLeft + _sameIndent;
    final leftish =
        (second.left < statsLeftMin + second.averageCharacterWidth &&
            (sameLeft || (second.left < first.lastLeft && first.indented > 0))) ||
        (sameLeft && first.indented == 0 && second.left >= statsIndentMin) ||
        (sameLeft && first.indented == second.indented && second.indented > 1) ||
        (second.left >= first.lastLeft && second.bottom <= first.bottom);

    return leftish &&
        first.bottom + stats.lineSpace + stats.lineSpace * _lineFactor >= second.bottom &&
        first.finalWidth > width * _unwrapFactor &&
        !_adjacentQuotes(first.parts.last.text, second.text);
  }

  void _checkCentered(final _Stats stats) {
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
      } else if (leftMargin > statsIndentMax && leftMargin > rightMargin * _rightFactor) {
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
    lines.sort((final a, final b) {
      final dy = a.y - b.y;

      return dy.abs() < 0.5 ? a.x.compareTo(b.x) : dy.compareTo(0);
    });

    return PdfPageText(lines: lines, images: images);
  }

  /// Renders the page's HTML with the canonical-text invariant:
  /// blocks joined by `\n`, paragraph lines joined by `\n` inside
  /// one text node (font-size spans add no characters).
  String render(final int anchor) {
    final blocks =
        <_Block>[
          for (final line in lines) _Block(top: line.top, left: line.left, line: line),
          for (final image in images)
            if (image.path.isNotEmpty) _Block(top: image.y, left: image.x, image: image),
        ]..sort((final a, final b) {
          final dy = a.top - b.top;

          return dy.abs() < 0.5 ? a.left.compareTo(b.left) : dy.compareTo(0);
        });

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
      final escaped = _escape(part.text);
      if (part.em != 0 && part.em != 1) {
        out.write('<span style="font-size:${_formatEm(part.em)}em">$escaped</span>');
      } else {
        out.write(escaped);
      }
    }
  }
}

String _escape(final String text) =>
    text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _formatEm(final double em) =>
    em == em.roundToDouble() ? em.toInt().toString() : em.toString();

bool _adjacentQuotes(final String first, final String second) {
  final lastChar = RegExp(r'.*([^ ])\s*$').firstMatch(first)?.group(1) ?? ' ';
  final firstChar = RegExp(r'\s*([^ ])').firstMatch(second)?.group(1) ?? ' ';

  return (lastChar == '"' && firstChar == '"') ||
      (lastChar == '\u2019' && firstChar == '\u2018') ||
      (lastChar == '\u201D' && firstChar == '\u201C');
}
