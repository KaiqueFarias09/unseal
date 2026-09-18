/// JBIG2 (ITU-T T.88) image decoding for PDF's JBIG2Decode filter.
///
/// Ported from pdf.js v3.11.174 `src/core/jbig2.js` (`Jbig2Image`,
/// `SimpleSegmentVisitor`, `processSegment` and `readSegments`),
/// Apache-2.0; parity comments point at the mirrored
/// functions. Companion files hold the shared plumbing:
/// `pdf_jbig2_arithmetic.dart` (MQ), `pdf_jbig2_mmr.dart` (Group 4),
/// `pdf_jbig2_segment.dart` (headers + Annex A integers),
/// `pdf_jbig2_huffman.dart` (Annex B) and
/// `pdf_jbig2_region.dart` (the region decoders).
library;

import 'dart:typed_data';

import '../../exceptions/pdf_exception.dart';
import 'huffman_decoder.dart';
import 'region_decoder.dart';
import 'segment_decoder.dart';

/// Decodes a JBIG2Decode payload (ITU-T T.88, the embedded
/// segment format PDFs use — no file header) into packed 1-bit
/// rows: most significant bit first, in the PDF's default `/Decode
/// [0 1]` convention (0 = black, 1 = white), rows padded to whole
/// bytes — the input contract documented on `PdfBitmap`
/// (image/pdf_bitmap.dart).
///
/// [globals] carries the resolved bytes of the `/JBIG2Globals`
/// stream (retained symbol and pattern dictionaries shared across
/// pages) when the image references one.
///
/// Ground truth: pdf.js v3.11.174 `src/core/jbig2.js`
/// (`Jbig2Image`) plus the color inversion `jbig2_stream.js` applies
/// to its output. Port with parity comments pointing at it.
// pdf.js jbig2_stream.js readBlock: the globals chunk is decoded
// first, then the image chunk, through one shared visitor; the block
// ends by inverting every byte because JBIG2 encodes black as 1 while
// the PDF image model wants 0 = black.
Uint8List decodeJbig2(final Uint8List data, {final Uint8List? globals}) {
  final chunks = <_Jbig2Chunk>[
    if (globals != null) _Jbig2Chunk(globals, 0, globals.length),
    _Jbig2Chunk(data, 0, data.length),
  ];
  final buffer = _Jbig2Image().parseChunks(chunks);
  if (buffer == null) {
    // No PageInformation segment: nothing was ever drawn.
    throw const PdfException('JBIG2 error: no page information segment.');
  }
  for (var i = 0; i < buffer.length; i++) {
    buffer[i] ^= 0xFF;
  }

  return buffer;
}

/// One byte window to decode, pdf.js `{ data, start, end }`.
// pdf.js jbig2.js parseJbig2Chunks chunk shape
final class _Jbig2Chunk {
  /// Creates the chunk window.
  const _Jbig2Chunk(this.data, this.start, this.end);

  /// The whole payload bytes.
  final Uint8List data;

  /// The window start.
  final int start;

  /// The window end.
  final int end;
}

/// The segment decoder facade, pdf.js `Jbig2Image`.
// pdf.js jbig2.js Jbig2Image
final class _Jbig2Image {
  final _Jbig2SegmentVisitor _visitor = _Jbig2SegmentVisitor();

  /// Decodes the chunk sequence into the packed page buffer
  /// (`parseChunks` in pdf.js).
  // pdf.js jbig2.js Jbig2Image.parseChunks
  Uint8List? parseChunks(final List<_Jbig2Chunk> chunks) {
    for (final chunk in chunks) {
      final segments = _readSegments(false, chunk.data, chunk.start, chunk.end);
      for (final segment in segments) {
        _processSegment(segment, _visitor);
      }
    }

    return _visitor.buffer;
  }
}

/// A parsed segment: its header plus the data window.
// pdf.js jbig2.js readSegments segment object
final class _Jbig2Segment {
  _Jbig2Segment(this.header, this.data, this.start, this.end);

  final Jbig2SegmentHeader header;
  final Uint8List data;
  int start;
  int end;
}

