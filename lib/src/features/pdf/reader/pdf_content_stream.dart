import 'dart:math' as math;
import 'dart:typed_data';

import '../codec/pdf_stream_decoder.dart';
import '../entities/pdf_layout.dart';
import '../entities/pdf_page.dart';
import '../entities/pdf_page_text.dart';
import '../exceptions/pdf_exception.dart';
import '../header/pdf_document.dart';
import '../header/pdf_object.dart';
import '../image/pdf_bitmap.dart';
import 'pdf_font.dart';

/// Extracts the text and image placements of PDF pages by
/// interpreting their content streams.
///
/// Tracks the text and graphics state the show-text operators see
/// (font, size, spacing, the text matrix and the CTM stack), then
/// groups the emitted runs into canonical lines: runs sharing a
/// baseline merge left-to-right with a space wherever the gap
/// exceeds a fraction of the font size. That line join happens once,
/// here, and defines the page's canonical text stream — the reflow
/// and the facsimile text layer both consume it character-for-
/// character unchanged.
class PdfTextExtractor {
  /// Creates an extractor bound to [document].
  PdfTextExtractor(this.document) : _fontsByNumber = <int, PdfFont>{};

  /// The document whose objects fonts and resources resolve through.
  final PdfDocument document;

  final Map<int, PdfFont> _fontsByNumber;

  /// Cached fonts for dictionaries referenced inline (no object
  /// number to key by).
  final Expando<PdfFont> _directFonts = Expando<PdfFont>();

  /// Extracts [page]'s text; [onImage] receives each drawable
  /// image (JPEG passthrough or a decoded bitmap as PNG) drawn on
  /// any page, deduplicated by object number, with the file
  /// extension it should carry.
  PdfPageText extract(
    final PdfPage page, {
    final void Function(int objectNumber, Uint8List bytes, String extension)? onImage,
  }) {
    final extraction = _extractAll(page, collectGlyphs: false, onImage: onImage);

    return extraction.pageText;
  }

  /// Extracts [page]'s text together with the layout primitives the
  /// structure layer segments: per-character glyph cells (real
  /// advances, so word geometry is never invented from line widths)
  /// and the page's ruling lines (filled hairline rectangles and
  /// stroked segments, the input table detection needs). The
  /// [PdfPageText] equals [extract]'s output for the same page.
  PdfPageLayoutExtraction extractLayout(
    final PdfPage page, {
    final void Function(int objectNumber, Uint8List bytes, String extension)? onImage,
  }) {
    return _extractAll(page, collectGlyphs: true, onImage: onImage);
  }

  PdfPageLayoutExtraction _extractAll(
    final PdfPage page, {
    required final bool collectGlyphs,
    final void Function(int objectNumber, Uint8List bytes, String extension)? onImage,
  }) {
    final runs = <_Run>[];
    final glyphs = collectGlyphs ? <_GlyphCell>[] : null;
    final rules = collectGlyphs ? <_RuleSegment>[] : null;
    final images = <PdfImageBox>[];
    final streams = _contentStreams(page);
    var skippedContentStreams = 0;
    for (final stream in streams) {
      Uint8List content;
      try {
        content = document.decodeStream(stream);
      } on Exception {
        skippedContentStreams++;
        continue;
      }
      _interpret(content, _resourcesOf(page), runs, images, onImage, glyphs != null, rules);
    }

    final pageText = _toPageText(
      runs,
      images,
      page,
      contentStreamCount: streams.length,
      skippedContentStreams: skippedContentStreams,
    );
    if (!collectGlyphs) {
      return PdfPageLayoutExtraction(pageText: pageText, words: const [], rules: const []);
    }

    return PdfPageLayoutExtraction(
      pageText: pageText,
      words: _extractWords(runs, page),
      rules: _placeRules(rules!, page),
    );
  }

  List<PdfStream> _contentStreams(final PdfPage page) {
    final contentsObject = document.object(page.objectNumber);
    PdfDictionary? pageDictionary;
    if (contentsObject is PdfDictionary) pageDictionary = contentsObject;
    pageDictionary ??= _pageDictionaryOf(page);
    if (pageDictionary == null) return const <PdfStream>[];

    final contents = document.resolve(pageDictionary['Contents']);
    if (contents is PdfStream) return <PdfStream>[contents];
    if (contents is PdfArray) {
      return <PdfStream>[
        for (final item in contents.items)
          if (document.resolve(item) is PdfStream) document.resolve(item) as PdfStream,
      ];
    }

    return const <PdfStream>[];
  }

  PdfDictionary? _pageDictionaryOf(final PdfPage page) {
    if (page.objectNumber == 0) return null;
    final object = document.object(page.objectNumber);

    return object is PdfDictionary ? object : null;
  }

  PdfDictionary? _resourcesOf(final PdfPage page) {
    if (page.resources != null) {
      final resolved = document.resolve(page.resources);

      return resolved is PdfDictionary ? resolved : null;
    }

    final pageDictionary = _pageDictionaryOf(page);
    final resolved = document.resolve(pageDictionary?['Resources']);

    return resolved is PdfDictionary ? resolved : null;
  }

  PdfFont _fontOf(final PdfObject? entry) {
    if (entry is PdfIndirectRef) {
      final cached = _fontsByNumber[entry.objectNumber];
      if (cached != null) return cached;

      final dictionary = document.resolve(entry);
      final font = dictionary is PdfDictionary ? PdfFont.of(document, dictionary) : _fallbackFont();
      _fontsByNumber[entry.objectNumber] = font;

      return font;
    }
    if (entry is PdfDictionary) {
      final cached = _directFonts[entry];
      if (cached != null) return cached;

      final font = PdfFont.of(document, entry);
      _directFonts[entry] = font;

      return font;
    }

    return _fallbackFont();
  }

  PdfFont _fallbackFont() => _fallback ??= PdfFont.of(document, const PdfDictionary({}));

  PdfFont? _fallback;

  void _interpret(
    final Uint8List content,
    final PdfDictionary? resources,
    final List<_Run> runs,
    final List<PdfImageBox> images,
    final void Function(int objectNumber, Uint8List bytes, String extension)? onImage,
    final bool collectCells,
    final List<_RuleSegment>? rules,
  ) {
    _ContentInterpreter(this, content, resources, runs, images, onImage, collectCells, rules).run();
  }

  PdfObject? _fontEntry(final PdfDictionary? resources, final String name) {
    final fonts = document.resolve(resources?['Font']);
    if (fonts is PdfDictionary) return fonts[name];

    return null;
  }

