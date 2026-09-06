import 'dart:math' as math;
import 'dart:typed_data';

import '../entities/pdf_page.dart';
import '../entities/pdf_page_text.dart';
import '../exceptions/pdf_exception.dart';
import '../header/pdf_document.dart';
import '../header/pdf_object.dart';
import '../utils/pdf_bitmap.dart';
import '../utils/pdf_stream_filters.dart';
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
    final runs = <_Run>[];
    final images = <PdfImageBox>[];
    for (final stream in _contentStreams(page)) {
      Uint8List content;
      try {
        content = document.decodeStream(stream);
      } on Exception {
        continue;
      }
      _interpret(content, _resourcesOf(page), runs, images, onImage);
    }

    return _toPageText(runs, images, page);
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
  ) {
    final lexer = _ContentLexer(content);
    final operands = <Object?>[];

    final gstates = <_GraphicsState>[];
    var gstate = _GraphicsState();
    var textMatrix = _Mat.identity;
    var lineMatrix = _Mat.identity;
    var inText = false;
    var budget = 4000000;

    while (true) {
      final token = lexer.next();
      if (token == null || budget-- <= 0) break;

      if (token is _Operator) {
        switch (token.name) {
          case 'q':
            gstates.add(gstate);
            gstate = gstate.copy();
          case 'Q':
            if (gstates.isNotEmpty) gstate = gstates.removeLast();
          case 'cm':
            final m = _matrixOperands(operands);
            if (m != null) gstate.ctm = _Mat.multiply(m, gstate.ctm);
          case 'BT':
            inText = true;
            textMatrix = _Mat.identity;
            lineMatrix = _Mat.identity;
          case 'ET':
            inText = false;
          case 'Tf':
            if (operands.length >= 2 && operands[0] is String && operands[1] is num) {
              gstate.font = _fontOf(_fontEntry(resources, operands[0] as String));
              gstate.fontSize = (operands[1] as num).toDouble();
            }
          case 'Tc':
            gstate.charSpacing = _num(operands);
          case 'Tw':
            gstate.wordSpacing = _num(operands);
          case 'Tz':
            gstate.horizontalScale = _num(operands, fallback: 100) / 100;
          case 'TL':
            gstate.leading = _num(operands);
          case 'Ts':
            gstate.rise = _num(operands);
          case 'Td':
            final tx = _num(operands);
            final ty = _num(operands, index: 1);
            lineMatrix = _Mat.multiply(_Mat.translation(tx, ty), lineMatrix);
            textMatrix = lineMatrix;
          case 'TD':
            final tx = _num(operands);
            final ty = _num(operands, index: 1);
            gstate.leading = -ty;
            lineMatrix = _Mat.multiply(_Mat.translation(tx, ty), lineMatrix);
            textMatrix = lineMatrix;
          case 'Tm':
            final m = _matrixOperands(operands);
            if (m != null) {
              lineMatrix = m;
              textMatrix = m;
            }
          case 'T*':
            lineMatrix = _Mat.multiply(_Mat.translation(0, -gstate.leading), lineMatrix);
            textMatrix = lineMatrix;
          case 'Tj':
            final bytes = _stringOperand(operands);
            if (inText && bytes != null) {
              _showText(bytes, textMatrix, gstate, runs);
            }
          case "'":
            lineMatrix = _Mat.multiply(_Mat.translation(0, -gstate.leading), lineMatrix);
            textMatrix = lineMatrix;
            final bytes = _stringOperand(operands);
            if (inText && bytes != null) {
              _showText(bytes, textMatrix, gstate, runs);
            }
          case '"':
            if (operands.length >= 3) {
              gstate.wordSpacing = (operands[0] as num?)?.toDouble() ?? gstate.wordSpacing;
              gstate.charSpacing = (operands[1] as num?)?.toDouble() ?? gstate.charSpacing;
            }
            lineMatrix = _Mat.multiply(_Mat.translation(0, -gstate.leading), lineMatrix);
            textMatrix = lineMatrix;
            final bytes = _stringOperand(operands);
            if (inText && bytes != null) {
              _showText(bytes, textMatrix, gstate, runs);
            }
          case 'TJ':
            final array = operands.length == 1 && operands[0] is List<Object?>
                ? operands[0] as List<Object?>
                : null;
            if (inText && array != null) {
              for (final element in array) {
                if (element is Uint8List) {
                  textMatrix = _showText(element, textMatrix, gstate, runs);
                } else if (element is num) {
                  final shift = -element / 1000 * gstate.fontSize * gstate.horizontalScale;
                  textMatrix = _Mat.multiply(_Mat.translation(shift, 0), textMatrix);
                }
              }
            }
          case 'Do':
            if (operands.length == 1 && operands[0] is String) {
              _drawXObject(operands[0] as String, resources, gstate, images, onImage);
            }
        }
        operands.clear();
      } else {
        operands.add((token as _Operand).value);
        if (operands.length > 64) operands.removeAt(0);
      }
    }
  }

  PdfObject? _fontEntry(final PdfDictionary? resources, final String name) {
    final fonts = document.resolve(resources?['Font']);
    if (fonts is PdfDictionary) return fonts[name];

    return null;
  }

  /// Shows [bytes], records the run and returns the advanced text
  /// matrix.
  _Mat _showText(
    final Uint8List bytes,
    final _Mat textMatrix,
    final _GraphicsState gstate,
    final List<_Run> runs,
  ) {
    final font = gstate.font ?? _fallbackFont();
    final (text, advanceEm, codeCount, spaceCount) = font.decode(bytes);
    final advanceText =
        advanceEm * gstate.fontSize +
        codeCount * gstate.charSpacing +
        spaceCount * gstate.wordSpacing;
    final effective = _Mat.multiply(
      _Mat.translation(0, gstate.rise),
      _Mat.multiply(textMatrix, gstate.ctm),
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
        ),
      );
    }

    return _Mat.multiply(_Mat.translation(advanceText * gstate.horizontalScale, 0), textMatrix);
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
    String extension = '';
    Uint8List? imageBytes;
    if (number != 0) {
      final lastFilter = _lastFilterName(stream);
      if (lastFilter == 'DCTDecode') {
        extension = 'jpg';
        imageBytes = stream.bytes;
      } else if (lastFilter == 'CCITTFaxDecode' || lastFilter == 'JBIG2Decode') {
        try {
          final packed = decodePdfStream(stream, document.resolve);
          final bitmap = PdfBitmap.fromPacked(
            width: _imageDimension(stream, 'Width', 'W'),
            height: _imageDimension(stream, 'Height', 'H'),
            packed: packed,
          );
          extension = 'png';
          imageBytes = bitmap.toPngBytes();
        } on PdfException {
          // Degrade to geometry-only, like every unsupported image.
        }
      }
    }

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

  /// The innermost filter name of an image stream's `/Filter` (a
  /// bare name or an array), null when the stream is unfiltered.
  String? _lastFilterName(final PdfStream stream) {
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

  int _imageDimension(final PdfStream stream, final String long, final String short) {
    final value = document.resolve(
      stream.dictionary[long] ?? stream.dictionary[short] ?? const PdfNull(),
    );
    if (value is PdfNumber) return value.intValue;
    return 0;
  }

  PdfPageText _toPageText(
    final List<_Run> runs,
    final List<PdfImageBox> images,
    final PdfPage page,
  ) {
    final box = page.cropBox ?? page.mediaBox;
    final boxX0 = box[0];
    final boxY0 = box[1];
    final boxX1 = box[2];
    final boxY1 = box[3];
    final pageWidth = boxX1 - boxX0;
    final pageHeight = boxY1 - boxY0;

    // Clip to the visible box (a little slack), drop noise.
    final visible = runs
        .where(
          (final run) =>
              run.text.trim().isNotEmpty &&
              run.x >= boxX0 - 8 &&
              run.x <= boxX1 + 8 &&
              run.baselineY >= boxY0 - 8 &&
              run.baselineY <= boxY1 + 8,
        )
        .toList();

    // Group runs into lines by baseline proximity.
    visible.sort((final a, final b) => b.baselineY.compareTo(a.baselineY));
    final clusters = <List<_Run>>[];
    for (final run in visible) {
      if (clusters.isNotEmpty) {
        final cluster = clusters.last;
        final anchor = cluster.first;
        final tolerance =
            0.45 * (run.fontSize < anchor.fontSize ? run.fontSize : anchor.fontSize) + 0.6;
        if ((run.baselineY - anchor.baselineY).abs() <= tolerance) {
          cluster.add(run);
          continue;
        }
      }
      clusters.add(<_Run>[run]);
    }

    final lines = <PdfTextLine>[];
    for (final cluster in clusters) {
      cluster.sort((final a, final b) => a.x.compareTo(b.x));
      final buffer = StringBuffer();
      var previousRight = cluster.first.x;
      var left = cluster.first.x;
      var right = cluster.first.x + cluster.first.width;
      var height = 0.0;
      var fontSize = 0.0;
      var baseline = cluster.first.baselineY;
      var rotated = false;
      var first = true;
      var previousFontSize = cluster.first.fontSize;
      for (final run in cluster) {
        final smaller = run.fontSize < previousFontSize ? run.fontSize : previousFontSize;
        final gapThreshold = 0.28 * smaller + 0.9;
        if (!first) {
          final gap = run.x - previousRight;
          if (gap > gapThreshold) buffer.write(' ');
        }
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
      if (text.isEmpty) continue;

      lines.add(
        PdfTextLine(
          text: text,
          x: left - boxX0,
          // Baseline sits ~0.8 em under the visual top of the line.
          y: boxY1 - (baseline + height * 0.8),
          width: right - left,
          height: height,
          fontSize: fontSize,
          rotated: rotated,
        ),
      );
    }

    // Reading order: top to bottom, then left to right.
    lines.sort((final a, final b) {
      final dy = a.y - b.y;

      return dy.abs() < 0.5 ? a.x.compareTo(b.x) : dy.compareTo(0);
    });

    final placedImages = <PdfImageBox>[
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

    return PdfPageText(
      lines: _rotateAll(lines, page.rotate, pageWidth, pageHeight),
      images: placedImages,
    );
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

final class _Run {
  const _Run({
    required this.text,
    required this.x,
    required this.baselineY,
    required this.width,
    required this.fontSize,
    required this.rotated,
  });

  final String text;
  final double x;
  final double baselineY;
  final double width;
  final double fontSize;
  final bool rotated;
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
  static _Mat multiply(final _Mat m, final _Mat n) => _Mat(
    n.a * m.a + n.b * m.c,
    n.a * m.b + n.b * m.d,
    n.c * m.a + n.d * m.c,
    n.c * m.b + n.d * m.d,
    n.e * m.a + n.f * m.c + m.e,
    n.e * m.b + n.f * m.d + m.f,
  );

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
  /// streams only carry these inside inline images (skipped
  /// wholesale), so the entries themselves are not kept.
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

bool _isRegular(final int byte) =>
    byte != 0 &&
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
