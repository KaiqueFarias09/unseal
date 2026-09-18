/// The JBIG2 region decoders: generic region (with the template-0
/// fast path), generic refinement, symbol dictionary, text region,
/// pattern dictionary and halftone region.
///
/// Ported from pdf.js v3.11.174 `src/core/jbig2.js`, Apache-2.0;
/// parity comments point at the mirrored functions. Bitmaps are
/// `List<Uint8List>` — one row of 0/1 pixels each, as in pdf.js.
library;

import 'dart:typed_data';

import '../../exceptions/pdf_exception.dart';
import 'arithmetic_decoder.dart';
import 'huffman_decoder.dart';
import 'mmr_decoder.dart';
import 'segment_decoder.dart';

/// The largest byte allocation one decode may request. Corrupt or
/// hostile headers declare absurd dimensions; the cap turns them into
/// clean PdfExceptions instead of out-of-memory kills. 64 MiB of
/// pixels is seven times the largest page in the corpus (A4 300dpi).
const int _jbig2MaxAllocBytes = 64 * 1024 * 1024;

/// The largest symbol count one dictionary or region may request.
const int _jbig2MaxSymbols = 1 << 20;

/// One decoding pass over a segment window: the MQ decoder, the
/// shared arithmetic contexts and the raw bytes
/// (`DecodingContext` in pdf.js).
final class Jbig2DecodingContext {
  /// Creates the context for the window [data[start..end]).
  Jbig2DecodingContext(this.data, this.start, this.end)
    : decoder = Jbig2ArithmeticDecoder(data, start, end),
      contextCache = Jbig2ContextCache();

  /// The segment bytes.
  final Uint8List data;

  /// The window start.
  final int start;

  /// The window end.
  final int end;

  /// The MQ decoder primed on the window.
  final Jbig2ArithmeticDecoder decoder;

  /// The per-segment arithmetic context cache.
  final Jbig2ContextCache contextCache;
}

/// The arithmetic context cache, pdf.js `ContextCache`: one lazily
/// allocated table per procedure id, so each (segment, procedure)
/// pair restarts from the zero state. Slot `'3'` is pre-registered
/// for IAID, as in pdf.js.
// pdf.js jbig2.js ContextCache
final class Jbig2ContextCache {
  final Map<String, Uint8List> _contexts = <String, Uint8List>{
    jbig2IaidContextId: Uint8List(1 << 16),
  };

  /// Returns the contexts for [id], allocating on first use.
  // pdf.js jbig2.js ContextCache.getContexts
  Uint8List getContexts(final String id) => _contexts.putIfAbsent(id, () => Uint8List(1 << 16));
}

/// Template-0 fast path (`decodeBitmapTemplate0` in pdf.js): the
/// standard AT pixels let the context label be maintained with one
/// shift and two lookups per pixel.
// pdf.js jbig2.js decodeBitmapTemplate0
List<Uint8List> _decodeBitmapTemplate0(
  final int width,
  final int height,
  final Jbig2DecodingContext decodingContext,
) {
  jbig2CheckedPixels(width, height);
  final decoder = decodingContext.decoder;
  final contexts = decodingContext.contextCache.getContexts('GB');
  final bitmap = List<Uint8List>.filled(height, Uint8List(0), growable: true);

  // ...ooooo....
  // ..ooooooo... Context template for current pixel (X)
  // .ooooX...... (concatenate values of 'o'-pixels to get contextLabel)
  const oldPixelMask = 0x7bf7; // 01111 0111111 0111

  for (var i = 0; i < height; i++) {
    final row = bitmap[i] = Uint8List(width);
    final row1 = i < 1 ? row : bitmap[i - 1];
    final row2 = i < 2 ? row : bitmap[i - 2];

    // At the beginning of each row:
    // Fill contextLabel with pixels that are above/right of (X)
    var contextLabel =
        (row2[0] << 13) |
        (row2[1] << 12) |
        (row2[2] << 11) |
        (row1[0] << 7) |
        (row1[1] << 6) |
        (row1[2] << 5) |
        (row1[3] << 4);
    for (var j = 0; j < width; j++) {
      final pixel = decoder.readBit(contexts, contextLabel);
      row[j] = pixel;

      // At each pixel: Clear contextLabel pixels that are shifted
      // out of the context, then add new ones.
      contextLabel =
          ((contextLabel & oldPixelMask) << 1) |
          (j + 3 < width ? row2[j + 3] << 11 : 0) |
          (j + 4 < width ? row1[j + 4] << 4 : 0) |
          pixel;
    }
  }

  return bitmap;
}

/// Whether [at] holds the standard template-0 AT pixels.
bool _isStandardAt0(final List<Point> at) {
  return at.length == 4 &&
      at[0].x == 3 &&
      at[0].y == -1 &&
      at[1].x == -3 &&
      at[1].y == -1 &&
      at[2].x == 2 &&
      at[2].y == -2 &&
      at[3].x == -2 &&
      at[3].y == -2;
}

/// 6.2 Generic Region Decoding Procedure (`decodeBitmap` in
/// pdf.js). The skip mask of the original is dropped from this
/// signature: ENABLESKIP is unsupported, as in pdf.js's halftone
/// path.
// pdf.js jbig2.js decodeBitmap
/// Guards a width x height row allocation (one byte per pixel).
int jbig2CheckedPixels(final int width, final int height) {
  if (width < 0 ||
      height < 0 ||
      width > _jbig2MaxAllocBytes ||
      height > _jbig2MaxAllocBytes ||
      width * height > _jbig2MaxAllocBytes) {
    throw PdfException('JBIG2 error: region ${width}x$height exceeds the allocation budget.');
  }

  return width * height;
}