  /// Shows [bytes], records the run and returns the advanced text
  /// matrix. With [collectCells], one glyph cell per decoded character
  /// code is recorded with its absolute pen position and real device
  /// advance — the primitive word geometry derives from.
  _Mat _showText(
    final Uint8List bytes,
    final _Mat textMatrix,
    final _GraphicsState gstate,
    final List<_Run> runs, {
    required final bool collectCells,
  }) {
    final font = gstate.font ?? _fallbackFont();
    final (text, advanceEm, codeCount, spaceCount) = font.decode(bytes);
    final advanceText =
        advanceEm * gstate.fontSize +
        codeCount * gstate.charSpacing +
        spaceCount * gstate.wordSpacing;
    // Device = CTM ∘ Tm applied to the text-space point: the CTM maps
    // the text matrix's result to device space, so the CTM composes on
    // the outside. The inverted order inflates positions and widths by
    // the Tm scale on every producer that translates with `cm` before
    // `BT` (cupsfilter does on every page).
    final effective = _Mat.multiply(
      gstate.ctm,
      _Mat.multiply(textMatrix, _Mat.translation(0, gstate.rise)),
    );
    final startX = effective.e;
    final startY = effective.f;
    final horizontal = effective.b.abs() < 1e-4 && effective.c.abs() < 1e-4;
    final double widthDevice;
    final double fontSizeDevice;
    if (horizontal) {
      widthDevice = advanceText * gstate.horizontalScale * effective.a.abs();
      fontSizeDevice = gstate.fontSize.abs() * effective.d.abs();
    } else {
      // Rotated (or skewed) text: the exact axis-aligned box of the
      // parallelogram the run sweeps. The advance vector runs along
      // the text direction (a, b); the visual ascent (baseline to
      // top, 0.8 em) runs along the vertical direction (c, d). The
      // box over {p0, p0+advance, p0+ascent, p0+advance+ascent} has
      // per-axis extents |advance|+|ascent| on that axis.
      final advanceDevice = advanceText * gstate.horizontalScale;
      final ascentDevice = gstate.fontSize.abs() * 0.8;
      final advanceX = effective.a * advanceDevice;
      final ascentX = effective.c * ascentDevice;
      widthDevice = advanceX.abs() + ascentX.abs();
      final verticalNorm = math.sqrt(effective.c * effective.c + effective.d * effective.d);
      fontSizeDevice = gstate.fontSize.abs() * verticalNorm;
    }

    if (text.isNotEmpty) {
      // A non-positive or non-finite size (a broken `Tf`, overflow in
      // a hostile matrix) would poison the reflow's font statistics —
      // degrade to the raw size, then to the document default.
      var runFontSize = fontSizeDevice;
      if (!runFontSize.isFinite || runFontSize <= 0) runFontSize = gstate.fontSize;
      if (!runFontSize.isFinite || runFontSize <= 0) runFontSize = 12;
      runs.add(
        _Run(
          text: text,
          x: startX,
          baselineY: startY,
          width: widthDevice,
          fontSize: runFontSize,
          rotated: !horizontal,
          cells: collectCells
              ? _glyphCells(
                  font,
                  bytes,
                  gstate,
                  effective,
                  horizontal: horizontal,
                  fontSizeDevice: runFontSize,
                  advanceScale: math.sqrt(effective.a * effective.a + effective.b * effective.b),
                )
              : const <_GlyphCell>[],
        ),
      );
    }

    return _Mat.multiply(_Mat.translation(advanceText * gstate.horizontalScale, 0), textMatrix);
  }

  /// The per-code glyph cells of one show-text payload: each cell
  /// carries the decoded characters, the absolute pen position (device
  /// space, baseline origin), the device advance along the text
  /// direction and the direction unit vector itself. Positions come
  /// from the font's own width metrics plus the text state — TJ
  /// adjustments and inter-string moves show up as gaps between
  /// absolute positions, so word segmentation never has to guess.
  List<_GlyphCell> _glyphCells(
    final PdfFont font,
    final Uint8List bytes,
    final _GraphicsState gstate,
    final _Mat effective, {
    required final bool horizontal,
    required final double fontSizeDevice,
    required final double advanceScale,
  }) {
    final cells = <_GlyphCell>[];
    final horizontalScale = gstate.horizontalScale;
    final directionNorm = math.sqrt(effective.a * effective.a + effective.b * effective.b);
    var pen = 0.0;
    var offset = 0;
    while (offset + font.codeBytes <= bytes.length) {
      var code = 0;
      for (var i = 0; i < font.codeBytes; i++) {
        code = code * 256 + bytes[offset + i];
      }
      offset += font.codeBytes;
      final advanceEm = font.widthOfCode(code);
      final charAdvance =
          (advanceEm * gstate.fontSize + gstate.charSpacing) * horizontalScale +
          (code == 0x20 && !font.isCid ? gstate.wordSpacing * horizontalScale : 0);
      final piece = font.unicodeOfCode(code) ?? '';
      // The pen advances in TEXT space, then the text matrix maps the
      // point out — composition order matters for rotated text.
      final point = _Mat.multiply(effective, _Mat.translation(pen, 0));
      cells.add(
        _GlyphCell(
          text: piece,
          x: point.e,
          y: point.f,
          // The device advance scales by the same matrix factor as the
          // run's width; fontSize is the sanitized device size. Both
          // must agree with the run so word gaps measure real spacing.
          advance: charAdvance * advanceScale,
          fontSize: fontSizeDevice,
          directionX: directionNorm == 0 ? 1 : effective.a / directionNorm,
          directionY: directionNorm == 0 ? 0 : effective.b / directionNorm,
          horizontal: horizontal,
        ),
      );
      pen += charAdvance;
    }

    return cells;
  }

  void _drawXObject(
    final String name,
    final PdfDictionary? resources,
    final _GraphicsState gstate,
    final List<PdfImageBox> images,
    final void Function(int objectNumber, Uint8List bytes, String extension)? onImage,
  ) {
    final xobjects = document.resolve(resources?['XObject']);
    if (xobjects is! PdfDictionary) return;

    final entry = xobjects[name];
    final stream = document.resolve(entry);
    if (stream is! PdfStream) return;

    final subtype = document.resolve(stream.dictionary['Subtype']);
    if (subtype is! PdfName || subtype.value != 'Image') return;

    final ctm = gstate.ctm;
    final width = (ctm.a.abs() + ctm.c.abs());
    final height = (ctm.b.abs() + ctm.d.abs());
    final number = entry is PdfIndirectRef ? entry.objectNumber : 0;

    // DCTDecode (JPEG) leaves a file the HTML can point at
    // byte-for-byte; the bitmap codecs decode here to a grayscale
    // PNG. Undecodable placements still record their geometry.
    final decoded = number != 0 ? decodePdfImageStream(document, stream) : null;
    final extension = decoded?.$2 ?? '';
    final imageBytes = decoded?.$1;

    final path = extension.isEmpty ? '' : 'images/pdf-image-$number.$extension';
    if (images.length < 256) {
      images.add(
        PdfImageBox(name: name, x: ctm.e, y: ctm.f, width: width, height: height, path: path),
      );
    }

    if (onImage != null && imageBytes != null) {
      onImage(number, imageBytes, extension);
    }
  }