/// Reads the segment sequence of one chunk
/// (`readSegments` in pdf.js). The standalone format's
/// random-access organization is only reachable from `parseJbig2`,
/// so [randomAccess] arrives pre-resolved.
// pdf.js jbig2.js readSegments
List<_Jbig2Segment> _readSegments(
  final bool randomAccess,
  final Uint8List data,
  final int start,
  final int end,
) {
  final segments = <_Jbig2Segment>[];
  var position = start;
  while (position < end) {
    final segmentHeader = readJbig2SegmentHeader(data, position);
    position = segmentHeader.headerEnd;
    final segment = _Jbig2Segment(segmentHeader, data, 0, 0);
    if (!randomAccess) {
      segment.start = position;
      position += segmentHeader.length;
      segment.end = position;
    }
    segments.add(segment);
    if (segmentHeader.type == 51) {
      break; // end of file is found
    }
  }
  if (randomAccess) {
    for (final segment in segments) {
      segment.start = position;
      position += segment.header.length;
      segment.end = position;
    }
  }

  return segments;
}

/// Decodes one segment and dispatches it on the visitor
/// (`processSegment` in pdf.js).
// pdf.js jbig2.js processSegment
void _processSegment(final _Jbig2Segment segment, final _Jbig2SegmentVisitor visitor) {
  final header = segment.header;
  switch (header.type) {
    case 0:
      _processSymbolDictionary(segment, visitor);

      return;
    case 6:
    case 7:
      _processTextRegion(segment, visitor);

      return;
    case 16:
      _processPatternDictionary(segment, visitor);

      return;
    case 22:
    case 23:
      _processHalftoneRegion(segment, visitor);

      return;
    case 38:
    case 39:
      _processGenericRegion(segment, visitor);

      return;
    case 48:
      _processPageInformation(segment, visitor);

      return;
    case 49:
    case 50:
    case 51:
    case 62:
      return;
    case 53:
      visitor.onTables(header.number, segment.data, segment.start, segment.end);

      return;
    default:
      throw PdfException(
        'JBIG2 error: segment type ${header.typeName}(${header.type}) is not implemented.',
      );
  }
}

void _processSymbolDictionary(final _Jbig2Segment segment, final _Jbig2SegmentVisitor visitor) {
  final header = segment.header;
  final data = segment.data;
  final end = segment.end;
  var position = segment.start;

  // 7.4.2 Symbol dictionary segment syntax
  final dictionaryFlags = jbig2ReadUint16(data, position); // 7.4.2.1.1
  final huffman = dictionaryFlags & 1 != 0;
  final refinement = dictionaryFlags & 2 != 0;
  final huffmanDhSelector = (dictionaryFlags >> 2) & 3;
  final huffmanDwSelector = (dictionaryFlags >> 4) & 3;
  final bitmapSizeSelector = (dictionaryFlags >> 6) & 1;
  final aggregationInstancesSelector = (dictionaryFlags >> 7) & 1;
  final template = (dictionaryFlags >> 10) & 3;
  final refinementTemplate = (dictionaryFlags >> 12) & 1;
  position += 2;
  var at = const <Point>[];
  if (!huffman) {
    final atLength = template == 0 ? 4 : 1;
    at = <Point>[
      for (var i = 0; i < atLength; i++)
        Point(jbig2ReadInt8(data, position + i * 2), jbig2ReadInt8(data, position + i * 2 + 1)),
    ];
    position += atLength * 2;
  }
  var refinementAt = const <Point>[];
  if (refinement && refinementTemplate == 0) {
    refinementAt = <Point>[
      Point(jbig2ReadInt8(data, position), jbig2ReadInt8(data, position + 1)),
      Point(jbig2ReadInt8(data, position + 2), jbig2ReadInt8(data, position + 3)),
    ];
    position += 4;
  }
  final numberOfExportedSymbols = jbig2ReadUint32(data, position);
  position += 4;
  final numberOfNewSymbols = jbig2ReadUint32(data, position);
  position += 4;
  visitor.onSymbolDictionary(
    huffman: huffman,
    refinement: refinement,
    huffmanDhSelector: huffmanDhSelector,
    huffmanDwSelector: huffmanDwSelector,
    bitmapSizeSelector: bitmapSizeSelector,
    aggregationInstancesSelector: aggregationInstancesSelector,
    template: template,
    at: at,
    refinementTemplate: refinementTemplate,
    refinementAt: refinementAt,
    numberOfExportedSymbols: numberOfExportedSymbols,
    numberOfNewSymbols: numberOfNewSymbols,
    currentSegment: header.number,
    referredSegments: header.referredTo,
    data: data,
    start: position,
    end: end,
  );
}