/// 6.2 Generic Region Decoding Procedure (`decodeBitmap` in pdf.js);
/// every region and symbol bitmap funnels through here.
List<Uint8List> jbig2DecodeBitmap(
  final int width,
  final int height,
  final int templateIndex,
  final List<Point> at,
  final Jbig2DecodingContext decodingContext, {
  required final bool isMmr,
  required final bool isPredictionEnabled,
}) {
  if (isMmr) {
    return decodeMmrBitmap(
      decodingContext.data,
      decodingContext.start,
      decodingContext.end,
      width,
      height,
    );
  }

  // Use optimized version for the most common case
  if (templateIndex == 0 && !isPredictionEnabled && _isStandardAt0(at)) {
    return _decodeBitmapTemplate0(width, height, decodingContext);
  }

  return _Jbig2BitmapDecoder(
    width: width,
    height: height,
    templateIndex: templateIndex,
    at: at,
    decodingContext: decodingContext,
    isPredictionEnabled: isPredictionEnabled,
  ).decode();
}

final class _Jbig2BitmapDecoder {
  _Jbig2BitmapDecoder({
    required this.width,
    required this.height,
    required this.templateIndex,
    required this.at,
    required this.decodingContext,
    required this.isPredictionEnabled,
  });

  final int width;
  final int height;
  final int templateIndex;
  final List<Point> at;
  final Jbig2DecodingContext decodingContext;
  final bool isPredictionEnabled;

  List<Uint8List> decode() {
    jbig2CheckedPixels(width, height);
    final template = _BitmapTemplate(templateIndex, at, width);
    final bitmap = <Uint8List>[];
    final decoder = decodingContext.decoder;
    final contexts = decodingContext.contextCache.getContexts('GB');
    final pseudoPixelContext = jbig2ReusedContexts[templateIndex];
    var row = Uint8List(width);
    var ltp = 0;
    var contextLabel = 0;
    for (var i = 0; i < height; i++) {
      if (isPredictionEnabled) {
        ltp = _nextLtp(decoder, contexts, pseudoPixelContext, ltp);
      }
      if (ltp != 0) {
        bitmap.add(row);
        continue;
      }
      row = Uint8List.fromList(row);
      bitmap.add(row);
      for (var j = 0; j < width; j++) {
        contextLabel = template.contextFor(i, j, bitmap, contextLabel);
        row[j] = decoder.readBit(contexts, contextLabel);
      }
    }

    return bitmap;
  }

  int _nextLtp(
    final Jbig2ArithmeticDecoder decoder,
    final Uint8List contexts,
    final int pseudoPixelContext,
    final int ltp,
  ) {
    return ltp ^ decoder.readBit(contexts, pseudoPixelContext);
  }
}

final class _BitmapTemplate {
  _BitmapTemplate(final int templateIndex, final List<Point> at, final int width)
    : _points = <Point>[...jbig2CodingTemplates[templateIndex], ...at],
      _width = width {
    // Sorting is non-standard but maximizes context reuse between adjacent
    // pixels, matching the pdf.js implementation.
    _points.sort((final a, final b) => a.y - b.y != 0 ? a.y - b.y : a.x - b.x);
    _templateX = Int8List(_points.length);
    _templateY = Int8List(_points.length);
    final changingEntries = <int>[];
    for (var index = 0; index < _points.length; index++) {
      final point = _points[index];
      _templateX[index] = point.x;
      _templateY[index] = point.y;
      if (point.x < _minX) _minX = point.x;
      if (point.x > _maxX) _maxX = point.x;
      if (point.y < _minY) _minY = point.y;
      if (index < _points.length - 1 &&
          point.y == _points[index + 1].y &&
          point.x == _points[index + 1].x - 1) {
        _reuseMask |= 1 << (_points.length - 1 - index);
      } else {
        changingEntries.add(index);
      }
    }
    _changingX = Int8List(changingEntries.length);
    _changingY = Int8List(changingEntries.length);
    _changingBits = Uint16List(changingEntries.length);
    for (var index = 0; index < changingEntries.length; index++) {
      final pointIndex = changingEntries[index];
      _changingX[index] = _points[pointIndex].x;
      _changingY[index] = _points[pointIndex].y;
      _changingBits[index] = 1 << (_points.length - 1 - pointIndex);
    }
  }

  final List<Point> _points;
  final int _width;
  late final Int8List _templateX;
  late final Int8List _templateY;
  late final Int8List _changingX;
  late final Int8List _changingY;
  late final Uint16List _changingBits;
  int _reuseMask = 0;
  int _minX = 0;
  int _maxX = 0;
  int _minY = 0;

  int contextFor(
    final int rowIndex,
    final int columnIndex,
    final List<Uint8List> bitmap,
    final int previousContext,
  ) {
    if (columnIndex >= -_minX && columnIndex < _width - _maxX && rowIndex >= -_minY) {
      return _reusedContext(rowIndex, columnIndex, bitmap, previousContext);
    }

    return _fullContext(rowIndex, columnIndex, bitmap);
  }

  int _reusedContext(
    final int rowIndex,
    final int columnIndex,
    final List<Uint8List> bitmap,
    final int previousContext,
  ) {
    var context = (previousContext << 1) & _reuseMask;
    for (var index = 0; index < _changingX.length; index++) {
      final row = rowIndex + _changingY[index];
      final column = columnIndex + _changingX[index];
      if (row >= 0 && row < bitmap.length && column >= 0 && column < _width) {
        if (bitmap[row][column] != 0) {
          context |= _changingBits[index];
        }
      }
    }

    return context;
  }