  PdfPageText _toPageText(
    final List<_Run> runs,
    final List<PdfImageBox> images,
    final PdfPage page, {
    required final int contentStreamCount,
    required final int skippedContentStreams,
  }) {
    final box = page.cropBox ?? page.mediaBox;
    final boxX0 = box[0];
    final boxY0 = box[1];
    final boxX1 = box[2];
    final boxY1 = box[3];
    final pageWidth = boxX1 - boxX0;
    final pageHeight = boxY1 - boxY0;

    final visible = _visibleRuns(runs, boxX0, boxX1, boxY0, boxY1);
    final clusters = _lineClusters(visible);
    final lines = _textLines(_splitRepeatedGutters(clusters, pageWidth), boxX0, boxY1);
    final placedImages = _placeImages(images, boxX0, boxY1);

    return PdfPageText(
      lines: _rotateAll(lines, page.rotate, pageWidth, pageHeight),
      images: placedImages,
      contentStreamCount: contentStreamCount,
      skippedContentStreams: skippedContentStreams,
    );
  }

  /// Drops text runs outside the page's visible crop box and removes noise.
  List<_Run> _visibleRuns(
    final List<_Run> runs,
    final double boxX0,
    final double boxX1,
    final double boxY0,
    final double boxY1,
  ) {
    return runs.where((final run) {
      return run.text.trim().isNotEmpty &&
          run.x >= boxX0 - 8 &&
          run.x <= boxX1 + 8 &&
          run.baselineY >= boxY0 - 8 &&
          run.baselineY <= boxY1 + 8;
    }).toList();
  }

  /// Groups runs into lines by comparing each run with the current line's
  /// anchor baseline. The source order is normalised before grouping.
  List<List<_Run>> _lineClusters(final List<_Run> visible) {
    visible.sort((final a, final b) => b.baselineY.compareTo(a.baselineY));
    final clusters = <List<_Run>>[];
    for (final run in visible) {
      if (_appendToLastCluster(clusters, run)) continue;
      clusters.add(<_Run>[run]);
    }

    return clusters;
  }

  bool _appendToLastCluster(final List<List<_Run>> clusters, final _Run run) {
    if (clusters.isEmpty) return false;
    final cluster = clusters.last;
    final anchor = cluster.first;
    final smallerFontSize = run.fontSize < anchor.fontSize ? run.fontSize : anchor.fontSize;
    final tolerance = 0.45 * smallerFontSize + 0.6;
    if ((run.baselineY - anchor.baselineY).abs() > tolerance) return false;

    cluster.add(run);

    return true;
  }

  /// A repeated wide gap between runs is stronger column evidence than a
  /// single line's spacing. Keep isolated gaps as one canonical line.
  List<List<_Run>> _splitRepeatedGutters(final List<List<_Run>> clusters, final double pageWidth) {
    if (clusters.length < 3 || pageWidth <= 0) return clusters;

    final candidates =
        <({int clusterIndex, int splitIndex, double rightStart, double leftStart})>[];
    for (var index = 0; index < clusters.length; index++) {
      final sorted = List<_Run>.of(clusters[index])..sort((final a, final b) => a.x.compareTo(b.x));
      for (var split = 1; split < sorted.length; split++) {
        final preceding = sorted[split - 1];
        final following = sorted[split];
        if (following.x - preceding.x < pageWidth * 0.3 ||
            following.x - preceding.x - preceding.width < pageWidth * 0.03 ||
            preceding.width < pageWidth * 0.12 ||
            following.width < pageWidth * 0.12) {
          continue;
        }
        candidates.add((
          clusterIndex: index,
          splitIndex: split,
          rightStart: following.x,
          leftStart: sorted.first.x,
        ));
        break;
      }
    }
    if (candidates.length < 3) return clusters;

    for (final anchor in candidates) {
      final agreeing = candidates.where(
        (final item) =>
            (item.rightStart - anchor.rightStart).abs() <= pageWidth * 0.04 &&
            (item.leftStart - anchor.leftStart).abs() <= pageWidth * 0.08,
      );
      if (agreeing.length < 3) continue;

      final splits = <int, int>{for (final item in agreeing) item.clusterIndex: item.splitIndex};
      final separated = <List<_Run>>[];
      for (var index = 0; index < clusters.length; index++) {
        final split = splits[index];
        if (split == null) {
          separated.add(clusters[index]);
          continue;
        }
        final sorted = List<_Run>.of(clusters[index])
          ..sort((final a, final b) => a.x.compareTo(b.x));
        separated
          ..add(sorted.sublist(0, split))
          ..add(sorted.sublist(split));
      }
      return separated;
    }

    return clusters;
  }

  /// Converts run clusters into canonical text lines and restores reading
  /// order from top to bottom, then left to right.
  List<PdfTextLine> _textLines(
    final List<List<_Run>> clusters,
    final double boxX0,
    final double boxY1,
  ) {
    final lines = <PdfTextLine>[];
    for (final cluster in clusters) {
      final line = _textLine(cluster, boxX0, boxY1);
      if (line != null) lines.add(line);
    }
    lines.sort(_compareReadingOrder);

    return lines;
  }

  PdfTextLine? _textLine(final List<_Run> cluster, final double boxX0, final double boxY1) {
    cluster.sort((final a, final b) => a.x.compareTo(b.x));
    final firstRun = cluster.first;
    final buffer = StringBuffer();
    var previousRight = firstRun.x;
    var left = firstRun.x;
    var right = firstRun.x + firstRun.width;
    var height = 0.0;
    var fontSize = 0.0;
    var baseline = firstRun.baselineY;
    var rotated = false;
    var first = true;
    var previousFontSize = firstRun.fontSize;
    for (final run in cluster) {
      final smaller = run.fontSize < previousFontSize ? run.fontSize : previousFontSize;
      final gapThreshold = 0.28 * smaller + 0.9;
      if (!first && run.x - previousRight > gapThreshold) buffer.write(' ');
      buffer.write(run.text);
      previousRight = run.x + run.width;
      previousFontSize = run.fontSize;
      if (run.x < left) left = run.x;
      if (run.x + run.width > right) right = run.x + run.width;
      if (run.fontSize > fontSize) {
        fontSize = run.fontSize;
        baseline = run.baselineY;
      }
      if (run.fontSize > height) height = run.fontSize;
      rotated = rotated || run.rotated;
      first = false;
    }

    final text = buffer.toString().trim();
    if (text.isEmpty) return null;

    return PdfTextLine(
      text: text,
      x: left - boxX0,
      // Baseline sits ~0.8 em under the visual top of the line.
      y: boxY1 - (baseline + height * 0.8),
      width: right - left,
      height: height,
      fontSize: fontSize,
      rotated: rotated,
    );
  }

  int _compareReadingOrder(final PdfTextLine a, final PdfTextLine b) {
    final dy = a.y - b.y;

    return dy.abs() < 0.5 ? a.x.compareTo(b.x) : dy.compareTo(0);
  }

  List<PdfImageBox> _placeImages(
    final List<PdfImageBox> images,
    final double boxX0,
    final double boxY1,
  ) {
    return <PdfImageBox>[
      for (final image in images)
        PdfImageBox(
          name: image.name,
          x: image.x - boxX0,
          // The CTM origin is the image's bottom-left corner.
          y: boxY1 - image.y - image.height,
          width: image.width,
          height: image.height,
        ),
    ];
  }