void _processTextRegion(final _Jbig2Segment segment, final _Jbig2SegmentVisitor visitor) {
  final header = segment.header;
  final data = segment.data;
  final end = segment.end;
  var position = segment.start;

  final info = readJbig2RegionSegmentInformation(data, position);
  position += jbig2RegionSegmentInformationFieldLength;
  final textRegionSegmentFlags = jbig2ReadUint16(data, position);
  position += 2;
  final huffman = textRegionSegmentFlags & 1 != 0;
  final refinement = textRegionSegmentFlags & 2 != 0;
  final logStripSize = (textRegionSegmentFlags >> 2) & 3;
  final referenceCorner = (textRegionSegmentFlags >> 4) & 3;
  final transposed = textRegionSegmentFlags & 64 != 0;
  final combinationOperator = (textRegionSegmentFlags >> 7) & 3;
  final defaultPixelValue = (textRegionSegmentFlags >> 9) & 1;
  final dsOffset = (textRegionSegmentFlags << 17) >> 27;
  final refinementTemplate = (textRegionSegmentFlags >> 15) & 1;
  var huffmanFs = 0, huffmanDs = 0, huffmanDt = 0;
  if (huffman) {
    final textRegionHuffmanFlags = jbig2ReadUint16(data, position);
    position += 2;
    huffmanFs = textRegionHuffmanFlags & 3;
    huffmanDs = (textRegionHuffmanFlags >> 2) & 3;
    huffmanDt = (textRegionHuffmanFlags >> 4) & 3;
  }
  var refinementAt = const <Point>[];
  if (refinement && refinementTemplate == 0) {
    refinementAt = <Point>[
      Point(jbig2ReadInt8(data, position), jbig2ReadInt8(data, position + 1)),
      Point(jbig2ReadInt8(data, position + 2), jbig2ReadInt8(data, position + 3)),
    ];
    position += 4;
  }
  final numberOfSymbolInstances = jbig2ReadUint32(data, position);
  position += 4;
  visitor.onImmediateTextRegion(
    info: info,
    huffman: huffman,
    refinement: refinement,
    logStripSize: logStripSize,
    referenceCorner: referenceCorner,
    transposed: transposed,
    combinationOperator: combinationOperator,
    defaultPixelValue: defaultPixelValue,
    dsOffset: dsOffset,
    refinementTemplate: refinementTemplate,
    refinementAt: refinementAt,
    huffmanFs: huffmanFs,
    huffmanDs: huffmanDs,
    huffmanDt: huffmanDt,
    numberOfSymbolInstances: numberOfSymbolInstances,
    referredSegments: header.referredTo,
    data: data,
    start: position,
    end: end,
  );
}

void _processPatternDictionary(final _Jbig2Segment segment, final _Jbig2SegmentVisitor visitor) {
  final header = segment.header;
  final data = segment.data;
  var position = segment.start;

  // 7.4.4 Pattern dictionary segment syntax
  final patternDictionaryFlags = data[position++];
  final mmr = patternDictionaryFlags & 1 != 0;
  final template = (patternDictionaryFlags >> 1) & 3;
  final patternWidth = data[position++];
  final patternHeight = data[position++];
  final maxPatternIndex = jbig2ReadUint32(data, position);
  visitor.onPatternDictionary(
    mmr: mmr,
    template: template,
    patternWidth: patternWidth,
    patternHeight: patternHeight,
    maxPatternIndex: maxPatternIndex,
    currentSegment: header.number,
    data: data,
    start: position,
    end: segment.end,
  );
}