  int _fullContext(final int rowIndex, final int columnIndex, final List<Uint8List> bitmap) {
    var context = 0;
    for (var index = 0; index < _templateX.length; index++) {
      final column = columnIndex + _templateX[index];
      final row = rowIndex + _templateY[index];
      if (column < 0 || column >= _width || row < 0 || row >= bitmap.length) {
        continue;
      }
      final bit = bitmap[row][column];
      if (bit != 0) {
        context |= bit << (_templateX.length - 1 - index);
      }
    }

    return context;
  }
}

/// 6.3.2 Generic Refinement Region Decoding Procedure
/// (`decodeRefinement` in pdf.js).
// pdf.js jbig2.js decodeRefinement
List<Uint8List> jbig2DecodeRefinement(
  final int width,
  final int height,
  final int templateIndex,
  final List<Uint8List> referenceBitmap,
  final int offsetX,
  final int offsetY,
  final List<Point> at,
  final Jbig2DecodingContext decodingContext, {
  required final bool isPredictionEnabled,
}) {
  var codingTemplate = jbig2RefinementTemplates[templateIndex].coding;
  if (templateIndex == 0) {
    codingTemplate = <Point>[...codingTemplate, at[0]];
  }
  final codingTemplateLength = codingTemplate.length;
  final codingTemplateX = Int32List(codingTemplateLength);
  final codingTemplateY = Int32List(codingTemplateLength);
  for (var k = 0; k < codingTemplateLength; k++) {
    codingTemplateX[k] = codingTemplate[k].x;
    codingTemplateY[k] = codingTemplate[k].y;
  }

  var referenceTemplate = jbig2RefinementTemplates[templateIndex].reference;
  if (templateIndex == 0) {
    referenceTemplate = <Point>[...referenceTemplate, at[1]];
  }
  final referenceTemplateLength = referenceTemplate.length;
  final referenceTemplateX = Int32List(referenceTemplateLength);
  final referenceTemplateY = Int32List(referenceTemplateLength);
  for (var k = 0; k < referenceTemplateLength; k++) {
    referenceTemplateX[k] = referenceTemplate[k].x;
    referenceTemplateY[k] = referenceTemplate[k].y;
  }
  if (referenceBitmap.isEmpty || referenceBitmap[0].isEmpty) {
    // An aggregate reference must carry pixels; pdf.js would throw on
    // the empty read as well, but as a raw RangeError.
    throw const PdfException('JBIG2 error: refinement reference is empty.');
  }

  final referenceWidth = referenceBitmap[0].length;
  final referenceHeight = referenceBitmap.length;

  jbig2CheckedPixels(width, height);
  final pseudoPixelContext = jbig2RefinementReusedContexts[templateIndex];
  final bitmap = <Uint8List>[];

  final decoder = decodingContext.decoder;
  final contexts = decodingContext.contextCache.getContexts('GR');

  var ltp = 0;
  for (var i = 0; i < height; i++) {
    if (isPredictionEnabled) {
      final sltp = decoder.readBit(contexts, pseudoPixelContext);
      ltp ^= sltp;
      if (ltp != 0) {
        throw const PdfException('JBIG2 error: prediction is not supported.');
      }
    }
    final row = Uint8List(width);
    bitmap.add(row);
    for (var j = 0; j < width; j++) {
      var contextLabel = 0;
      for (var k = 0; k < codingTemplateLength; k++) {
        final i0 = i + codingTemplateY[k];
        final j0 = j + codingTemplateX[k];
        if (i0 < 0 || j0 < 0 || j0 >= width) {
          contextLabel <<= 1; // out of bound pixel
        } else {
          contextLabel = (contextLabel << 1) | bitmap[i0][j0];
        }
      }
      for (var k = 0; k < referenceTemplateLength; k++) {
        final i0 = i + referenceTemplateY[k] - offsetY;
        final j0 = j + referenceTemplateX[k] - offsetX;
        if (i0 < 0 || i0 >= referenceHeight || j0 < 0 || j0 >= referenceWidth) {
          contextLabel <<= 1; // out of bound pixel
        } else {
          contextLabel = (contextLabel << 1) | referenceBitmap[i0][j0];
        }
      }
      row[j] = decoder.readBit(contexts, contextLabel);
    }
  }

  return bitmap;
}

/// 6.5.5 Decoding the symbol dictionary
/// (`decodeSymbolDictionary` in pdf.js). The `inputSymbols`
/// parameter carries the imported (referred-to) symbol bitmaps; the
/// return value is the exported symbol list.
// pdf.js jbig2.js decodeSymbolDictionary
List<List<Uint8List>> jbig2DecodeSymbolDictionary(
  final List<List<Uint8List>> symbols,
  final int numberOfNewSymbols,
  final int numberOfExportedSymbols,
  final Jbig2SymbolDictionaryHuffmanTables? huffmanTables,
  final int templateIndex,
  final List<Point> at,
  final int refinementTemplateIndex,
  final List<Point> refinementAt,
  final Jbig2DecodingContext decodingContext,
  final Jbig2BitReader? huffmanInput, {
  required final bool isHuffmanEnabled,
  required final bool isRefinementEnabled,
}) {
  return _Jbig2SymbolDictionaryDecoder(
    symbols: symbols,
    numberOfNewSymbols: numberOfNewSymbols,
    numberOfExportedSymbols: numberOfExportedSymbols,
    huffmanTables: huffmanTables,
    templateIndex: templateIndex,
    at: at,
    refinementTemplateIndex: refinementTemplateIndex,
    refinementAt: refinementAt,
    decodingContext: decodingContext,
    huffmanInput: huffmanInput,
    isHuffmanEnabled: isHuffmanEnabled,
    isRefinementEnabled: isRefinementEnabled,
  ).decode();
}