  /// Words from the line-clustered runs' glyph cells: cells order
  /// along the line's advance direction, split at whitespace
  /// characters and at gaps exceeding the same threshold the line
  /// joiner inserts spaces at, so word text and line text agree.
  ///
  /// Every box comes from real advances — never from dividing a
  /// line's width by its character count.
  List<PdfWord> _extractWords(final List<_Run> runs, final PdfPage page) {
    final box = page.cropBox ?? page.mediaBox;
    final visible = _visibleRuns(runs, box[0], box[2], box[1], box[3]);
    final clusters = _lineClusters(visible);
    final words = <PdfWord>[];
    for (final cluster in clusters) {
      final cells = <_GlyphCell>[];
      for (final run in cluster) {
        cells.addAll(run.cells);
      }
      if (cells.isEmpty) continue;

      final directionX = cells.first.directionX;
      final horizontal = cells.first.horizontal;
      final rtl = directionX < 0;
      if (horizontal) {
        cells.sort((final a, final b) => rtl ? b.x.compareTo(a.x) : a.x.compareTo(b.x));
      } else {
        // Order along the dominant advance direction of the cluster.
        final (dx, dy) = (cells.first.directionX, cells.first.directionY);
        double projection(final _GlyphCell cell) => cell.x * dx + cell.y * dy;
        cells.sort((final a, final b) => projection(a).compareTo(projection(b)));
      }

      const gapFactor = 0.28;
      const gapFloor = 0.9;
      var wordCells = <_GlyphCell>[];
      var previousEnd = double.nan;
      void flush() {
        if (wordCells.isEmpty) return;
        final text = wordCells
            .map((final cell) => cell.text)
            .join()
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (text.isEmpty) {
          wordCells = <_GlyphCell>[];
          previousEnd = double.nan;
          return;
        }

        final fontSize = _wordFontSize(wordCells);
        // The word's own first cell decides the direction class: a
        // cluster can mix upright runs with a same-baseline rotated
        // one.
        final wordHorizontal = wordCells.first.horizontal;
        final boxPoints = _wordBox(wordCells);
        final topLeft = _toRotatedPagePoint(boxPoints.$1, boxPoints.$2, page);
        final bottomRight = _toRotatedPagePoint(boxPoints.$3, boxPoints.$4, page);
        final left = topLeft.$1 <= bottomRight.$1 ? topLeft.$1 : bottomRight.$1;
        final top = topLeft.$2 <= bottomRight.$2 ? topLeft.$2 : bottomRight.$2;
        final right = topLeft.$1 <= bottomRight.$1 ? bottomRight.$1 : topLeft.$1;
        final bottom = topLeft.$2 <= bottomRight.$2 ? bottomRight.$2 : topLeft.$2;
        // The advance direction rotates with the page.
        final first = wordCells.first;
        final origin = _toRotatedPagePoint(boxPoints.$1, boxPoints.$2, page);
        final moved = _toRotatedPagePoint(
          boxPoints.$1 + first.directionX,
          boxPoints.$2 + first.directionY,
          page,
        );
        var (dx, dy) = (moved.$1 - origin.$1, moved.$2 - origin.$2);
        final norm = math.sqrt(dx * dx + dy * dy);
        if (norm < 1e-9) {
          dx = 1;
          dy = 0;
        } else {
          dx /= norm;
          dy /= norm;
        }
        words.add(
          PdfWord(
            text: text,
            x: left,
            y: top,
            width: right - left,
            height: bottom - top,
            fontSize: fontSize,
            rotated: !wordHorizontal,
            directionX: dx,
            directionY: dy,
          ),
        );
        wordCells = <_GlyphCell>[];
      }

      for (final cell in cells) {
        final isWhitespace = cell.text.trim().isEmpty;
        // The gap axis is the cell's own advance direction, so a
        // rotated run inside a mostly-horizontal cluster still
        // measures its gaps along its own baseline.
        final cellStart = cell.x * cell.directionX + cell.y * cell.directionY;
        final cellEnd = cellStart + cell.advance;
        if (isWhitespace) {
          flush();
          previousEnd = double.nan;
          continue;
        }
        if (wordCells.isNotEmpty) {
          final smaller = cell.fontSize < wordCells.last.fontSize
              ? cell.fontSize
              : wordCells.last.fontSize;
          final gap = previousEnd.isNaN ? 0.0 : (cellStart - previousEnd).abs();
          if (gap > gapFactor * smaller + gapFloor) {
            flush();
          }
        }
        wordCells.add(cell);
        previousEnd = cellEnd;
      }
      flush();
    }

    return words;
  }

  double _wordFontSize(final List<_GlyphCell> cells) {
    var size = 0.0;
    for (final cell in cells) {
      if (cell.fontSize > size) size = cell.fontSize;
    }

    return size <= 0 ? 12 : size;
  }

  /// The axis-aligned device-space box of one word's cells: corners
  /// `(minX, minY, maxX, maxY)`. Horizontal words span the advance
  /// extent; rotated words take the parallelogram sweep (advance times
  /// direction plus the 0.8 em ascent) over every cell.
  (double, double, double, double) _wordBox(final List<_GlyphCell> cells) {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    void grow(final double x, final double y) {
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }

    for (final cell in cells) {
      if (cell.horizontal) {
        final end = cell.x + (cell.directionX < 0 ? -cell.advance : cell.advance);
        // Device space grows upward: the box spans baseline to ascent.
        grow(cell.x <= end ? cell.x : end, cell.y);
        grow(cell.x <= end ? end : cell.x, cell.y + 0.8 * cell.fontSize);
      } else {
        final dx = cell.directionX;
        final dy = cell.directionY;
        final ascent = 0.8 * cell.fontSize;
        // Advance plus the ascent perpendicular to the direction.
        grow(cell.x, cell.y);
        grow(cell.x + dx * cell.advance, cell.y + dy * cell.advance);
        grow(cell.x - dy * ascent, cell.y + dx * ascent);
        grow(cell.x + dx * cell.advance - dy * ascent, cell.y + dy * cell.advance + dx * ascent);
      }
    }

    return (minX, minY, maxX, maxY);
  }

  /// Converts a device-space point to the cropped, rotated top-left
  /// page space, matching the line placement.
  (double, double) _toRotatedPagePoint(final double x, final double y, final PdfPage page) {
    final box = page.cropBox ?? page.mediaBox;
    final px = x - box[0];
    final py = box[3] - y;
    final pageWidth = box[2] - box[0];
    final pageHeight = box[3] - box[1];

    return switch (page.rotate % 360) {
      90 => (pageHeight - py, px),
      180 => (pageWidth - px, pageHeight - py),
      270 => (py, pageWidth - px),
      _ => (px, py),
    };
  }