void _processHalftoneRegion(final _Jbig2Segment segment, final _Jbig2SegmentVisitor visitor) {
  final header = segment.header;
  final data = segment.data;
  final end = segment.end;
  var position = segment.start;
  final info = readJbig2RegionSegmentInformation(data, position);
  position += jbig2RegionSegmentInformationFieldLength;
  final halftoneRegionFlags = data[position++];
  final mmr = halftoneRegionFlags & 1 != 0;
  final template = (halftoneRegionFlags >> 1) & 3;
  final enableSkip = halftoneRegionFlags & 8 != 0;
  final combinationOperator = (halftoneRegionFlags >> 4) & 7;
  final defaultPixelValue = (halftoneRegionFlags >> 7) & 1;
  final gridWidth = jbig2ReadUint32(data, position);
  position += 4;
  final gridHeight = jbig2ReadUint32(data, position);
  position += 4;
  final gridOffsetX = jbig2ReadUint32(data, position);
  position += 4;
  final gridOffsetY = jbig2ReadUint32(data, position);
  position += 4;
  final gridVectorX = jbig2ReadUint16(data, position);
  position += 2;
  final gridVectorY = jbig2ReadUint16(data, position);
  position += 2;
  visitor.onImmediateHalftoneRegion(
    info: info,
    mmr: mmr,
    template: template,
    enableSkip: enableSkip,
    combinationOperator: combinationOperator,
    defaultPixelValue: defaultPixelValue,
    gridWidth: gridWidth,
    gridHeight: gridHeight,
    gridOffsetX: gridOffsetX,
    gridOffsetY: gridOffsetY,
    gridVectorX: gridVectorX,
    gridVectorY: gridVectorY,
    referredSegments: header.referredTo,
    data: data,
    start: position,
    end: end,
  );
}

void _processGenericRegion(final _Jbig2Segment segment, final _Jbig2SegmentVisitor visitor) {
  final data = segment.data;
  var position = segment.start;
  final info = readJbig2RegionSegmentInformation(data, position);
  position += jbig2RegionSegmentInformationFieldLength;
  final genericRegionSegmentFlags = data[position++];
  final mmr = genericRegionSegmentFlags & 1 != 0;
  final template = (genericRegionSegmentFlags >> 1) & 3;
  final prediction = genericRegionSegmentFlags & 8 != 0;
  var at = const <Point>[];
  if (!mmr) {
    final atLength = template == 0 ? 4 : 1;
    at = <Point>[
      for (var i = 0; i < atLength; i++)
        Point(jbig2ReadInt8(data, position + i * 2), jbig2ReadInt8(data, position + i * 2 + 1)),
    ];
    position += atLength * 2;
  }
  visitor.onImmediateGenericRegion(
    info: info,
    mmr: mmr,
    template: template,
    prediction: prediction,
    at: at,
    data: data,
    start: position,
    end: segment.end,
  );
}

void _processPageInformation(final _Jbig2Segment segment, final _Jbig2SegmentVisitor visitor) {
  final data = segment.data;
  final position = segment.start;
  visitor.onPageInformation(
    width: jbig2ReadUint32(data, position),
    height: jbig2ReadUint32(data, position + 4),
    defaultPixelValue: (data[position + 16] >> 2) & 1,
    combinationOperator: (data[position + 16] >> 3) & 3,
    combinationOperatorOverride: data[position + 16] & 64 != 0,
  );
}

/// The segment sink, pdf.js `SimpleSegmentVisitor`: accumulates the
/// page buffer, the retained symbol/pattern dictionaries and the
/// custom Huffman tables across the chunks of one image.
// pdf.js jbig2.js SimpleSegmentVisitor
final class _Jbig2SegmentVisitor {
  int? _pageWidth;
  int _pageCombinationOperator = 0;
  bool _combinationOperatorOverride = false;

  /// The packed page buffer once PageInformation arrived.
  Uint8List? buffer;