final class _Jbig2SymbolDictionaryDecoder {
  _Jbig2SymbolDictionaryDecoder({
    required this.symbols,
    required this.numberOfNewSymbols,
    required this.numberOfExportedSymbols,
    required this.huffmanTables,
    required this.templateIndex,
    required this.at,
    required this.refinementTemplateIndex,
    required this.refinementAt,
    required this.decodingContext,
    required this.huffmanInput,
    required this.isHuffmanEnabled,
    required this.isRefinementEnabled,
  });

  final List<List<Uint8List>> symbols;
  final int numberOfNewSymbols;
  final int numberOfExportedSymbols;
  final Jbig2SymbolDictionaryHuffmanTables? huffmanTables;
  final int templateIndex;
  final List<Point> at;
  final int refinementTemplateIndex;
  final List<Point> refinementAt;
  final Jbig2DecodingContext decodingContext;
  final Jbig2BitReader? huffmanInput;
  final bool isHuffmanEnabled;
  final bool isRefinementEnabled;
  final List<List<Uint8List>> newSymbols = <List<Uint8List>>[];
  final List<int> symbolWidths = <int>[];
  late final Jbig2HuffmanTable _exportTable;
  late final int _symbolCodeLength;
  int _currentHeight = 0;

  Jbig2ArithmeticDecoder get _decoder => decodingContext.decoder;

  Jbig2ContextCache get _contextCache => decodingContext.contextCache;

  List<List<Uint8List>> decode() {
    if (isHuffmanEnabled && isRefinementEnabled) {
      throw const PdfException('JBIG2 error: symbol refinement with Huffman is not supported.');
    }
    _symbolCodeLength = _initialiseTables();
    _decodeHeightClasses();

    return _exportSymbols();
  }

  int _initialiseTables() {
    var codeLength = jbig2Log2(symbols.length + numberOfNewSymbols);
    if (isHuffmanEnabled) {
      _exportTable = jbig2GetStandardTable(1); // standard table B.1
      codeLength = codeLength > 1 ? codeLength : 1; // 6.5.8.2.3
    }

    return codeLength;
  }

  void _decodeHeightClasses() {
    var guard = 0;
    while (newSymbols.length < numberOfNewSymbols) {
      if (++guard > _jbig2MaxSymbols) {
        throw const PdfException('JBIG2 error: symbol dictionary does not terminate.');
      }
      _decodeHeightClass();
    }
  }

  void _decodeHeightClass() {
    final deltaHeight = isHuffmanEnabled
        ? huffmanTables!.tableDeltaHeight.decode(huffmanInput!)!
        : decodeJbig2Integer(_contextCache.getContexts('IADH'), 'IADH', _decoder)!;
    _currentHeight += deltaHeight;
    var currentWidth = 0;
    var totalWidth = 0;
    final firstSymbol = isHuffmanEnabled ? symbolWidths.length : 0;
    while (true) {
      final deltaWidth = isHuffmanEnabled
          ? huffmanTables!.tableDeltaWidth.decode(huffmanInput!)
          : decodeJbig2Integer(_contextCache.getContexts('IADW'), 'IADW', _decoder);
      if (deltaWidth == null) {
        break;
      }
      currentWidth += deltaWidth;
      totalWidth += currentWidth;
      _decodeSymbol(currentWidth);
    }
    if (isHuffmanEnabled && !isRefinementEnabled) {
      _decodeCollectiveBitmap(firstSymbol, totalWidth);
    }
  }

  void _decodeSymbol(final int currentWidth) {
    if (isRefinementEnabled) {
      newSymbols.add(_decodeRefinedSymbol(currentWidth));

      return;
    }
    if (isHuffmanEnabled) {
      symbolWidths.add(currentWidth);

      return;
    }
    newSymbols.add(
      jbig2DecodeBitmap(
        currentWidth,
        _currentHeight,
        templateIndex,
        at,
        decodingContext,
        isMmr: false,
        isPredictionEnabled: false,
      ),
    );
  }

  List<Uint8List> _decodeRefinedSymbol(final int currentWidth) {
    final numberOfInstances = decodeJbig2Integer(
      _contextCache.getContexts('IAAI'),
      'IAAI',
      _decoder,
    )!;
    if (numberOfInstances > 1) {
      return jbig2DecodeTextRegion(
        currentWidth,
        _currentHeight,
        0,
        numberOfInstances,
        1,
        [...symbols, ...newSymbols],
        _symbolCodeLength,
        0,
        0,
        1,
        0,
        null,
        refinementTemplateIndex,
        refinementAt,
        decodingContext,
        0,
        null,
        isHuffmanEnabled: isHuffmanEnabled,
        isRefinementEnabled: isRefinementEnabled,
      );
    }

    final symbolId = decodeJbig2Iaid(
      _contextCache.getContexts(jbig2IaidContextId),
      _decoder,
      _symbolCodeLength,
    );
    final rdx = decodeJbig2Integer(_contextCache.getContexts('IARDX'), 'IARDX', _decoder)!;
    final rdy = decodeJbig2Integer(_contextCache.getContexts('IARDY'), 'IARDY', _decoder)!;
    final symbol = symbolId < symbols.length
        ? symbols[symbolId]
        : newSymbols[symbolId - symbols.length];

    return jbig2DecodeRefinement(
      currentWidth,
      _currentHeight,
      refinementTemplateIndex,
      symbol,
      rdx,
      rdy,
      refinementAt,
      decodingContext,
      isPredictionEnabled: false,
    );
  }