  /// Converts rule segments to axis-aligned page-space rule lines;
  /// diagonal decoration drops here — the table detector reasons in
  /// axis-aligned lattices only.
  List<PdfRuleLine> _placeRules(final List<_RuleSegment> rules, final PdfPage page) {
    final out = <PdfRuleLine>[];
    for (final rule in rules) {
      final a = _toRotatedPagePoint(rule.x0, rule.y0, page);
      final b = _toRotatedPagePoint(rule.x1, rule.y1, page);
      if ((a.$1 - b.$1).abs() < 0.05) {
        if ((a.$2 - b.$2).abs() < 0.05) continue;
        out.add(PdfRuleLine(x0: a.$1, y0: a.$2, x1: a.$1, y1: b.$2));
      } else if ((a.$2 - b.$2).abs() < 0.05) {
        out.add(PdfRuleLine(x0: a.$1, y0: a.$2, x1: b.$1, y1: a.$2));
      }
    }

    return out;
  }

  List<PdfTextLine> _rotateAll(
    final List<PdfTextLine> lines,
    final int rotate,
    final double pageWidth,
    final double pageHeight,
  ) {
    if (rotate == 0) return lines;

    return <PdfTextLine>[
      for (final line in lines)
        switch (rotate % 360) {
          90 => PdfTextLine(
            text: line.text,
            x: pageHeight - line.y - line.height,
            y: line.x,
            width: line.height,
            height: line.width,
            fontSize: line.fontSize,
            rotated: line.rotated,
          ),
          180 => PdfTextLine(
            text: line.text,
            x: pageWidth - line.x - line.width,
            y: pageHeight - line.y - line.height,
            width: line.width,
            height: line.height,
            fontSize: line.fontSize,
            rotated: line.rotated,
          ),
          270 => PdfTextLine(
            text: line.text,
            x: line.y,
            y: pageWidth - line.x - line.width,
            width: line.height,
            height: line.width,
            fontSize: line.fontSize,
            rotated: line.rotated,
          ),
          _ => line,
        },
    ];
  }

  double _num(final List<Object?> operands, {final int index = 0, final double fallback = 0}) {
    if (index < operands.length && operands[index] is num) {
      return (operands[index] as num).toDouble();
    }

    return fallback;
  }

  _Mat? _matrixOperands(final List<Object?> operands) {
    if (operands.length < 6) return null;
    final values = <double>[];
    for (var i = 0; i < 6; i++) {
      final operand = operands[i];
      if (operand is! num) return null;
      values.add(operand.toDouble());
    }

    return _Mat(values[0], values[1], values[2], values[3], values[4], values[5]);
  }

  Uint8List? _stringOperand(final List<Object?> operands) {
    for (final operand in operands) {
      if (operand is Uint8List) return operand;
    }

    return null;
  }
}

/// Interprets one decoded content stream while keeping the mutable PDF
/// graphics/text state together. The extractor remains responsible for font
/// lookup and output, while this class owns operator sequencing. Layout
/// extraction adds two bounded collectors: glyph cells (per character code,
/// for word geometry) and rule segments (from path operators, for table
/// detection) — both null on the plain text path, which stays allocation-
/// free for them.
final class _ContentInterpreter {
  _ContentInterpreter(
    this._extractor,
    final Uint8List content,
    this._resources,
    this._runs,
    this._images,
    this._onImage,
    this._collectCells,
    this._rules,
  ) : _lexer = _ContentLexer(content);

  static const _maxRuleSegments = 4096;
  static const _maxPathSegments = 8192;

  final PdfTextExtractor _extractor;
  final PdfDictionary? _resources;
  final List<_Run> _runs;
  final List<PdfImageBox> _images;
  final void Function(int objectNumber, Uint8List bytes, String extension)? _onImage;
  final bool _collectCells;
  final List<_RuleSegment>? _rules;
  final _ContentLexer _lexer;
  final List<Object?> _operands = <Object?>[];
  final List<_GraphicsState> _gstates = <_GraphicsState>[];
  _GraphicsState _gstate = _GraphicsState();
  _Mat _textMatrix = _Mat.identity;
  _Mat _lineMatrix = _Mat.identity;
  bool _inText = false;
  var _budget = 4000000;

  /// Straight path segments awaiting a stroke decision, and the fat
  /// (non-hairline) rectangle edges awaiting one too — a background
  /// fill paints them away, a stroke turns them into rules.
  final List<_RuleSegment> _pendingSegments = <_RuleSegment>[];
  final List<_RuleSegment> _pendingFatRectEdges = <_RuleSegment>[];
  var _pathSegments = 0;
  bool _clipPending = false;

  void run() {
    while (true) {
      final token = _lexer.next();
      if (token == null || _budget-- <= 0) {
        break;
      }
      if (token is _Operator) {
        _handleOperator(token.name);
        _operands.clear();
      } else {
        _operands.add((token as _Operand).value);
        if (_operands.length > 64) {
          _operands.removeAt(0);
        }
      }
    }
  }

  void _handleOperator(final String name) {
    switch (name) {
      case 'q':
        _gstates.add(_gstate);
        _gstate = _gstate.copy();
      case 'Q':
        if (_gstates.isNotEmpty) {
          _gstate = _gstates.removeLast();
        }
      case 'cm':
        final matrix = _extractor._matrixOperands(_operands);
        if (matrix != null) {
          _gstate.ctm = _Mat.multiply(matrix, _gstate.ctm);
        }
      case 'BT':
        _inText = true;
        _textMatrix = _Mat.identity;
        _lineMatrix = _Mat.identity;
      case 'ET':
        _inText = false;
      case 'Tf':
        _setFont();
      case 'Tc':
        _gstate.charSpacing = _extractor._num(_operands);
      case 'Tw':
        _gstate.wordSpacing = _extractor._num(_operands);
      case 'Tz':
        _gstate.horizontalScale = _extractor._num(_operands, fallback: 100) / 100;
      case 'TL':
        _gstate.leading = _extractor._num(_operands);
      case 'Ts':
        _gstate.rise = _extractor._num(_operands);
      case 'Td':
        _setTextPosition();
      case 'TD':
        _setTextPosition(setLeading: true);
      case 'Tm':
        _setTextMatrix();
      case 'T*':
        _moveToNextLine();
      case 'Tj':
        _showString();
      case "'":
        _moveToNextLine();
        _showString();
      case '"':
        _setSpacingAndShowString();
      case 'TJ':
        _showArray();
      case 'Do':
        _drawObject();
      case 'm' || 'l':
        _pathPoint();
      case 'c' || 'v' || 'y':
        // Curves contribute their endpoint only: table rules are
        // straight, and decorative curves carry no lattice.
        if (_operands.length >= 2) {
          _operands.removeRange(0, _operands.length - 2);
          _pathPoint();
        }
      case 're':
        _pathRect();
      case 'S' || 's' || 'B' || 'B*' || 'b' || 'b*':
        _paintPath(stroked: true);
      case 'f' || 'F' || 'f*':
        _paintPath(stroked: false);
      case 'n':
        _clearPath();
      case 'W' || 'W*':
        _clipPending = true;
    }
  }