  /// Retained symbol dictionaries keyed by segment number
  /// (`this.symbols` in pdf.js).
  final Map<int, List<List<Uint8List>>> _symbols = <int, List<List<Uint8List>>>{};

  /// Retained pattern dictionaries keyed by segment number
  /// (`this.patterns` in pdf.js).
  final Map<int, List<List<Uint8List>>> _patterns = <int, List<List<Uint8List>>>{};

  /// Custom Huffman tables keyed by segment number
  /// (`this.customTables` in pdf.js).
  final Map<int, Jbig2HuffmanTable> _customTables = <int, Jbig2HuffmanTable>{};

  /// Records the page geometry and allocates the buffer
  /// (`onPageInformation` in pdf.js).
  // pdf.js jbig2.js SimpleSegmentVisitor.onPageInformation
  void onPageInformation({
    required final int width,
    required final int height,
    required final int defaultPixelValue,
    required final int combinationOperator,
    required final bool combinationOperatorOverride,
  }) {
    _pageWidth = width;
    _pageCombinationOperator = combinationOperator;
    _combinationOperatorOverride = combinationOperatorOverride;
    final rowSize = (width + 7) >> 3;
    // Corrupt headers declare absurd page sizes; cap the page buffer
    // like every other JBIG2 allocation.
    if (width < 0 ||
        height < 0 ||
        width > 0x10000000 ||
        height > 0x10000000 ||
        rowSize * height > 256 * 1024 * 1024) {
      throw PdfException('JBIG2 error: page ${width}x$height exceeds the allocation budget.');
    }

    final buffer = Uint8List(rowSize * height);
    // The contents of ArrayBuffers are initialized to 0.
    // Fill the buffer with 0xFF only if info.defaultPixelValue is set
    if (defaultPixelValue != 0) {
      buffer.fillRange(0, buffer.length, 0xff);
    }
    this.buffer = buffer;
  }

  /// Composites a decoded region bitmap onto the page buffer
  /// (`drawBitmap` in pdf.js).
  // pdf.js jbig2.js SimpleSegmentVisitor.drawBitmap
  void _drawBitmap(final Jbig2RegionSegmentInformation regionInfo, final List<Uint8List> bitmap) {
    for (var ri = 0; ri < bitmap.length; ri++) {}

    final width = regionInfo.width;
    final height = regionInfo.height;
    final rowSize = (_pageWidth! + 7) >> 3;
    final combinationOperator = _combinationOperatorOverride
        ? regionInfo.combinationOperator
        : _pageCombinationOperator;
    final buffer = this.buffer!;
    const mask0 = 128;
    var offset0 = regionInfo.y * rowSize + (regionInfo.x >> 3);
    final shift0 = regionInfo.x & 7;
    switch (combinationOperator) {
      case 0: // OR
        for (var i = 0; i < height; i++) {
          var mask = mask0 >> shift0;
          var offset = offset0;
          final bitmapRow = bitmap[i];
          for (var j = 0; j < width; j++) {
            // Writes past the page buffer are dropped, as the JS
            // typed-array stores pdf.js relies on are.
            if (bitmapRow[j] != 0 && offset < buffer.length) {
              buffer[offset] |= mask;
            }
            mask >>= 1;
            if (mask == 0) {
              mask = 128;
              offset++;
            }
          }
          offset0 += rowSize;
        }
      case 2: // XOR
        for (var i = 0; i < height; i++) {
          var mask = mask0 >> shift0;
          var offset = offset0;
          final bitmapRow = bitmap[i];
          for (var j = 0; j < width; j++) {
            if (bitmapRow[j] != 0 && offset < buffer.length) {
              buffer[offset] ^= mask;
            }
            mask >>= 1;
            if (mask == 0) {
              mask = 128;
              offset++;
            }
          }
          offset0 += rowSize;
        }
      default:
        throw PdfException('JBIG2 error: operator $combinationOperator is not supported.');
    }
  }

