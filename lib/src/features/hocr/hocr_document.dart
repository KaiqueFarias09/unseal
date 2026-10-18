import '../../foundation/spatial/spatial_rect.dart';

/// A parsed hOCR document: the producer metadata from `head` and the pages
/// in document order.
///
/// The model keeps the format's own detail — integer boxes, the native
/// baseline polynomial, the declared 0..100 confidence, the text angle,
/// every unconsumed title property verbatim — that the shared spatial
/// contract deliberately leaves out. Document order is the reading order;
/// nothing here re-sequences pages or elements.
final class HocrDocument {
  /// Creates a document from validated parts.
  const HocrDocument({
    this.system,
    this.capabilities = const <String>[],
    this.numberOfPages,
    this.languages = const <String>[],
    this.scripts = const <String>[],
    required this.pages,
  });

  /// The `ocr-system` metadata verbatim, when declared.
  final String? system;

  /// The `ocr-capabilities` tokens, when declared; empty otherwise.
  final List<String> capabilities;

  /// The `ocr-number-of-pages` metadata as an integer, when declared and
  /// numeric. Never compared with [pages].
  final int? numberOfPages;

  /// The `ocr-langs` tokens, when declared.
  final List<String> languages;

  /// The `ocr-scripts` tokens, when declared.
  final List<String> scripts;

  /// The `ocr_page` elements in document order; never empty.
  final List<HocrPage> pages;
}

/// Where a page's spatial frame came from.
enum HocrFrameSource {
  /// The page's own `bbox` with positive width and height.
  declared,

  /// The union of every boxed descendant's `bbox`, used when the page
  /// declares no `bbox` or a zero-extent one. A named derivation of
  /// declared boxes, never a guess.
  derivedFromContent,

  /// Neither the page nor any descendant declares a box; the page has no
  /// spatial projection.
  none,
}

/// An hOCR `bbox`: integer pixel coordinates in the image's top-left
/// space, `(x0, y0)` upper-left and `(x1, y1)` lower-right as the spec
/// defines them.
final class HocrBox {
  /// Creates a box; [ArgumentError] reports negative coordinates or an
  /// inverted box. Zero extent is a declared value and is accepted.
  HocrBox({required this.x0, required this.y0, required this.x1, required this.y1}) {
    if (x0 < 0 || y0 < 0 || x1 < 0 || y1 < 0) {
      throw ArgumentError.value('$x0 $y0 $x1 $y1', 'bbox', 'Coordinates must be non-negative');
    }
    if (x1 < x0 || y1 < y0) {
      throw ArgumentError.value(
        '$x0 $y0 $x1 $y1',
        'bbox',
        'Lower-right must not precede upper-left',
      );
    }
  }

  /// The left edge.
  final int x0;

  /// The top edge.
  final int y0;

  /// The right edge.
  final int x1;

  /// The bottom edge.
  final int y1;

  /// `x1 - x0`.
  int get width => x1 - x0;

  /// `y1 - y0`.
  int get height => y1 - y0;

  /// Whether the box encloses no area.
  bool get isDegenerate => width == 0 || height == 0;

  /// The shared rectangle in pixel space.
  SpatialRect get rect => SpatialRect(
    x: x0.toDouble(),
    y: y0.toDouble(),
    width: width.toDouble(),
    height: height.toDouble(),
  );

  /// The smallest box enclosing both.
  HocrBox union(final HocrBox other) => HocrBox(
    x0: x0 < other.x0 ? x0 : other.x0,
    y0: y0 < other.y0 ? y0 : other.y0,
    x1: x1 > other.x1 ? x1 : other.x1,
    y1: y1 > other.y1 ? y1 : other.y1,
  );

  @override
  bool operator ==(final Object other) =>
      other is HocrBox && other.x0 == x0 && other.y0 == y0 && other.x1 == x1 && other.y1 == y1;

  @override
  int get hashCode => Object.hash(x0, y0, x1, y1);

  @override
  String toString() => 'HocrBox($x0 $y0 $x1 $y1)';
}

/// A line's `baseline` polynomial, native: the stored coefficients in
/// stored order (`pn ... p0`) in the line's frame, whose origin is the
/// bottom-left corner of the line's box with y growing downward.
final class HocrBaseline {
  /// Creates a baseline; [ArgumentError] reports fewer than two
  /// coefficients, more than eight, or a non-finite one.
  HocrBaseline({required this.coefficients}) {
    if (coefficients.length < 2 || coefficients.length > 8) {
      throw ArgumentError.value(
        coefficients,
        'coefficients',
        'A baseline carries 2..8 coefficients',
      );
    }
    for (final value in coefficients) {
      if (!value.isFinite) {
        throw ArgumentError.value(value, 'coefficients', 'Must be finite');
      }
    }
  }

  /// The coefficients exactly as stored, highest order first.
  final List<double> coefficients;