  void _setFont() {
    if (_operands.length < 2 || _operands[0] is! String || _operands[1] is! num) {
      return;
    }
    _gstate.font = _extractor._fontOf(_extractor._fontEntry(_resources, _operands[0] as String));
    _gstate.fontSize = (_operands[1] as num).toDouble();
  }

  void _setTextPosition({final bool setLeading = false}) {
    final tx = _extractor._num(_operands);
    final ty = _extractor._num(_operands, index: 1);
    if (setLeading) {
      _gstate.leading = -ty;
    }
    _lineMatrix = _Mat.multiply(_Mat.translation(tx, ty), _lineMatrix);
    _textMatrix = _lineMatrix;
  }

  void _moveToNextLine() {
    _lineMatrix = _Mat.multiply(_Mat.translation(0, -_gstate.leading), _lineMatrix);
    _textMatrix = _lineMatrix;
  }

  void _setTextMatrix() {
    final matrix = _extractor._matrixOperands(_operands);
    if (matrix == null) {
      return;
    }
    _lineMatrix = matrix;
    _textMatrix = matrix;
  }

  void _showString() {
    final bytes = _extractor._stringOperand(_operands);
    if (_inText && bytes != null) {
      _textMatrix = _extractor._showText(
        bytes,
        _textMatrix,
        _gstate,
        _runs,
        collectCells: _collectCells,
      );
    }
  }

  void _setSpacingAndShowString() {
    if (_operands.length >= 3) {
      _gstate.wordSpacing = (_operands[0] as num?)?.toDouble() ?? _gstate.wordSpacing;
      _gstate.charSpacing = (_operands[1] as num?)?.toDouble() ?? _gstate.charSpacing;
    }
    _moveToNextLine();
    _showString();
  }

  void _showArray() {
    final array = _operands.length == 1 && _operands[0] is List<Object?>
        ? _operands[0] as List<Object?>
        : null;
    if (!_inText || array == null) {
      return;
    }
    for (final element in array) {
      if (element is Uint8List) {
        _textMatrix = _extractor._showText(
          element,
          _textMatrix,
          _gstate,
          _runs,
          collectCells: _collectCells,
        );
      } else if (element is num) {
        final shift = -element / 1000 * _gstate.fontSize * _gstate.horizontalScale;
        _textMatrix = _Mat.multiply(_Mat.translation(shift, 0), _textMatrix);
      }
    }
  }

  void _drawObject() {
    if (_operands.length == 1 && _operands[0] is String) {
      _extractor._drawXObject(_operands[0] as String, _resources, _gstate, _images, _onImage);
    }
  }

  /// Records one straight segment from the last two numeric operands
  /// (`m` starts a subpath, `l` continues it), transformed to device
  /// space as the operator appears.
  void _pathPoint() {
    if (_rules == null || _pathSegments >= _maxPathSegments) return;
    if (_operands.length < 2 || _operands[0] is! num || _operands[1] is! num) return;
    if (_pendingSegments.isEmpty && _pendingFatRectEdges.isEmpty && _operands.length == 2) {
      // A lone `m`: the subpath anchor, no segment yet.
      return;
    }
    final ctm = _gstate.ctm;
    final (ax, ay) = _lastPoint ?? (0.0, 0.0);
    final bx =
        ctm.a * (_operands[0] as num).toDouble() + ctm.c * (_operands[1] as num).toDouble() + ctm.e;
    final by =
        ctm.b * (_operands[0] as num).toDouble() + ctm.d * (_operands[1] as num).toDouble() + ctm.f;
    _lastPoint = (bx, by);
    _pendingSegments.add(_RuleSegment(x0: ax, y0: ay, x1: bx, y1: by, stroked: false));
    _pathSegments++;
  }

  (double, double)? _lastPoint;

  /// Records the four edges of a `re` rectangle. Hairline rectangles
  /// are rules whatever paints them; fat ones wait for a stroke — a
  /// plain fill is a background, not a table lattice.
  void _pathRect() {
    if (_rules == null || _pathSegments >= _maxPathSegments) return;
    if (_operands.length < 4) return;
    for (var i = 0; i < 4; i++) {
      if (_operands[i] is! num) return;
    }
    final ctm = _gstate.ctm;
    double tx(final double x, final double y) => ctm.a * x + ctm.c * y + ctm.e;
    double ty(final double x, final double y) => ctm.b * x + ctm.d * y + ctm.f;
    final x = (_operands[0] as num).toDouble();
    final y = (_operands[1] as num).toDouble();
    final w = (_operands[2] as num).toDouble();
    final h = (_operands[3] as num).toDouble();
    final p0 = (tx(x, y), ty(x, y));
    final p1 = (tx(x + w, y), ty(x + w, y));
    final p2 = (tx(x + w, y + h), ty(x + w, y + h));
    final p3 = (tx(x, y + h), ty(x, y + h));
    final width = math.sqrt((p1.$1 - p0.$1) * (p1.$1 - p0.$1) + (p1.$2 - p0.$2) * (p1.$2 - p0.$2));
    final height = math.sqrt((p3.$1 - p0.$1) * (p3.$1 - p0.$1) + (p3.$2 - p0.$2) * (p3.$2 - p0.$2));
    final thin = width <= 2 || height <= 2;
    final edges = <_RuleSegment>[
      _RuleSegment(x0: p0.$1, y0: p0.$2, x1: p1.$1, y1: p1.$2, stroked: false),
      _RuleSegment(x0: p1.$1, y0: p1.$2, x1: p2.$1, y1: p2.$2, stroked: false),
      _RuleSegment(x0: p2.$1, y0: p2.$2, x1: p3.$1, y1: p3.$2, stroked: false),
      _RuleSegment(x0: p3.$1, y0: p3.$2, x1: p0.$1, y1: p0.$2, stroked: false),
    ];
    _pathSegments += 4;
    if (thin) {
      _pendingSegments.addAll(edges);
    } else {
      _pendingFatRectEdges.addAll(edges);
    }
  }

  /// Flushes the path: stroking turns pending segments (and fat-rect
  /// edges) into rules; a pure fill paints the fat edges away — that
  /// is the background-rectangle filter. Clipped paths draw nothing.
  void _paintPath({required final bool stroked}) {
    if (_rules != null && !_clipPending) {
      if (stroked && _rules.length < _maxRuleSegments) {
        _rules
          ..addAll(_pendingSegments)
          ..addAll(_pendingFatRectEdges);
      }
    }
    _clearPath();
  }

  void _clearPath() {
    _pendingSegments.clear();
    _pendingFatRectEdges.clear();
    _lastPoint = null;
    _clipPending = false;
  }
}

final class _Run {
  const _Run({
    required this.text,
    required this.x,
    required this.baselineY,
    required this.width,
    required this.fontSize,
    required this.rotated,
    this.cells = const <_GlyphCell>[],
  });

  final String text;
  final double x;
  final double baselineY;
  final double width;
  final double fontSize;
  final bool rotated;

  /// Per-character glyph cells in device space; empty unless the
  /// extraction collected layout primitives.
  final List<_GlyphCell> cells;
}