  void _decodeCollectiveBitmap(final int firstSymbol, final int totalWidth) {
    final input = huffmanInput!;
    final bitmapSize = huffmanTables!.tableBitmapSize.decode(input)!;
    input.byteAlign();
    final collectiveBitmap = bitmapSize == 0
        ? jbig2ReadUncompressedBitmap(input, totalWidth, _currentHeight)
        : _decodeMmrCollectiveBitmap(bitmapSize, totalWidth);
    _appendCollectiveSymbols(firstSymbol, collectiveBitmap);
  }

  List<Uint8List> _decodeMmrCollectiveBitmap(final int bitmapSize, final int totalWidth) {
    final input = huffmanInput!;
    final originalEnd = input.end;
    final bitmapEnd = input.position + bitmapSize;
    input.end = bitmapEnd;
    final bitmap = decodeMmrBitmap(
      input.data,
      input.position,
      bitmapEnd,
      totalWidth,
      _currentHeight,
    );
    input.end = originalEnd;
    input.position = bitmapEnd;

    return bitmap;
  }

  void _appendCollectiveSymbols(final int firstSymbol, final List<Uint8List> bitmap) {
    final lastSymbol = symbolWidths.length;
    if (firstSymbol == lastSymbol - 1) {
      newSymbols.add(bitmap);

      return;
    }

    var xMin = 0;
    for (var index = firstSymbol; index < lastSymbol; index++) {
      final xMax = xMin + symbolWidths[index];
      final symbolBitmap = <Uint8List>[];
      for (var y = 0; y < _currentHeight; y++) {
        symbolBitmap.add(Uint8List.sublistView(bitmap[y], xMin, xMax));
      }
      newSymbols.add(symbolBitmap);
      xMin = xMax;
    }
  }

  List<List<Uint8List>> _exportSymbols() {
    final flags = _readExportFlags();
    final exported = <List<Uint8List>>[];
    var index = 0;
    for (final symbol in symbols) {
      if (flags[index++]) {
        exported.add(symbol);
      }
    }
    for (var newIndex = 0; newIndex < numberOfNewSymbols; newIndex++) {
      if (flags[index++]) {
        exported.add(newSymbols[newIndex]);
      }
    }

    return exported;
  }

  List<bool> _readExportFlags() {
    final flags = <bool>[];
    var currentFlag = false;
    final totalSymbolsLength = symbols.length + numberOfNewSymbols;
    var guard = 0;
    while (flags.length < totalSymbolsLength) {
      if (++guard > _jbig2MaxSymbols) {
        throw const PdfException('JBIG2 error: exported symbols do not terminate.');
      }
      var run = isHuffmanEnabled
          ? _exportTable.decode(huffmanInput!) ?? 0
          : decodeJbig2Integer(_contextCache.getContexts('IAEX'), 'IAEX', _decoder) ?? 0;
      while (run-- > 0 && flags.length < totalSymbolsLength) {
        flags.add(currentFlag);
      }
      currentFlag = !currentFlag;
    }

    return flags;
  }
}

/// 6.4 Text region decoding procedure (`decodeTextRegion` in
/// pdf.js). [huffmanTables] is non-null only for the Huffman path.
// pdf.js jbig2.js decodeTextRegion
List<Uint8List> jbig2DecodeTextRegion(
  final int width,
  final int height,
  final int defaultPixelValue,
  final int numberOfSymbolInstances,
  final int stripSize,
  final List<List<Uint8List>> inputSymbols,
  final int symbolCodeLength,
  final int transposed,
  final int dsOffset,
  final int referenceCorner,
  final int combinationOperator,
  final Jbig2TextRegionHuffmanTables? huffmanTables,
  final int refinementTemplateIndex,
  final List<Point> refinementAt,
  final Jbig2DecodingContext decodingContext,
  final int logStripSize,
  final Jbig2BitReader? huffmanInput, {
  required final bool isHuffmanEnabled,
  required final bool isRefinementEnabled,
}) {
  return _Jbig2TextRegionDecoder(
    width: width,
    height: height,
    defaultPixelValue: defaultPixelValue,
    numberOfSymbolInstances: numberOfSymbolInstances,
    stripSize: stripSize,
    inputSymbols: inputSymbols,
    symbolCodeLength: symbolCodeLength,
    transposed: transposed,
    dsOffset: dsOffset,
    referenceCorner: referenceCorner,
    combinationOperator: combinationOperator,
    huffmanTables: huffmanTables,
    refinementTemplateIndex: refinementTemplateIndex,
    refinementAt: refinementAt,
    decodingContext: decodingContext,
    logStripSize: logStripSize,
    huffmanInput: huffmanInput,
    isHuffmanEnabled: isHuffmanEnabled,
    isRefinementEnabled: isRefinementEnabled,
  ).decode();
}

final class _Jbig2TextRegionDecoder {
  _Jbig2TextRegionDecoder({
    required this.width,
    required this.height,
    required this.defaultPixelValue,
    required this.numberOfSymbolInstances,
    required this.stripSize,
    required this.inputSymbols,
    required this.symbolCodeLength,
    required this.transposed,
    required this.dsOffset,
    required this.referenceCorner,
    required this.combinationOperator,
    required this.huffmanTables,
    required this.refinementTemplateIndex,
    required this.refinementAt,
    required this.decodingContext,
    required this.logStripSize,
    required this.huffmanInput,
    required this.isHuffmanEnabled,
    required this.isRefinementEnabled,
  });