  /// The polynomial order (`coefficients.length - 1`; 1 for a straight
  /// line).
  int get order => coefficients.length - 1;

  /// The constant term `p0`: the baseline's offset from the line's bottom
  /// edge at its left edge (negative sits above the bottom edge).
  double get intercept => coefficients.last;

  /// The polynomial's value at horizontal offset [dx] from the line's left
  /// edge, in the line's bottom-left frame.
  double evaluate(final num dx) {
    var result = 0.0;
    for (final coefficient in coefficients) {
      result = result * dx + coefficient;
    }

    return result;
  }

  @override
  String toString() => 'HocrBaseline(${coefficients.join(' ')})';
}

/// A word's declared `x_wconf`: the 0..100 value when the producer wrote
/// a number, or the non-numeric token it wrote instead. A word that
/// declares no `x_wconf` has no [HocrConfidence] at all, so absent, unknown
/// and zero stay three different states.
final class HocrConfidence {
  /// A numeric confidence in 0..100; [ArgumentError] reports a value
  /// outside that range or a non-finite one.
  HocrConfidence.value(final double value) : declared = value, declaredToken = null {
    if (!value.isFinite || value < 0 || value > 100) {
      throw ArgumentError.value(value, 'x_wconf', 'Must lie in 0..100');
    }
  }

  /// A declared but non-numeric confidence (`x_wconf unknown`).
  const HocrConfidence.unknown(final String token) : declared = null, declaredToken = token;

  /// The declared 0..100 value, or null when the producer wrote a
  /// non-numeric token.
  final double? declared;

  /// The non-numeric token the producer wrote, when it did.
  final String? declaredToken;

  /// Whether the producer declared the confidence without a value.
  bool get isUnknown => declared == null;

  /// The shared 0..1 value (`declared / 100`), or null when unknown.
  double? get shared {
    final value = declared;

    return value == null ? null : value / 100.0;
  }

  @override
  String toString() => 'HocrConfidence(${declared ?? declaredToken})';
}

/// One modeled hOCR element: its role token, HTML tag, optional id and
/// box, language and direction attributes, text angle, and every title
/// property the subset does not consume, verbatim.
sealed class HocrElement {
  /// Creates the element.
  const HocrElement({
    required this.className,
    required this.tagName,
    this.id,
    this.box,
    this.language,
    this.xmlLanguage,
    this.direction,
    this.textAngle,
    this.properties = const <String, List<String>>{},
  });

  /// The hOCR role token the element was classified by (`ocr_line`,
  /// `ocr_caption`, `ocrx_block`, ...).
  final String className;

  /// The HTML tag name, lowercase.
  final String tagName;

  /// The `id` attribute verbatim, when declared. May repeat across the
  /// document; nothing in the subset relies on it.
  final String? id;

  /// The `bbox` property, when declared.
  final HocrBox? box;

  /// The `lang` attribute verbatim, when declared.
  final String? language;

  /// The `xml:lang` attribute verbatim, when declared.
  final String? xmlLanguage;

  /// The `dir` attribute verbatim, when declared.
  final String? direction;

  /// The `textangle` property in degrees, counter-clockwise, native. It
  /// never rotates any coordinate.
  final double? textAngle;

  /// Every title property the subset does not consume, by name, with its
  /// value tokens exactly as written.
  final Map<String, List<String>> properties;
}

/// A role element that holds other role elements: a page, a block or a
/// paragraph. The nesting is the producer's own; [lines] and [words]
/// flatten it in document order.
sealed class HocrContainer extends HocrElement {
  /// Creates the container.
  const HocrContainer({
    required super.className,
    required super.tagName,
    super.id,
    super.box,
    super.language,
    super.xmlLanguage,
    super.direction,
    super.textAngle,
    super.properties,
  });

  /// The role elements nested directly in this one, in document order,
  /// after transparent containers are flattened.
  List<HocrElement> get children;

  /// Every line under this element in document order.
  List<HocrLine> get lines {
    final result = <HocrLine>[];
    _collectLines(children, result);

    return result;
  }

  /// Every word under this element in document order.
  List<HocrWord> get words {
    final result = <HocrWord>[];
    for (final line in lines) {
      result.addAll(line.words);
    }

    return result;
  }

  static void _collectLines(final List<HocrElement> nodes, final List<HocrLine> into) {
    for (final node in nodes) {
      switch (node) {
        case HocrLine():
          into.add(node);
        case HocrContainer():
          _collectLines(node.children, into);
        case HocrWord():
          break;
      }
    }
  }
}