  /// The combined input symbols of the referred-to dictionaries.
  List<List<Uint8List>> _referredSymbols(final List<int> referredSegments) {
    final inputSymbols = <List<Uint8List>>[];
    for (final referredSegment in referredSegments) {
      final referredSymbols = _symbols[referredSegment];
      // referredSymbols is undefined when we have a reference to a Tables
      // segment instead of a SymbolDictionary.
      if (referredSymbols != null) {
        inputSymbols.addAll(referredSymbols);
      }
    }

    return inputSymbols;
  }

  /// Decodes a SymbolDictionary segment
  /// (`onSymbolDictionary` in pdf.js).
  // pdf.js jbig2.js SimpleSegmentVisitor.onSymbolDictionary
  // ignore: avoid_positional_boolean_parameters
  void onSymbolDictionary({
    required final bool huffman,
    required final bool refinement,
    required final int huffmanDhSelector,
    required final int huffmanDwSelector,
    required final int bitmapSizeSelector,
    required final int aggregationInstancesSelector,
    required final int template,
    required final List<Point> at,
    required final int refinementTemplate,
    required final List<Point> refinementAt,
    required final int numberOfExportedSymbols,
    required final int numberOfNewSymbols,
    required final int currentSegment,
    required final List<int> referredSegments,
    required final Uint8List data,
    required final int start,
    required final int end,
  }) {
    Jbig2SymbolDictionaryHuffmanTables? huffmanTables;
    Jbig2BitReader? huffmanInput;
    if (huffman) {
      huffmanTables = jbig2GetSymbolDictionaryHuffmanTables(
        huffmanDhSelector: huffmanDhSelector,
        huffmanDwSelector: huffmanDwSelector,
        bitmapSizeSelector: bitmapSizeSelector,
        aggregationInstancesSelector: aggregationInstancesSelector,
        referredTo: referredSegments,
        customTables: _customTables,
      );
      huffmanInput = Jbig2BitReader(data, start, end);
    }

    // Combines exported symbols from all referred segments
    final inputSymbols = _referredSymbols(referredSegments);

    final decodingContext = Jbig2DecodingContext(data, start, end);
    _symbols[currentSegment] = jbig2DecodeSymbolDictionary(
      inputSymbols,
      numberOfNewSymbols,
      numberOfExportedSymbols,
      huffmanTables,
      template,
      at,
      refinementTemplate,
      refinementAt,
      decodingContext,
      huffmanInput,
      isHuffmanEnabled: huffman,
      isRefinementEnabled: refinement,
    );
  }

  /// Decodes a text region segment (`onImmediateTextRegion` /
  /// `onImmediateLosslessTextRegion` in pdf.js — the lossless
  /// variant shares this body there too).
  // pdf.js jbig2.js SimpleSegmentVisitor.onImmediateTextRegion
  void onImmediateTextRegion({
    required final Jbig2RegionSegmentInformation info,
    required final bool huffman,
    required final bool refinement,
    required final int logStripSize,
    required final int referenceCorner,
    required final bool transposed,
    required final int combinationOperator,
    required final int defaultPixelValue,
    required final int dsOffset,
    required final int refinementTemplate,
    required final List<Point> refinementAt,
    required final int huffmanFs,
    required final int huffmanDs,
    required final int huffmanDt,
    required final int numberOfSymbolInstances,
    required final List<int> referredSegments,
    required final Uint8List data,
    required final int start,
    required final int end,
  }) {
    // Combines exported symbols from all referred segments
    final inputSymbols = _referredSymbols(referredSegments);
    final symbolCodeLength = jbig2Log2(inputSymbols.length);
    Jbig2TextRegionHuffmanTables? huffmanTables;
    Jbig2BitReader? huffmanInput;
    if (huffman) {
      huffmanInput = Jbig2BitReader(data, start, end);
      huffmanTables = jbig2GetTextRegionHuffmanTables(
        huffmanFs: huffmanFs,
        huffmanDs: huffmanDs,
        huffmanDt: huffmanDt,
        refinement: refinement,
        referredTo: referredSegments,
        customTables: _customTables,
        numberOfSymbols: inputSymbols.length,
        reader: huffmanInput,
      );
    }

    final decodingContext = Jbig2DecodingContext(data, start, end);
    final bitmap = jbig2DecodeTextRegion(
      info.width,
      info.height,
      defaultPixelValue,
      numberOfSymbolInstances,
      1 << logStripSize,
      inputSymbols,
      symbolCodeLength,
      transposed ? 1 : 0,
      dsOffset,
      referenceCorner,
      combinationOperator,
      huffmanTables,
      refinementTemplate,
      refinementAt,
      decodingContext,
      logStripSize,
      huffmanInput,
      isHuffmanEnabled: huffman,
      isRefinementEnabled: refinement,
    );
    _drawBitmap(info, bitmap);
  }