  final int width;
  final int height;
  final int defaultPixelValue;
  final int numberOfSymbolInstances;
  final int stripSize;
  final List<List<Uint8List>> inputSymbols;
  final int symbolCodeLength;
  final int transposed;
  final int dsOffset;
  final int referenceCorner;
  final int combinationOperator;
  final Jbig2TextRegionHuffmanTables? huffmanTables;
  final int refinementTemplateIndex;
  final List<Point> refinementAt;
  final Jbig2DecodingContext decodingContext;
  final int logStripSize;
  final Jbig2BitReader? huffmanInput;
  final bool isHuffmanEnabled;
  final bool isRefinementEnabled;

  Jbig2ArithmeticDecoder get _decoder => decodingContext.decoder;

  Jbig2ContextCache get _contextCache => decodingContext.contextCache;

  List<Uint8List> decode() {
    if (isHuffmanEnabled && isRefinementEnabled) {
      throw const PdfException('JBIG2 error: refinement with Huffman is not supported.');
    }
    if (combinationOperator != 0 && combinationOperator != 2) {
      throw PdfException('JBIG2 error: operator $combinationOperator is not supported.');
    }
    jbig2CheckedPixels(width, height);
    final bitmap = _emptyBitmap();
    var stripT = -_readDeltaT();
    var firstS = 0;
    var instance = 0;
    var guard = 0;
    while (instance < numberOfSymbolInstances) {
      if (++guard > _jbig2MaxSymbols) {
        throw const PdfException('JBIG2 error: text region does not terminate.');
      }
      stripT += _readDeltaT();
      firstS += _readDeltaFirstS();
      var currentS = firstS;
      while (true) {
        currentS = _decodeInstance(stripT, currentS, bitmap);
        instance++;
        final deltaS = _readDeltaS();
        if (deltaS == null) {
          break;
        }
        currentS += deltaS + dsOffset;
      }
    }

    return bitmap;
  }

  List<Uint8List> _emptyBitmap() {
    return List<Uint8List>.generate(height, (final _) {
      final row = Uint8List(width);
      if (defaultPixelValue != 0) {
        row.fillRange(0, width, defaultPixelValue);
      }

      return row;
    }, growable: true);
  }

  int _readDeltaT() {
    return isHuffmanEnabled
        ? huffmanTables!.tableDeltaT.decode(huffmanInput!) ?? 0
        : decodeJbig2Integer(_contextCache.getContexts('IADT'), 'IADT', _decoder) ?? 0;
  }

  int _readDeltaFirstS() {
    return isHuffmanEnabled
        ? huffmanTables!.tableFirstS.decode(huffmanInput!) ?? 0
        : decodeJbig2Integer(_contextCache.getContexts('IAFS'), 'IAFS', _decoder) ?? 0;
  }

  int? _readDeltaS() {
    return isHuffmanEnabled
        ? huffmanTables!.tableDeltaS.decode(huffmanInput!)
        : decodeJbig2Integer(_contextCache.getContexts('IADS'), 'IADS', _decoder);
  }

  int _decodeInstance(final int stripT, final int currentS, final List<Uint8List> bitmap) {
    final currentT = stripSize > 1 ? _readCurrentT() : 0;
    final symbolId = _readSymbolId();
    if (symbolId < 0 || symbolId >= inputSymbols.length || inputSymbols[symbolId].isEmpty) {
      throw const PdfException('JBIG2 error: text region symbol out of range.');
    }

    var symbolBitmap = inputSymbols[symbolId];
    var symbolWidth = symbolBitmap[0].length;
    var symbolHeight = symbolBitmap.length;
    if (_shouldRefine()) {
      final refined = _refineSymbol(symbolBitmap, symbolWidth, symbolHeight);
      symbolBitmap = refined.$1;
      symbolWidth = refined.$2;
      symbolHeight = refined.$3;
    }
    final t = stripSize * stripT + currentT;
    final offsetT = t - (referenceCorner & 1 != 0 ? 0 : symbolHeight - 1);
    final offsetS = currentS - (referenceCorner & 2 != 0 ? symbolWidth - 1 : 0);
    if (transposed != 0) {
      _drawTransposed(bitmap, symbolBitmap, offsetT, offsetS, symbolWidth, symbolHeight);

      return currentS + symbolHeight - 1;
    }
    _drawNormal(bitmap, symbolBitmap, offsetT, offsetS, symbolWidth, symbolHeight);

    return currentS + symbolWidth - 1;
  }

  int _readCurrentT() {
    return isHuffmanEnabled
        ? huffmanInput!.readBits(logStripSize)
        : decodeJbig2Integer(_contextCache.getContexts('IAIT'), 'IAIT', _decoder) ?? 0;
  }

  int _readSymbolId() {
    return isHuffmanEnabled
        ? huffmanTables!.symbolIdTable.decode(huffmanInput!) ??
              (throw const PdfException('JBIG2 error: symbol id decode failed.'))
        : decodeJbig2Iaid(
            _contextCache.getContexts(jbig2IaidContextId),
            _decoder,
            symbolCodeLength,
          );
  }

  bool _shouldRefine() {
    if (!isRefinementEnabled) {
      return false;
    }

    return isHuffmanEnabled
        ? huffmanInput!.readBit() != 0
        : (decodeJbig2Integer(_contextCache.getContexts('IARI'), 'IARI', _decoder) ?? 0) != 0;
  }