/// One `ocr_page`: its declared identity properties and its children in
/// the nesting the producer declared.
final class HocrPage extends HocrContainer {
  /// Creates a page and computes its spatial frame.
  HocrPage({
    required super.className,
    required super.tagName,
    super.id,
    super.box,
    super.language,
    super.xmlLanguage,
    super.direction,
    super.textAngle,
    super.properties,
    this.physicalPageNumber,
    this.logicalPageNumber,
    this.imageName,
    this.imageMd5,
    this.scanResolutionX,
    this.scanResolutionY,
    required this.children,
  }) {
    final declared = box;
    if (declared != null && !declared.isDegenerate) {
      frame = declared;
      frameSource = HocrFrameSource.declared;

      return;
    }
    HocrBox? union;
    void visit(final List<HocrElement> nodes) {
      for (final node in nodes) {
        final nodeBox = node.box;
        if (nodeBox != null) union = union == null ? nodeBox : union!.union(nodeBox);
        switch (node) {
          case HocrContainer():
            visit(node.children);
          case HocrLine():
            visit(node.words);
          case HocrWord():
            break;
        }
      }
    }

    visit(children);
    final derived = union;
    if (derived != null && !derived.isDegenerate) {
      frame = derived;
      frameSource = HocrFrameSource.derivedFromContent;
    } else {
      frame = null;
      frameSource = HocrFrameSource.none;
    }
  }

  /// The `ppageno` property, when declared.
  final int? physicalPageNumber;

  /// The `lpageno` property verbatim, when declared.
  final String? logicalPageNumber;

  /// The `image` property, when declared with a value.
  final String? imageName;

  /// The `imagemd5` property verbatim, when declared.
  final String? imageMd5;

  /// The horizontal `scan_res` in DPI, when declared.
  final int? scanResolutionX;

  /// The vertical `scan_res` in DPI, when declared.
  final int? scanResolutionY;

  @override
  final List<HocrElement> children;

  /// The geometry the spatial page is built on, or null when
  /// [frameSource] is [HocrFrameSource.none].
  late final HocrBox? frame;

  /// How [frame] was chosen.
  late final HocrFrameSource frameSource;
}

/// One content area (`ocr_carea`, `ocrx_block`, or the deprecated
/// `ocr_column`).
final class HocrBlock extends HocrContainer {
  /// Creates a block.
  const HocrBlock({
    required super.className,
    required super.tagName,
    super.id,
    required HocrBox super.box,
    super.language,
    super.xmlLanguage,
    super.direction,
    super.textAngle,
    super.properties,
    required this.children,
  });

  /// The block's `bbox`; the spec requires it.
  @override
  HocrBox get box => super.box!;

  @override
  final List<HocrElement> children;
}

/// One `ocr_par`.
final class HocrParagraph extends HocrContainer {
  /// Creates a paragraph.
  const HocrParagraph({
    required super.className,
    required super.tagName,
    super.id,
    super.box,
    super.language,
    super.xmlLanguage,
    super.direction,
    super.textAngle,
    super.properties,
    required this.children,
  });

  @override
  final List<HocrElement> children;
}

/// One line (`ocr_line`, `ocrx_line`, or a Tesseract line-role class):
/// its words, its own text, and the native baseline.
final class HocrLine extends HocrElement {
  /// Creates a line.
  const HocrLine({
    required super.className,
    required super.tagName,
    super.id,
    required HocrBox super.box,
    super.language,
    super.xmlLanguage,
    super.direction,
    super.textAngle,
    super.properties,
    this.baseline,
    this.hasHardBreak,
    required this.text,
    required this.hasAlternativeReadings,
    required this.words,
  });

  /// The line's `bbox`; the spec requires it.
  @override
  HocrBox get box => super.box!;

  /// The `baseline` polynomial, when declared.
  final HocrBaseline? baseline;

  /// The `hardbreak` property, when declared.
  final bool? hasHardBreak;

  /// The line's own text: its descendant character data verbatim (words,
  /// the whitespace between them, plain text when the line has no
  /// words), with `del` content excluded.
  final String text;

  /// Whether the line, outside its words, carries `ins`/`del`
  /// alternatives.
  final bool hasAlternativeReadings;

  /// The words in document order; empty for plain-text lines.
  final List<HocrWord> words;

  /// The named projection of the baseline into page space at image
  /// column [x]: `box.y1 + baseline.evaluate(x - box.x0)`. Null when the
  /// line declares no baseline.
  double? baselineYAt(final num x) {
    final polynomial = baseline;
    if (polynomial == null) return null;

    return box.y1 + polynomial.evaluate(x - box.x0);
  }
}

/// One `ocrx_word`.
final class HocrWord extends HocrElement {
  /// Creates a word.
  const HocrWord({
    required super.className,
    required super.tagName,
    super.id,
    super.box,
    super.language,
    super.xmlLanguage,
    super.direction,
    super.textAngle,
    super.properties,
    this.confidence,
    required this.text,
    required this.hasAlternativeReadings,
  });

  /// The declared `x_wconf`, or null when the word declares none.
  final HocrConfidence? confidence;

  /// The word's text: its descendant character data verbatim with `del`
  /// content excluded.
  final String text;

  /// Whether the word carries `ins`/`del` alternatives.
  final bool hasAlternativeReadings;
}