  /// Decodes a PatternDictionary segment
  /// (`onPatternDictionary` in pdf.js).
  // pdf.js jbig2.js SimpleSegmentVisitor.onPatternDictionary
  void onPatternDictionary({
    required final bool mmr,
    required final int template,
    required final int patternWidth,
    required final int patternHeight,
    required final int maxPatternIndex,
    required final int currentSegment,
    required final Uint8List data,
    required final int start,
    required final int end,
  }) {
    final decodingContext = Jbig2DecodingContext(data, start, end);
    _patterns[currentSegment] = jbig2DecodePatternDictionary(
      patternWidth,
      patternHeight,
      maxPatternIndex,
      template,
      decodingContext,
      isMmr: mmr,
    );
  }

  /// Decodes a halftone region segment
  /// (`onImmediateHalftoneRegion` /
  /// `onImmediateLosslessHalftoneRegion` in pdf.js).
  // pdf.js jbig2.js SimpleSegmentVisitor.onImmediateHalftoneRegion
  void onImmediateHalftoneRegion({
    required final Jbig2RegionSegmentInformation info,
    required final bool mmr,
    required final int template,
    required final bool enableSkip,
    required final int combinationOperator,
    required final int defaultPixelValue,
    required final int gridWidth,
    required final int gridHeight,
    required final int gridOffsetX,
    required final int gridOffsetY,
    required final int gridVectorX,
    required final int gridVectorY,
    required final List<int> referredSegments,
    required final Uint8List data,
    required final int start,
    required final int end,
  }) {
    // HalftoneRegion refers to exactly one PatternDictionary.
    final patterns = _patterns[referredSegments[0]];
    if (patterns == null) {
      throw const PdfException('JBIG2 error: halftone region without a pattern dictionary.');
    }

    final decodingContext = Jbig2DecodingContext(data, start, end);
    final bitmap = jbig2DecodeHalftoneRegion(
      patterns,
      template,
      info.width,
      info.height,
      defaultPixelValue,
      combinationOperator,
      gridWidth,
      gridHeight,
      gridOffsetX,
      gridOffsetY,
      gridVectorX,
      gridVectorY,
      decodingContext,
      isMmr: mmr,
      isSkipEnabled: enableSkip,
    );
    _drawBitmap(info, bitmap);
  }

  /// Decodes a generic region segment (`onImmediateGenericRegion` /
  /// `onImmediateLosslessGenericRegion` in pdf.js).
  // pdf.js jbig2.js SimpleSegmentVisitor.onImmediateGenericRegion
  void onImmediateGenericRegion({
    required final Jbig2RegionSegmentInformation info,
    required final bool mmr,
    required final int template,
    required final bool prediction,
    required final List<Point> at,
    required final Uint8List data,
    required final int start,
    required final int end,
  }) {
    final decodingContext = Jbig2DecodingContext(data, start, end);
    final bitmap = jbig2DecodeBitmap(
      info.width,
      info.height,
      template,
      at,
      decodingContext,
      isMmr: mmr,
      isPredictionEnabled: prediction,
    );
    _drawBitmap(info, bitmap);
  }

  /// Decodes a custom Huffman Tables segment
  /// (`onTables` in pdf.js).
  // pdf.js jbig2.js SimpleSegmentVisitor.onTables
  void onTables(final int currentSegment, final Uint8List data, final int start, final int end) {
    _customTables[currentSegment] = jbig2DecodeTablesSegment(data, start, end);
  }
}