  (List<Uint8List>, int, int) _refineSymbol(
    final List<Uint8List> symbolBitmap,
    final int symbolWidth,
    final int symbolHeight,
  ) {
    final rdw = decodeJbig2Integer(_contextCache.getContexts('IARDW'), 'IARDW', _decoder) ?? 0;
    final rdh = decodeJbig2Integer(_contextCache.getContexts('IARDH'), 'IARDH', _decoder) ?? 0;
    final rdx = decodeJbig2Integer(_contextCache.getContexts('IARDX'), 'IARDX', _decoder) ?? 0;
    final rdy = decodeJbig2Integer(_contextCache.getContexts('IARDY'), 'IARDY', _decoder) ?? 0;
    final width = symbolWidth + rdw;
    final height = symbolHeight + rdh;
    final refined = jbig2DecodeRefinement(
      width,
      height,
      refinementTemplateIndex,
      symbolBitmap,
      (rdw >> 1) + rdx,
      (rdh >> 1) + rdy,
      refinementAt,
      decodingContext,
      isPredictionEnabled: false,
    );

    return (refined, width, height);
  }

  void _drawTransposed(
    final List<Uint8List> bitmap,
    final List<Uint8List> symbolBitmap,
    final int offsetT,
    final int offsetS,
    final int symbolWidth,
    final int symbolHeight,
  ) {
    final maxWidth = width - offsetT < symbolWidth ? width - offsetT : symbolWidth;
    for (var rowIndex = 0; rowIndex < symbolHeight; rowIndex++) {
      final destinationIndex = offsetS + rowIndex;
      if (destinationIndex < 0 || destinationIndex >= bitmap.length) {
        continue;
      }
      _combineRow(bitmap[destinationIndex], symbolBitmap[rowIndex], offsetT, maxWidth);
    }
  }

  void _drawNormal(
    final List<Uint8List> bitmap,
    final List<Uint8List> symbolBitmap,
    final int offsetT,
    final int offsetS,
    final int symbolWidth,
    final int symbolHeight,
  ) {
    for (var rowIndex = 0; rowIndex < symbolHeight; rowIndex++) {
      final destinationIndex = offsetT + rowIndex;
      if (destinationIndex < 0 || destinationIndex >= bitmap.length) {
        continue;
      }
      _combineRow(bitmap[destinationIndex], symbolBitmap[rowIndex], offsetS, symbolWidth);
    }
  }

  void _combineRow(
    final Uint8List destination,
    final Uint8List source,
    final int offset,
    final int length,
  ) {
    for (var index = 0; index < length; index++) {
      final destinationIndex = offset + index;
      if (destinationIndex < 0 || destinationIndex >= destination.length) {
        continue;
      }
      if (combinationOperator == 0) {
        destination[destinationIndex] |= source[index];
      } else {
        destination[destinationIndex] ^= source[index];
      }
    }
  }
}

/// Reads an uncompressed collective bitmap
/// (`readUncompressedBitmap` in pdf.js).
// pdf.js jbig2.js readUncompressedBitmap
List<Uint8List> jbig2ReadUncompressedBitmap(
  final Jbig2BitReader reader,
  final int width,
  final int height,
) {
  jbig2CheckedPixels(width, height);
  final bitmap = List<Uint8List>.generate(height, (_) => Uint8List(width), growable: true);
  for (var y = 0; y < height; y++) {
    final row = bitmap[y];
    for (var x = 0; x < width; x++) {
      row[x] = reader.readBit();
    }
    reader.byteAlign();
  }

  return bitmap;
}

/// 6.7 Pattern dictionary decoding procedure
/// (`decodePatternDictionary` in pdf.js): one collective bitmap
/// split into [maxPatternIndex] + 1 pattern tiles.
// pdf.js jbig2.js decodePatternDictionary
List<List<Uint8List>> jbig2DecodePatternDictionary(
  final int patternWidth,
  final int patternHeight,
  final int maxPatternIndex,
  final int template,
  final Jbig2DecodingContext decodingContext, {
  required final bool isMmr,
}) {
  final at = <Point>[];
  if (!isMmr) {
    at.add(Point(-patternWidth, 0));
    if (template == 0) {
      at.addAll(<Point>[Point(-3, -1), Point(2, -2), Point(-2, -2)]);
    }
  }
  final collectiveWidth = (maxPatternIndex + 1) * patternWidth;
  final collectiveBitmap = jbig2DecodeBitmap(
    collectiveWidth,
    patternHeight,
    template,
    at,
    decodingContext,
    isMmr: isMmr,
    isPredictionEnabled: false,
  );
  // Divide collective bitmap into patterns.
  final patterns = <List<Uint8List>>[];
  for (var i = 0; i <= maxPatternIndex; i++) {
    final xMin = patternWidth * i;
    final xMax = xMin + patternWidth;
    patterns.add(<Uint8List>[
      for (var y = 0; y < patternHeight; y++)
        Uint8List.sublistView(collectiveBitmap[y], xMin, xMax),
    ]);
  }

  return patterns;
}

/// 6.6 Halftone region decoding procedure
/// (`decodeHalftoneRegion` in pdf.js): gray-scale bit planes
/// (Annex C) rendered through the pattern grid.
// pdf.js jbig2.js decodeHalftoneRegion
List<Uint8List> jbig2DecodeHalftoneRegion(
  final List<List<Uint8List>> patterns,
  final int template,
  final int regionWidth,
  final int regionHeight,
  final int defaultPixelValue,
  final int combinationOperator,
  final int gridWidth,
  final int gridHeight,
  final int gridOffsetX,
  final int gridOffsetY,
  final int gridVectorX,
  final int gridVectorY,
  final Jbig2DecodingContext decodingContext, {
  required final bool isMmr,
  required final bool isSkipEnabled,
}) {
  if (isSkipEnabled) {
    throw const PdfException('JBIG2 error: skip is not supported.');
  }
  if (combinationOperator != 0) {
    throw PdfException(
      'JBIG2 error: operator "$combinationOperator" is not supported in halftone region.',
    );
  }

  return _Jbig2HalftoneDecoder(
    patterns: patterns,
    template: template,
    regionWidth: regionWidth,
    regionHeight: regionHeight,
    defaultPixelValue: defaultPixelValue,
    gridWidth: gridWidth,
    gridHeight: gridHeight,
    gridOffsetX: gridOffsetX,
    gridOffsetY: gridOffsetY,
    gridVectorX: gridVectorX,
    gridVectorY: gridVectorY,
    decodingContext: decodingContext,
    isMmr: isMmr,
  ).decode();
}