/// One character code's placement: the decoded characters, the pen
/// position (device space, baseline origin), the device advance along
/// the text direction and the direction unit vector.
final class _GlyphCell {
  const _GlyphCell({
    required this.text,
    required this.x,
    required this.y,
    required this.advance,
    required this.fontSize,
    required this.directionX,
    required this.directionY,
    required this.horizontal,
  });

  final String text;
  final double x;
  final double y;
  final double advance;
  final double fontSize;
  final double directionX;
  final double directionY;
  final bool horizontal;
}

/// One straight rule segment in device space (a stroked line or a
/// rectangle edge), the raw material of table detection.
final class _RuleSegment {
  const _RuleSegment({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required this.stroked,
  });

  final double x0;
  final double y0;
  final double x1;
  final double y1;
  final bool stroked;
}

final class _GraphicsState {
  _Mat ctm = _Mat.identity;
  PdfFont? font;
  double fontSize = 0;
  double charSpacing = 0;
  double wordSpacing = 0;
  double horizontalScale = 1;
  double leading = 0;
  double rise = 0;

  _GraphicsState copy() {
    final copy = _GraphicsState()
      ..ctm = ctm
      ..font = font
      ..fontSize = fontSize
      ..charSpacing = charSpacing
      ..wordSpacing = wordSpacing
      ..horizontalScale = horizontalScale
      ..leading = leading
      ..rise = rise;

    return copy;
  }
}

/// Row-major matrix `[a b c d e f]` — `[x' = a·x + c·y + e,
/// y' = b·x + d·y + f]` — matching the PDF convention.
final class _Mat {
  const _Mat(this.a, this.b, this.c, this.d, this.e, this.f);

  static const _Mat identity = _Mat(1, 0, 0, 1, 0, 0);

  factory _Mat.translation(final double tx, final double ty) => _Mat(1, 0, 0, 1, tx, ty);

  /// Applies [m] first, then [n].
  static _Mat multiply(final _Mat m, final _Mat n) {
    return _Mat(
      n.a * m.a + n.b * m.c,
      n.a * m.b + n.b * m.d,
      n.c * m.a + n.d * m.c,
      n.c * m.b + n.d * m.d,
      n.e * m.a + n.f * m.c + m.e,
      n.e * m.b + n.f * m.d + m.f,
    );
  }

  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;
}

/// Sequential content-stream tokenizer.
///
/// Yields numbers, strings (literal and hex), names, arrays and
/// dictionaries as operand values, and bare keywords as operators.
/// Inline images (`BI … ID <binary> EI`) are skipped wholesale.
final class _ContentLexer {
  _ContentLexer(this.bytes);

  final Uint8List bytes;
  int _pos = 0;

  _Token? next() {
    _skipSpace();
    if (_atEnd()) return null;
    final byte = bytes[_pos];
    if (byte == 0x2F) return _Operand(_name());
    if (byte == 0x28) return _Operand(_literalString());
    if (byte == 0x3C) {
      if (_pos + 1 < bytes.length && bytes[_pos + 1] == 0x3C) {
        _pos += 2;

        return _Operand(_dictionary());
      }

      return _Operand(_hexString());
    }
    if (byte == 0x5B) {
      _pos++;
      final items = <Object?>[];
      while (true) {
        _skipSpace();
        if (_atEnd()) break;
        if (bytes[_pos] == 0x5D) {
          _pos++;

          break;
        }
        final token = next();
        if (token == null || token is _Operator) break;
        items.add((token as _Operand).value);
      }

      return _Operand(items);
    }
    if (byte == 0x2B || byte == 0x2D || byte == 0x2E || (byte >= 0x30 && byte <= 0x39)) {
      return _Operand(_number());
    }

    return _Operator(_keyword());
  }

  bool _atEnd() => _pos >= bytes.length;

  void _skipSpace() {
    while (!_atEnd()) {
      final byte = bytes[_pos];
      if (byte == 0x25) {
        while (!_atEnd() && bytes[_pos] != 0x0A && bytes[_pos] != 0x0D) {
          _pos++;
        }
      } else if (byte == 0 ||
          byte == 0x09 ||
          byte == 0x0A ||
          byte == 0x0C ||
          byte == 0x0D ||
          byte == 0x20) {
        _pos++;
      } else {
        return;
      }
    }
  }

  double _number() {
    final start = _pos;
    while (!_atEnd()) {
      final byte = bytes[_pos];
      final numeric =
          (byte >= 0x30 && byte <= 0x39) || byte == 0x2B || byte == 0x2D || byte == 0x2E;
      if (!numeric) break;
      _pos++;
    }

    var literal = String.fromCharCodes(bytes, start, _pos);
    if (literal.endsWith('.')) literal = '${literal}0';

    return double.tryParse(literal) ?? 0;
  }

  String _name() {
    _pos++; // /
    final start = _pos;
    while (!_atEnd() && _isRegular(bytes[_pos])) {
      _pos++;
    }

    return String.fromCharCodes(bytes, start, _pos);
  }

  String _keyword() {
    final start = _pos;
    while (!_atEnd() && _isRegular(bytes[_pos])) {
      _pos++;
    }

    final keyword = String.fromCharCodes(bytes, start, _pos);
    if (keyword == 'BI') _skipInlineImage();
    if (keyword.isEmpty && _pos < bytes.length) {
      // A delimiter the token shapes above cannot classify (a stray
      // `>` from a mis-nested marked-content dictionary, a `)` or
      // `]` in unexpected context): consume it so the interpreter
      // always makes progress. Returning without advancing would
      // spin here until the token budget burns (~108 ms per stream
      // measured) and abort the rest of the content.
      _pos++;
    }

    return keyword;
  }

  Uint8List _literalString() {
    _pos++;
    final out = BytesBuilder(copy: false);
    var depth = 1;
    while (!_atEnd() && depth > 0) {
      final byte = bytes[_pos];
      if (byte == 0x5C) {
        _pos++;
        if (_atEnd()) break;
        final escape = bytes[_pos];
        switch (escape) {
          case 0x6E:
            out.addByte(0x0A);
            _pos++;
          case 0x72:
            out.addByte(0x0D);
            _pos++;
          case 0x74:
            out.addByte(0x09);
            _pos++;
          case 0x62:
            out.addByte(0x08);
            _pos++;
          case 0x66:
            out.addByte(0x0C);
            _pos++;
          case 0x28:
            out.addByte(0x28);
            _pos++;
          case 0x29:
            out.addByte(0x29);
            _pos++;
          case 0x5C:
            out.addByte(0x5C);
            _pos++;
          case 0x0D:
            _pos++;
            if (!_atEnd() && bytes[_pos] == 0x0A) _pos++;
          case 0x0A:
            _pos++;
          default:
            if (escape >= 0x30 && escape <= 0x37) {
              var octal = escape - 0x30;
              _pos++;
              for (var digit = 0; digit < 2 && !_atEnd(); digit++) {
                final next = bytes[_pos];
                if (next < 0x30 || next > 0x37) break;
                octal = octal * 8 + (next - 0x30);
                _pos++;
              }
              out.addByte(octal & 0xFF);
            } else {
              out.addByte(escape);
              _pos++;
            }
        }

        continue;
      }
      if (byte == 0x28) depth++;
      if (byte == 0x29) {
        depth--;
        if (depth == 0) {
          _pos++;

          break;
        }
      }
      out.addByte(byte);
      _pos++;
    }

    return out.toBytes();
  }

