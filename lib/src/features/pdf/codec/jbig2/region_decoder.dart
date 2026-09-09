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
bool _isStandardAt0(final List<Point> at) =>
    at.length == 4 &&
    at[0].x == 3 &&
    at[0].y == -1 &&
    at[1].x == -3 &&
    at[1].y == -1 &&
    at[2].x == 2 &&
    at[2].y == -2 &&
    at[3].x == -2 &&
    at[3].y == -2;

/// 6.2 Generic Region Decoding Procedure (`decodeBitmap` in
/// pdf.js). The skip mask of the original is dropped from this
/// signature: ENABLESKIP is unsupported, as in pdf.js's halftone
/// path.
// pdf.js jbig2.js decodeBitmap
/// The largest byte allocation one decode may request. Corrupt or
/// hostile headers declare absurd dimensions; the cap turns them into
/// clean PdfExceptions instead of out-of-memory kills. 64 MiB of
/// pixels is seven times the largest page in the corpus (A4 300dpi).
const int _jbig2MaxAllocBytes = 64 * 1024 * 1024;

/// The largest symbol count one dictionary or region may request.
const int _jbig2MaxSymbols = 1 << 20;

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
  final bool mmr,
  final int width,
  final int height,
  final int templateIndex,
  final bool prediction,
  final List<Point> at,
  final Jbig2DecodingContext decodingContext,
) {
  if (mmr) {
    return decodeMmrBitmap(
      decodingContext.data,
      decodingContext.start,
      decodingContext.end,
      width,
      height,
    );
  }

  // Use optimized version for the most common case
  if (templateIndex == 0 && !prediction && _isStandardAt0(at)) {
    return _decodeBitmapTemplate0(width, height, decodingContext);
  }

  final template = <Point>[...jbig2CodingTemplates[templateIndex], ...at];

  // Sorting is non-standard, and it is not required. But sorting increases
  // the number of template bits that can be reused from the previous
  // contextLabel in the main loop.
  template.sort((final a, final b) => a.y - b.y != 0 ? a.y - b.y : a.x - b.x);

  final templateLength = template.length;
  final templateX = Int8List(templateLength);
  final templateY = Int8List(templateLength);
  final changingTemplateEntries = <int>[];
  var reuseMask = 0;
  var minX = 0, maxX = 0, minY = 0;

  for (var k = 0; k < templateLength; k++) {
    templateX[k] = template[k].x;
    templateY[k] = template[k].y;
    if (template[k].x < minX) {
      minX = template[k].x;
    }
    if (template[k].x > maxX) {
      maxX = template[k].x;
    }
    if (template[k].y < minY) {
      minY = template[k].y;
    }
    // Check if the template pixel appears in two consecutive context labels,
    // so it can be reused. Otherwise, we add it to the list of changing
    // template entries.
    if (k < templateLength - 1 &&
        template[k].y == template[k + 1].y &&
        template[k].x == template[k + 1].x - 1) {
      reuseMask |= 1 << (templateLength - 1 - k);
    } else {
      changingTemplateEntries.add(k);
    }
  }
  final changingEntriesLength = changingTemplateEntries.length;

  final changingTemplateX = Int8List(changingEntriesLength);
  final changingTemplateY = Int8List(changingEntriesLength);
  final changingTemplateBit = Uint16List(changingEntriesLength);
  for (var c = 0; c < changingEntriesLength; c++) {
    final k = changingTemplateEntries[c];
    changingTemplateX[c] = template[k].x;
    changingTemplateY[c] = template[k].y;
    changingTemplateBit[c] = 1 << (templateLength - 1 - k);
  }

  // Get the safe bounding box edges from the width, height, minX, maxX, minY
  final sbbLeft = -minX;
  final sbbTop = -minY;
  final sbbRight = width - maxX;

  jbig2CheckedPixels(width, height);
  final pseudoPixelContext = jbig2ReusedContexts[templateIndex];
  var row = Uint8List(width);
  final bitmap = <Uint8List>[];

  final decoder = decodingContext.decoder;
  final contexts = decodingContext.contextCache.getContexts('GB');

  var ltp = 0;
  var contextLabel = 0;
  for (var i = 0; i < height; i++) {
    if (prediction) {
      final sltp = decoder.readBit(contexts, pseudoPixelContext);
      ltp ^= sltp;
      if (ltp != 0) {
        bitmap.add(row); // duplicate previous row
        continue;
      }
    }
    row = Uint8List.fromList(row);
    bitmap.add(row);
    for (var j = 0; j < width; j++) {
      // Are we in the middle of a scanline, so we can reuse contextLabel
      // bits?
      if (j >= sbbLeft && j < sbbRight && i >= sbbTop) {
        // If yes, we can just shift the bits that are reusable and only
        // fetch the remaining ones.
        contextLabel = (contextLabel << 1) & reuseMask;
        for (var k = 0; k < changingEntriesLength; k++) {
          final i0 = i + changingTemplateY[k];
          final j0 = j + changingTemplateX[k];
          // Out-of-range template pixels (possible with a corrupt AT)
          // contribute 0 instead of throwing.
          if (i0 >= 0 && i0 < bitmap.length && j0 >= 0 && j0 < width) {
            final bit = bitmap[i0][j0];
            if (bit != 0) {
              contextLabel |= changingTemplateBit[k];
            }
          }
        }
      } else {
        // compute the contextLabel from scratch
        contextLabel = 0;
        var shift = templateLength - 1;
        for (var k = 0; k < templateLength; k++, shift--) {
          final j0 = j + templateX[k];
          if (j0 >= 0 && j0 < width) {
            final i0 = i + templateY[k];
            if (i0 >= 0 && i0 < bitmap.length) {
              final bit = bitmap[i0][j0];
              if (bit != 0) {
                contextLabel |= bit << shift;
              }
            }
          }
        }
      }
      if (width == 6 && height == 6) {}
      row[j] = decoder.readBit(contexts, contextLabel);
    }
  }
  return bitmap;
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
  final bool prediction,
  final List<Point> at,
  final Jbig2DecodingContext decodingContext,
) {
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
    if (prediction) {
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
  final bool huffman,
  final bool refinement,
  final List<List<Uint8List>> symbols,
  final int numberOfNewSymbols,
  final int numberOfExportedSymbols,
  final Jbig2SymbolDictionaryHuffmanTables? huffmanTables,
  final int templateIndex,
  final List<Point> at,
  final int refinementTemplateIndex,
  final List<Point> refinementAt,
  final Jbig2DecodingContext decodingContext,
  final Jbig2BitReader? huffmanInput,
) {
  if (huffman && refinement) {
    throw const PdfException('JBIG2 error: symbol refinement with Huffman is not supported.');
  }

  final newSymbols = <List<Uint8List>>[];
  var currentHeight = 0;
  var symbolCodeLength = jbig2Log2(symbols.length + numberOfNewSymbols);

  final decoder = decodingContext.decoder;
  final contextCache = decodingContext.contextCache;
  Jbig2HuffmanTable? tableB1;
  List<int>? symbolWidths;
  if (huffman) {
    tableB1 = jbig2GetStandardTable(1); // standard table B.1
    symbolWidths = <int>[];
    symbolCodeLength = symbolCodeLength > 1 ? symbolCodeLength : 1; // 6.5.8.2.3
  }
  var heightClassGuard = 0;
  while (newSymbols.length < numberOfNewSymbols) {
    // Corrupt headers announce millions of symbols; the out-of-band
    // pattern alone terminates this loop, so bound it outright.
    if (++heightClassGuard > _jbig2MaxSymbols) {
      throw const PdfException('JBIG2 error: symbol dictionary does not terminate.');
    }
    final deltaHeight = huffman
        ? huffmanTables!.tableDeltaHeight.decode(huffmanInput!)!
        : decodeJbig2Integer(contextCache.getContexts('IADH'), 'IADH', decoder)!; // 6.5.6
    currentHeight += deltaHeight;
    var currentWidth = 0;
    var totalWidth = 0;
    final firstSymbol = huffman ? symbolWidths!.length : 0;
    while (true) {
      final deltaWidth = huffman
          ? huffmanTables!.tableDeltaWidth.decode(huffmanInput!) // 6.5.7
          : decodeJbig2Integer(contextCache.getContexts('IADW'), 'IADW', decoder);
      if (deltaWidth == null) {
        break; // OOB
      }
      currentWidth += deltaWidth;
      totalWidth += currentWidth;
      List<Uint8List> bitmap;
      if (refinement) {
        // 6.5.8.2 Refinement/aggregate-coded symbol bitmap
        final numberOfInstances = decodeJbig2Integer(
          contextCache.getContexts('IAAI'),
          'IAAI',
          decoder,
        )!;
        if (numberOfInstances > 1) {
          bitmap = jbig2DecodeTextRegion(
            huffman,
            refinement,
            currentWidth,
            currentHeight,
            0,
            numberOfInstances,
            1, // strip size
            [...symbols, ...newSymbols],
            symbolCodeLength,
            0, // transposed
            0, // ds offset
            1, // top left 7.4.3.1.1
            0, // OR operator
            null,
            refinementTemplateIndex,
            refinementAt,
            decodingContext,
            0,
            null,
          );
        } else {
          final symbolId = decodeJbig2Iaid(
            contextCache.getContexts(jbig2IaidContextId),
            decoder,
            symbolCodeLength,
          );
          final rdx = decodeJbig2Integer(
            contextCache.getContexts('IARDX'),
            'IARDX',
            decoder,
          )!; // 6.4.11.3
          final rdy = decodeJbig2Integer(
            contextCache.getContexts('IARDY'),
            'IARDY',
            decoder,
          )!; // 6.4.11.4
          final symbol = symbolId < symbols.length
              ? symbols[symbolId]
              : newSymbols[symbolId - symbols.length];
          bitmap = jbig2DecodeRefinement(
            currentWidth,
            currentHeight,
            refinementTemplateIndex,
            symbol,
            rdx,
            rdy,
            false,
            refinementAt,
            decodingContext,
          );
        }
        newSymbols.add(bitmap);
      } else if (huffman) {
        // Store only symbol width and decode a collective bitmap when the
        // height class is done.
        symbolWidths!.add(currentWidth);
      } else {
        // 6.5.8.1 Direct-coded symbol bitmap
        bitmap = jbig2DecodeBitmap(
          false,
          currentWidth,
          currentHeight,
          templateIndex,
          false,
          at,
          decodingContext,
        );
        newSymbols.add(bitmap);
      }
    }
    if (huffman && !refinement) {
      // 6.5.9 Height class collective bitmap
      final bitmapSize = huffmanTables!.tableBitmapSize.decode(huffmanInput!)!;
      huffmanInput.byteAlign();
      List<Uint8List> collectiveBitmap;
      if (bitmapSize == 0) {
        // Uncompressed collective bitmap
        collectiveBitmap = jbig2ReadUncompressedBitmap(huffmanInput, totalWidth, currentHeight);
      } else {
        // MMR collective bitmap
        final originalEnd = huffmanInput.end;
        final bitmapEnd = huffmanInput.position + bitmapSize;
        huffmanInput.end = bitmapEnd;
        collectiveBitmap = decodeMmrBitmap(
          huffmanInput.data,
          huffmanInput.position,
          bitmapEnd,
          totalWidth,
          currentHeight,
        );
        huffmanInput.end = originalEnd;
        huffmanInput.position = bitmapEnd;
      }
      final numberOfSymbolsDecoded = symbolWidths!.length;
      if (firstSymbol == numberOfSymbolsDecoded - 1) {
        // collectiveBitmap is a single symbol.
        newSymbols.add(collectiveBitmap);
      } else {
        // Divide collectiveBitmap into symbols.
        var xMin = 0;
        for (var i = firstSymbol; i < numberOfSymbolsDecoded; i++) {
          final bitmapWidth = symbolWidths[i];
          final xMax = xMin + bitmapWidth;
          final symbolBitmap = <Uint8List>[];
          for (var y = 0; y < currentHeight; y++) {
            symbolBitmap.add(Uint8List.sublistView(collectiveBitmap[y], xMin, xMax));
          }
          newSymbols.add(symbolBitmap);
          xMin = xMax;
        }
      }
    }
  }

  // 6.5.10 Exported symbols
  final exportedSymbols = <List<Uint8List>>[];
  final flags = <bool>[];
  var currentFlag = false;
  final totalSymbolsLength = symbols.length + numberOfNewSymbols;
  var exportGuard = 0;
  while (flags.length < totalSymbolsLength) {
    if (++exportGuard > _jbig2MaxSymbols) {
      throw const PdfException('JBIG2 error: exported symbols do not terminate.');
    }
    final runLength = huffman
        ? tableB1!.decode(huffmanInput!)
        : decodeJbig2Integer(contextCache.getContexts('IAEX'), 'IAEX', decoder);
    var run = runLength ?? 0;
    // A corrupt stream can decode an absurd run length; flags past the
    // total are never read, so stop as soon as the buffer is full.
    while (run-- > 0 && flags.length < totalSymbolsLength) {
      flags.add(currentFlag);
    }
    currentFlag = !currentFlag;
  }
  var i = 0;
  for (final symbol in symbols) {
    if (flags[i]) {
      exportedSymbols.add(symbol);
    }
    i++;
  }
  for (var j = 0; j < numberOfNewSymbols; i++, j++) {
    if (flags[i]) {
      exportedSymbols.add(newSymbols[j]);
    }
  }
  return exportedSymbols;
}

/// 6.4 Text region decoding procedure (`decodeTextRegion` in
/// pdf.js). [huffmanTables] is non-null only for the Huffman path.
// pdf.js jbig2.js decodeTextRegion
List<Uint8List> jbig2DecodeTextRegion(
  final bool huffman,
  final bool refinement,
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
  final Jbig2BitReader? huffmanInput,
) {
  if (huffman && refinement) {
    throw const PdfException('JBIG2 error: refinement with Huffman is not supported.');
  }
  if (combinationOperator != 0 && combinationOperator != 2) {
    throw PdfException('JBIG2 error: operator $combinationOperator is not supported.');
  }

  // Prepare bitmap
  jbig2CheckedPixels(width, height);
  final bitmap = List<Uint8List>.generate(height, (final i) {
    final row = Uint8List(width);
    if (defaultPixelValue != 0) {
      row.fillRange(0, width, defaultPixelValue);
    }
    return row;
  }, growable: true);

  final decoder = decodingContext.decoder;
  final contextCache = decodingContext.contextCache;
  var stripT = huffman
      ? -(huffmanTables!.tableDeltaT.decode(huffmanInput!) ?? 0)
      : -(decodeJbig2Integer(contextCache.getContexts('IADT'), 'IADT', decoder) ?? 0); // 6.4.6
  var firstS = 0;
  var i = 0;
  var instanceGuard = 0;
  while (i < numberOfSymbolInstances) {
    // Real-world streams may declare more instances than they contain and
    // rely on OOB to terminate the region, as pdf.js does. Keep the
    // termination guard on the actual loop instead of trusting that count.
    if (++instanceGuard > _jbig2MaxSymbols) {
      throw const PdfException('JBIG2 error: text region does not terminate.');
    }
    final deltaT = huffman
        ? huffmanTables!.tableDeltaT.decode(huffmanInput!) ??
              0 // 6.4.6
        : decodeJbig2Integer(contextCache.getContexts('IADT'), 'IADT', decoder) ?? 0;
    stripT += deltaT;

    final deltaFirstS = huffman
        ? huffmanTables!.tableFirstS.decode(huffmanInput!) ??
              0 // 6.4.7
        : decodeJbig2Integer(contextCache.getContexts('IAFS'), 'IAFS', decoder) ?? 0;
    firstS += deltaFirstS;
    var currentS = firstS;
    do {
      var currentT = 0; // 6.4.9
      if (stripSize > 1) {
        currentT = huffman
            ? huffmanInput!.readBits(logStripSize)
            : decodeJbig2Integer(contextCache.getContexts('IAIT'), 'IAIT', decoder) ?? 0;
      }
      final t = stripSize * stripT + currentT;
      final symbolId = huffman
          ? huffmanTables!.symbolIdTable.decode(huffmanInput!) ??
                (throw const PdfException('JBIG2 error: symbol id decode failed.'))
          : decodeJbig2Iaid(
              contextCache.getContexts(jbig2IaidContextId),
              decoder,
              symbolCodeLength,
            );
      final applyRefinement =
          refinement &&
          (huffman
              ? huffmanInput!.readBit() != 0
              : (decodeJbig2Integer(contextCache.getContexts('IARI'), 'IARI', decoder) ?? 0) != 0);
      if (symbolId < 0 || symbolId >= inputSymbols.length || inputSymbols[symbolId].isEmpty) {
        // pdf.js hits the same malformed input as a raw TypeError; the
        // library contract turns it into a PdfException.
        throw const PdfException('JBIG2 error: text region symbol out of range.');
      }
      var symbolBitmap = inputSymbols[symbolId];
      var symbolWidth = symbolBitmap[0].length;
      var symbolHeight = symbolBitmap.length;
      if (applyRefinement) {
        final rdw =
            decodeJbig2Integer(contextCache.getContexts('IARDW'), 'IARDW', decoder) ??
            0; // 6.4.11.1
        final rdh =
            decodeJbig2Integer(contextCache.getContexts('IARDH'), 'IARDH', decoder) ??
            0; // 6.4.11.2
        final rdx =
            decodeJbig2Integer(contextCache.getContexts('IARDX'), 'IARDX', decoder) ??
            0; // 6.4.11.3
        final rdy =
            decodeJbig2Integer(contextCache.getContexts('IARDY'), 'IARDY', decoder) ??
            0; // 6.4.11.4
        symbolWidth += rdw;
        symbolHeight += rdh;
        symbolBitmap = jbig2DecodeRefinement(
          symbolWidth,
          symbolHeight,
          refinementTemplateIndex,
          symbolBitmap,
          (rdw >> 1) + rdx,
          (rdh >> 1) + rdy,
          false,
          refinementAt,
          decodingContext,
        );
      }
      final offsetT = t - (referenceCorner & 1 != 0 ? 0 : symbolHeight - 1);
      final offsetS = currentS - (referenceCorner & 2 != 0 ? symbolWidth - 1 : 0);
      if (transposed != 0) {
        // Place Symbol Bitmap from T1,S1
        for (var s2 = 0; s2 < symbolHeight; s2++) {
          final row = offsetS + s2 >= 0 && offsetS + s2 < bitmap.length
              ? bitmap[offsetS + s2]
              : null;
          if (row == null) {
            continue;
          }
          final symbolRow = symbolBitmap[s2];
          // To ignore Parts of Symbol bitmap which goes
          // outside bitmap region
          final maxWidth = width - offsetT < symbolWidth ? width - offsetT : symbolWidth;
          if (combinationOperator == 0) {
            // OR
            for (var t2 = 0; t2 < maxWidth; t2++) {
              if (offsetT + t2 >= 0) {
                row[offsetT + t2] |= symbolRow[t2];
              }
            }
          } else {
            // XOR
            for (var t2 = 0; t2 < maxWidth; t2++) {
              if (offsetT + t2 >= 0) {
                row[offsetT + t2] ^= symbolRow[t2];
              }
            }
          }
        }
        currentS += symbolHeight - 1;
      } else {
        for (var t2 = 0; t2 < symbolHeight; t2++) {
          final row = offsetT + t2 >= 0 && offsetT + t2 < bitmap.length
              ? bitmap[offsetT + t2]
              : null;
          if (row == null) {
            continue;
          }
          final symbolRow = symbolBitmap[t2];
          if (combinationOperator == 0) {
            // OR
            for (var s2 = 0; s2 < symbolWidth; s2++) {
              if (offsetS + s2 >= 0 && offsetS + s2 < width) {
                row[offsetS + s2] |= symbolRow[s2];
              }
            }
          } else {
            // XOR
            for (var s2 = 0; s2 < symbolWidth; s2++) {
              if (offsetS + s2 >= 0 && offsetS + s2 < width) {
                row[offsetS + s2] ^= symbolRow[s2];
              }
            }
          }
        }
        currentS += symbolWidth - 1;
      }
      i++;
      final deltaS = huffman
          ? huffmanTables!.tableDeltaS.decode(huffmanInput!) // 6.4.8
          : decodeJbig2Integer(contextCache.getContexts('IADS'), 'IADS', decoder);
      if (deltaS == null) {
        break; // OOB
      }
      currentS += deltaS + dsOffset;
    } while (true);
  }
  return bitmap;
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
  final bool mmr,
  final int patternWidth,
  final int patternHeight,
  final int maxPatternIndex,
  final int template,
  final Jbig2DecodingContext decodingContext,
) {
  final at = <Point>[];
  if (!mmr) {
    at.add(Point(-patternWidth, 0));
    if (template == 0) {
      at.addAll(<Point>[Point(-3, -1), Point(2, -2), Point(-2, -2)]);
    }
  }
  final collectiveWidth = (maxPatternIndex + 1) * patternWidth;
  final collectiveBitmap = jbig2DecodeBitmap(
    mmr,
    collectiveWidth,
    patternHeight,
    template,
    false,
    at,
    decodingContext,
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
  final bool mmr,
  final List<List<Uint8List>> patterns,
  final int template,
  final int regionWidth,
  final int regionHeight,
  final int defaultPixelValue,
  final bool enableSkip,
  final int combinationOperator,
  final int gridWidth,
  final int gridHeight,
  final int gridOffsetX,
  final int gridOffsetY,
  final int gridVectorX,
  final int gridVectorY,
  final Jbig2DecodingContext decodingContext,
) {
  if (enableSkip) {
    throw const PdfException('JBIG2 error: skip is not supported.');
  }
  if (combinationOperator != 0) {
    throw PdfException(
      'JBIG2 error: operator "$combinationOperator" is not supported in halftone region.',
    );
  }

  // Prepare bitmap.
  final regionBitmap = List<Uint8List>.generate(regionHeight, (final _) {
    final row = Uint8List(regionWidth);
    if (defaultPixelValue != 0) {
      row.fillRange(0, regionWidth, defaultPixelValue);
    }
    return row;
  }, growable: true);

  final numberOfPatterns = patterns.length;
  final pattern0 = patterns[0];
  final patternWidth = pattern0[0].length;
  final patternHeight = pattern0.length;
  final bitsPerValue = jbig2Log2(numberOfPatterns);
  final at = <Point>[];
  at.add(Point(template <= 1 ? 3 : 2, -1));
  if (template == 0) {
    at.addAll(<Point>[Point(-3, -1), Point(2, -2), Point(-2, -2)]);
  }
  // Annex C. Gray-scale Image Decoding Procedure.
  final grayScaleBitPlanes = List<List<Uint8List>?>.filled(bitsPerValue, null);
  for (var i = bitsPerValue - 1; i >= 0; i--) {
    if (mmr) {
      // MMR bit planes are in one continuous stream. Only EOFB codes
      // indicate the end of each bitmap, so EOFBs must be decoded.
      grayScaleBitPlanes[i] = decodeMmrBitmap(
        decodingContext.data,
        decodingContext.start,
        decodingContext.end,
        gridWidth,
        gridHeight,
        endOfBlock: true,
      );
    } else {
      grayScaleBitPlanes[i] = jbig2DecodeBitmap(
        false,
        gridWidth,
        gridHeight,
        template,
        false,
        at,
        decodingContext,
      );
    }
  }
  // 6.6.5.2 Rendering the patterns.
  for (var mg = 0; mg < gridHeight; mg++) {
    for (var ng = 0; ng < gridWidth; ng++) {
      var bit = 0;
      var patternIndex = 0;
      for (var j = bitsPerValue - 1; j >= 0; j--) {
        bit ^= grayScaleBitPlanes[j]![mg][ng]; // Gray decoding
        patternIndex |= bit << j;
      }
      final patternBitmap = patterns[patternIndex];
      // JS `>>` runs on int32, so the uint32 grid offsets wrap
      // negative exactly as pdf.js's do before the shift.
      final x = (gridOffsetX + mg * gridVectorY + ng * gridVectorX).toSigned(32) >> 8;
      final y = (gridOffsetY + mg * gridVectorX - ng * gridVectorY).toSigned(32) >> 8;
      // Draw patternBitmap at (x, y).
      if (x >= 0 &&
          x + patternWidth <= regionWidth &&
          y >= 0 &&
          y + patternHeight <= regionHeight) {
        for (var i = 0; i < patternHeight; i++) {
          final regionRow = regionBitmap[y + i];
          final patternRow = patternBitmap[i];
          for (var j = 0; j < patternWidth; j++) {
            regionRow[x + j] |= patternRow[j];
          }
        }
      } else {
        for (var i = 0; i < patternHeight; i++) {
          final regionY = y + i;
          if (regionY < 0 || regionY >= regionHeight) {
            continue;
          }
          final regionRow = regionBitmap[regionY];
          final patternRow = patternBitmap[i];
          for (var j = 0; j < patternWidth; j++) {
            final regionX = x + j;
            if (regionX >= 0 && regionX < regionWidth) {
              regionRow[regionX] |= patternRow[j];
            }
          }
        }
      }
    }
  }
  return regionBitmap;
}