final class _Jbig2HalftoneDecoder {
  _Jbig2HalftoneDecoder({
    required this.patterns,
    required this.template,
    required this.regionWidth,
    required this.regionHeight,
    required this.defaultPixelValue,
    required this.gridWidth,
    required this.gridHeight,
    required this.gridOffsetX,
    required this.gridOffsetY,
    required this.gridVectorX,
    required this.gridVectorY,
    required this.decodingContext,
    required this.isMmr,
  });

  final List<List<Uint8List>> patterns;
  final int template;
  final int regionWidth;
  final int regionHeight;
  final int defaultPixelValue;
  final int gridWidth;
  final int gridHeight;
  final int gridOffsetX;
  final int gridOffsetY;
  final int gridVectorX;
  final int gridVectorY;
  final Jbig2DecodingContext decodingContext;
  final bool isMmr;

  List<Uint8List> decode() {
    final bitmap = _emptyBitmap();
    final pattern = patterns[0];
    final patternWidth = pattern[0].length;
    final patternHeight = pattern.length;
    final bitsPerValue = jbig2Log2(patterns.length);
    final planes = _readBitPlanes(bitsPerValue);
    _render(bitmap, planes, bitsPerValue, patternWidth, patternHeight);

    return bitmap;
  }

  List<Uint8List> _emptyBitmap() {
    return List<Uint8List>.generate(regionHeight, (final _) {
      final row = Uint8List(regionWidth);
      if (defaultPixelValue != 0) {
        row.fillRange(0, regionWidth, defaultPixelValue);
      }

      return row;
    }, growable: true);
  }

  List<List<Uint8List>?> _readBitPlanes(final int bitsPerValue) {
    final at = <Point>[Point(template <= 1 ? 3 : 2, -1)];
    if (template == 0) {
      at.addAll(<Point>[Point(-3, -1), Point(2, -2), Point(-2, -2)]);
    }
    final planes = List<List<Uint8List>?>.filled(bitsPerValue, null);
    for (var index = bitsPerValue - 1; index >= 0; index--) {
      planes[index] = isMmr
          ? decodeMmrBitmap(
              decodingContext.data,
              decodingContext.start,
              decodingContext.end,
              gridWidth,
              gridHeight,
              endOfBlock: true,
            )
          : jbig2DecodeBitmap(
              gridWidth,
              gridHeight,
              template,
              at,
              decodingContext,
              isMmr: false,
              isPredictionEnabled: false,
            );
    }

    return planes;
  }

  void _render(
    final List<Uint8List> bitmap,
    final List<List<Uint8List>?> planes,
    final int bitsPerValue,
    final int patternWidth,
    final int patternHeight,
  ) {
    for (var row = 0; row < gridHeight; row++) {
      for (var column = 0; column < gridWidth; column++) {
        final patternIndex = _patternIndex(planes, bitsPerValue, row, column);
        final x = (gridOffsetX + row * gridVectorY + column * gridVectorX).toSigned(32) >> 8;
        final y = (gridOffsetY + row * gridVectorX - column * gridVectorY).toSigned(32) >> 8;
        _drawPattern(bitmap, patterns[patternIndex], x, y, patternWidth, patternHeight);
      }
    }
  }

  int _patternIndex(
    final List<List<Uint8List>?> planes,
    final int bitsPerValue,
    final int row,
    final int column,
  ) {
    var bit = 0;
    var patternIndex = 0;
    for (var index = bitsPerValue - 1; index >= 0; index--) {
      bit ^= planes[index]![row][column];
      patternIndex |= bit << index;
    }

    return patternIndex;
  }

  void _drawPattern(
    final List<Uint8List> bitmap,
    final List<Uint8List> pattern,
    final int x,
    final int y,
    final int patternWidth,
    final int patternHeight,
  ) {
    final fits =
        x >= 0 && x + patternWidth <= regionWidth && y >= 0 && y + patternHeight <= regionHeight;
    if (fits) {
      _drawContained(bitmap, pattern, x, y, patternWidth, patternHeight);

      return;
    }
    _drawClipped(bitmap, pattern, x, y, patternWidth, patternHeight);
  }

  void _drawContained(
    final List<Uint8List> bitmap,
    final List<Uint8List> pattern,
    final int x,
    final int y,
    final int patternWidth,
    final int patternHeight,
  ) {
    for (var row = 0; row < patternHeight; row++) {
      final destination = bitmap[y + row];
      final source = pattern[row];
      for (var column = 0; column < patternWidth; column++) {
        destination[x + column] |= source[column];
      }
    }
  }

  void _drawClipped(
    final List<Uint8List> bitmap,
    final List<Uint8List> pattern,
    final int x,
    final int y,
    final int patternWidth,
    final int patternHeight,
  ) {
    for (var row = 0; row < patternHeight; row++) {
      final destinationRow = y + row;
      if (destinationRow < 0 || destinationRow >= regionHeight) {
        continue;
      }
      final destination = bitmap[destinationRow];
      final source = pattern[row];
      for (var column = 0; column < patternWidth; column++) {
        final destinationColumn = x + column;
        if (destinationColumn >= 0 && destinationColumn < regionWidth) {
          destination[destinationColumn] |= source[column];
        }
      }
    }
  }
}