  Uint8List _hexString() {
    _pos++; // <
    final out = BytesBuilder(copy: false);
    var pending = -1;
    while (!_atEnd()) {
      final byte = bytes[_pos++];
      if (byte == 0x3E) break;

      var value = -1;
      if (byte >= 0x30 && byte <= 0x39) {
        value = byte - 0x30;
      } else if (byte >= 0x41 && byte <= 0x46) {
        value = byte - 0x41 + 10;
      } else if (byte >= 0x61 && byte <= 0x66) {
        value = byte - 0x61 + 10;
      }

      if (value < 0) continue;
      if (pending < 0) {
        pending = value;
      } else {
        out.addByte(pending * 16 + value);
        pending = -1;
      }
    }
    if (pending >= 0) out.addByte(pending * 16);

    return out.toBytes();
  }

  /// Consumes a dictionary body up to its closing `>>`; content
  /// streams only carry these inside inline images and marked-content
  /// property lists (skipped wholesale), so the entries themselves
  /// are not kept. Hex strings `<...>` and literal strings `(...)`
  /// are skipped as units so their closing delimiters cannot be
  /// mis-paired with the dictionary's own `>>` — the Tagged-PDF shape
  /// `/Span<</ActualText<FEFF0044>>> BDC` must leave nothing behind.
  Map<String, Object?> _dictionary() {
    var depth = 1;
    while (!_atEnd() && depth > 0) {
      final byte = bytes[_pos];
      if (byte == 0x3C && _pos + 1 < bytes.length && bytes[_pos + 1] == 0x3C) {
        depth++;
        _pos += 2;
        continue;
      }
      if (byte == 0x3E && _pos + 1 < bytes.length && bytes[_pos + 1] == 0x3E) {
        depth--;
        _pos += 2;
        continue;
      }
      if (byte == 0x3C) {
        // Hex string: skip to its own closing `>`.
        _pos++;
        while (!_atEnd() && bytes[_pos] != 0x3E) {
          _pos++;
        }
        _pos++;

        continue;
      }
      if (byte == 0x28) {
        // Literal string: skip balanced parentheses with escapes.
        _pos++;
        var depth2 = 1;
        while (!_atEnd() && depth2 > 0) {
          final b = bytes[_pos];
          if (b == 0x5C) {
            _pos += 2;
            continue;
          }
          if (b == 0x28) depth2++;
          if (b == 0x29) depth2--;
          _pos++;
        }
        continue;
      }
      _pos++;
    }

    return <String, Object?>{};
  }

  void _skipInlineImage() {
    // Scan for whitespace-delimited EI after the ID binary payload.
    var pos = _pos;
    while (pos + 2 < bytes.length) {
      if (bytes[pos] == 0x45 && bytes[pos + 1] == 0x49) {
        final before = bytes[pos - 1];
        if (before == 0x20 ||
            before == 0x0A ||
            before == 0x0D ||
            before == 0x09 ||
            before == 0x00) {
          _pos = pos + 2;

          return;
        }
      }
      pos++;
    }
    _pos = bytes.length;
  }
}

sealed class _Token {
  const _Token();
}

/// An operand value: number (double), name (`String`), string
/// (`Uint8List`), array (`List<Object?>`) or dictionary
/// (`Map<String, Object?>`).
final class _Operand extends _Token {
  const _Operand(this.value);

  final Object? value;
}

/// A bare keyword operator (`Tj`, `q`, `BT`, ...).
final class _Operator extends _Token {
  const _Operator(this.name);

  final String name;
}

bool _isRegular(final int byte) {
  return byte != 0 &&
      byte != 0x09 &&
      byte != 0x0A &&
      byte != 0x0C &&
      byte != 0x0D &&
      byte != 0x20 &&
      byte != 0x28 &&
      byte != 0x29 &&
      byte != 0x3C &&
      byte != 0x3E &&
      byte != 0x5B &&
      byte != 0x5D &&
      byte != 0x7B &&
      byte != 0x7D &&
      byte != 0x2F &&
      byte != 0x25;
}

/// Decodes the drawable bytes of the image object [objectNumber] the
/// way the extractor's placements do: JPEG passthrough for DCTDecode,
/// the bitmap codecs to a grayscale PNG for CCITT/JBIG2. Returns null
/// when the number carries no image stream or its codec stays
/// unsupported — the on-demand path sessions use to serve
/// `images/pdf-image-<n>.<ext>` without a materialized owning page.
(Uint8List, String)? decodePdfImageObject(final PdfDocument document, final int objectNumber) {
  if (objectNumber <= 0) return null;

  final object = document.object(objectNumber);
  if (object is! PdfStream) return null;

  final subtype = document.resolve(object.dictionary['Subtype']);
  if (subtype is! PdfName || subtype.value != 'Image') return null;

  return decodePdfImageStream(document, object);
}

/// Decodes one image [stream] already resolved to a `/Subtype /Image`
/// object: `(bytes, extension)` when a file format comes out, null
/// when the codec stays unsupported (geometry-only placement).
(Uint8List, String)? decodePdfImageStream(final PdfDocument document, final PdfStream stream) {
  final lastFilter = pdfLastFilterName(document, stream);
  if (lastFilter == 'DCTDecode') return (stream.bytes, 'jpg');
  if (lastFilter != 'CCITTFaxDecode' && lastFilter != 'JBIG2Decode') return null;

  try {
    final packed = decodePdfStream(stream, document.resolve);
    final bitmap = PdfBitmap.fromPacked(
      width: pdfImageDimension(document, stream, 'Width', 'W'),
      height: pdfImageDimension(document, stream, 'Height', 'H'),
      packed: packed,
    );

    return (bitmap.toPngBytes(), 'png');
  } on PdfException {
    // Degrade to geometry-only, like every unsupported image.
    return null;
  }
}

/// The innermost filter name of an image stream's `/Filter` (a
/// bare name or an array), null when the stream is unfiltered.
String? pdfLastFilterName(final PdfDocument document, final PdfStream stream) {
  final filter = document.resolve(stream.dictionary['Filter'] ?? const PdfNull());
  if (filter is PdfName) return filter.value;
  if (filter is PdfArray) {
    String? last;
    for (final item in filter.items) {
      if (item is PdfName) last = item.value;
    }

    return last;
  }

  return null;
}

/// The integer image dimension an image stream carries under [long]
/// or its PDF short form [short]; 0 when neither is a number.
int pdfImageDimension(
  final PdfDocument document,
  final PdfStream stream,
  final String long,
  final String short,
) {
  final value = document.resolve(
    stream.dictionary[long] ?? stream.dictionary[short] ?? const PdfNull(),
  );
  if (value is PdfNumber) return value.intValue;

  return 0;
}
