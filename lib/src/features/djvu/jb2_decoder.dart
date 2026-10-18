import 'dart:typed_data';

import 'djvu_decode_budget.dart';
import 'djvu_exception.dart';
import 'fgbz_decoder.dart';
import 'zp_decoder.dart';

const _maxJb2PagePixels = 16 * 1000 * 1000;
const _maxJb2SymbolPixels = 4 * 1000 * 1000;
const _maxJb2DecodedSymbolPixels = 64 * 1000 * 1000;
const _maxJb2BlitPixels = 64 * 1000 * 1000;
const _maxJb2DictionaryPixels = 16 * 1000 * 1000;
const _maxJb2Records = 65536;
const _maxJb2ContextNodes = 1024 * 1024;
const _maxJb2CommentBytes = 64 * 1024;
const _maxSyntheticBytes = 16;

/// Work cap for the FGbz color pass's group scan. Real pages stay orders of
/// magnitude below it (their passes equal their palette sizes); the cap turns
/// a hostile left-regressing blit sequence into a typed refusal.
const _maxJb2ColorScanSteps = 64 * 1000 * 1000;

/// Conservative page-local placement, chain and color-pass bookkeeping cap.
/// The record limit bounds placements to 65536; shared symbol pixels have
/// their separate ledger and the JB2 decoder bounds local symbol storage.
const djvuFgbzPlacementBudgetBytes = 65536 * 128;

/// The bilevel mask produced by the supported subset of a JB2 image stream.
final class DjvuJb2Mask {
  /// Creates a bilevel page mask.
  const DjvuJb2Mask({required this.width, required this.height, required this.pixels});

  /// Page width in pixels.
  final int width;

  /// Page height in pixels.
  final int height;

  /// One byte per pixel in top-to-bottom order. One means black ink.
  final Uint8List pixels;
}

/// One JB2 blit's native placement: bottom-left pixel coordinates in the
/// spec's bottom-origin space, plus the blitted symbol.
final class DjvuJb2BlitPlacement {
  /// Creates one blit placement from its decoded parts.
  const DjvuJb2BlitPlacement({
    required this.left,
    required this.bottom,
    required this.symbol,
    required this.shapeNumber,
  });

  /// Left edge of the symbol, in pixels.
  final int left;

  /// Bottom edge of the symbol, in the spec's bottom-origin coordinates.
  final int bottom;

  /// Native combined dictionary/image shape number.
  final int shapeNumber;

  /// The blitted symbol bitmap, cropped to its ink bounds.
  final DjvuJb2Symbol symbol;
}

/// A page mask whose ink pixels carry one FGbz palette index each.
///
/// [colorMap] holds one 16-bit value per pixel in top-to-bottom order: zero
/// is paper, and `index + 1` means the ink pixel takes the FGbz palette
/// entry at that zero-based index. This single page-sized map is the color
/// state — no per-color or per-blit buffer exists at any point.
final class DjvuJb2ColorizedMask {
  /// Creates a colorized page mask around its decoded map and palette.
  const DjvuJb2ColorizedMask({
    required this.width,
    required this.height,
    required this.colorMap,
    required this.palette,
  });

  /// Page width in pixels.
  final int width;

  /// Page height in pixels.
  final int height;

  /// One value per pixel; zero is paper, otherwise palette index plus one.
  final Uint16List colorMap;

  /// The FGbz palette the color map indexes into.
  final DjvuFgbzPalette palette;
}

/// Cumulative cap on retained shared-dictionary symbol pixels across one
/// document. Page-level JB2 limits already bound each stream; this ledger
/// keeps a bundled document's many Djbz chunks from multiplying those caps.
const djvuMaxSharedDictionaryPixelsPerBook = 64 * 1000 * 1000;

/// Tracks retained shared-dictionary symbol pixels across one document.
///
/// Dictionary decoding charges every symbol bitmap before it is allocated.
final class DjvuSharedDictionaryLedger {
  var _pixels = 0;

  /// Reserves [pixels] of retained dictionary symbol bitmap.
  void charge(final int pixels) {
    if (pixels < 0 || pixels > djvuMaxSharedDictionaryPixelsPerBook - _pixels) {
      throw const DjvuException('DjVu shared dictionaries exceed the 64-megapixel document limit.');
    }
    _pixels += pixels;
  }
}

/// A decoded JB2 shared symbol dictionary (a Djbz chunk's symbol list).
///
/// Pages decode their Sjbz stream against this list; symbols a page adds stay
/// page-local and never flow back into the shared dictionary.
final class DjvuJb2SharedDictionary {
  /// Creates a shared dictionary around already-decoded symbols.
  const DjvuJb2SharedDictionary(this.symbols);

  /// The dictionary's accumulated symbols in decode order.
  final List<DjvuJb2Symbol> symbols;
}

/// Decodes a Djbz shared-dictionary JB2 stream into its accumulated symbols.
///
/// Dictionary streams carry symbol-add records only: direct additions,
/// matched refinements, comments, and the end record. A dictionary that
/// itself inherits another dictionary (record 9 with a nonzero count) is not
/// supported. Every symbol bitmap is charged to [ledger] before allocation.
DjvuJb2SharedDictionary decodeDjvuJb2Dictionary(
  final Uint8List encoded, {
  required final DjvuSharedDictionaryLedger ledger,
}) {
  final zp = DjvuZpDecoder(encoded, truncatedMessage: 'Truncated DjVu JB2 dictionary stream.');
  final nodeBudget = _ContextNodeBudget();
  final recordType = _NumberContext(nodeBudget);
  final imageSize = _NumberContext(nodeBudget);
  final symbolWidth = _NumberContext(nodeBudget);
  final symbolHeight = _NumberContext(nodeBudget);
  final inheritedDictionarySize = _NumberContext(nodeBudget);
  final symbolIndex = _NumberContext(nodeBudget);
  final symbolWidthDifference = _NumberContext(nodeBudget);
  final symbolHeightDifference = _NumberContext(nodeBudget);
  final commentLength = _NumberContext(nodeBudget);
  final commentByte = _NumberContext(nodeBudget);
  final directContexts = Uint8List(1024);
  final refinementContexts = Uint8List(2048);

  var firstRecord = _decodeNumber(zp, recordType, 0, 11);
  if (firstRecord == 9) {
    final inheritedCount = _decodeNumber(zp, inheritedDictionarySize, 0, 262142);
    if (inheritedCount != 0) {
      throw const DjvuUnsupportedCodecException(
        'DjVu shared dictionaries that inherit other dictionaries are not supported.',
      );
    }
    firstRecord = _decodeNumber(zp, recordType, 0, 11);
  }
  if (firstRecord != 0) {
    throw const DjvuException('Invalid DjVu JB2 dictionary start record.');
  }
  // Dictionary streams still declare the image dimensions and reserved flag;
  // both are decoded to keep the arithmetic stream aligned and are unused.
  _decodeNumber(zp, imageSize, 0, 262142);
  _decodeNumber(zp, imageSize, 0, 262142);
  if (zp.decodeBit(0).bit) {
    throw const DjvuException('Invalid reserved flag in DjVu JB2 dictionary header.');
  }

  final symbols = <DjvuJb2Symbol>[];
  var storedDictionaryPixels = 0;
  var decodedSymbolPixels = 0;
  var records = 0;
  var ended = false;
  while (!ended) {
    if (zp.syntheticBytes > _maxSyntheticBytes) {
      throw const DjvuException('Truncated DjVu JB2 dictionary stream.');
    }
    if (records >= _maxJb2Records) {
      throw const DjvuException('DjVu JB2 dictionary exceeds the 65536-record limit.');
    }
    records++;
    switch (_decodeNumber(zp, recordType, 0, 11)) {
      case 2:
        final width = _decodeNumber(zp, symbolWidth, 0, 262142);
        final height = _decodeNumber(zp, symbolHeight, 0, 262142);
        final symbol = _chargedDirectBitmap(
          zp,
          directContexts,
          width,
          height,
          decodedSymbolPixels,
          ledger,
        );
        decodedSymbolPixels += symbol.width * symbol.height;
        storedDictionaryPixels = _addStoredSymbol(symbols, symbol, storedDictionaryPixels);
      case 5:
        final reference = _referenceSymbol(symbols, zp, symbolIndex);
        final symbolWidthValue =
            reference.width + _decodeNumber(zp, symbolWidthDifference, -262143, 262142);
        final symbolHeightValue =
            reference.height + _decodeNumber(zp, symbolHeightDifference, -262143, 262142);
        final symbol = _chargedRefinedBitmap(
          zp,
          refinementContexts,
          symbolWidthValue,
          symbolHeightValue,
          reference,
          decodedSymbolPixels,
          ledger,
        );
        decodedSymbolPixels += symbol.width * symbol.height;
        storedDictionaryPixels = _addStoredSymbol(symbols, symbol, storedDictionaryPixels);
      case 9:
      // A mid-stream dictionary requirement is a no-op in a dictionary.
      case 10:
        final length = _decodeNumber(zp, commentLength, 0, 262142);
        if (length > _maxJb2CommentBytes) {
          throw const DjvuException('DjVu JB2 dictionary comment exceeds the 64 KiB limit.');
        }
        for (var index = 0; index < length; index++) {
          _decodeNumber(zp, commentByte, 0, 255);
        }
      case 11:
        ended = true;
      default:
        throw const DjvuException('DjVu JB2 dictionary records cannot place symbols on a page.');
    }
  }
  return DjvuJb2SharedDictionary(symbols);
}

/// Decodes local-symbol JB2 records into a page-sized black-ink mask.
///
/// This accepts direct and matched-refinement records that use the page-local
/// symbol dictionary, plus records that inherit a [DjvuJb2SharedDictionary]
/// shared by the document's Djbz chunk.
DjvuJb2Mask decodeDjvuJb2Mask(
  final Uint8List encoded, {
  required final int expectedWidth,
  required final int expectedHeight,
  final DjvuJb2SharedDictionary? inherited,
}) => decodeDjvuJb2Page(
  encoded,
  expectedWidth: expectedWidth,
  expectedHeight: expectedHeight,
  inherited: inherited,
  collectBlits: false,
).mask;

/// Decodes local-symbol JB2 records into a page color map, applying
/// [colors] to every blit.
///
/// The chunk's color sequence must name exactly the page's blits; the paint
/// order reproduces the native two-layer rendering (`DjVuImage::stencil`):
/// color groups run in first-appearance order and the last pass covering a
/// pixel wins.
DjvuJb2ColorizedMask decodeDjvuJb2ColorizedMask(
  final Uint8List encoded, {
  required final int expectedWidth,
  required final int expectedHeight,
  final DjvuJb2SharedDictionary? inherited,
  required final DjvuFgbzPalette colors,
  final DjvuDecodeBudget? budget,
}) {
  final colorIndices = colors.colorIndices;
  if (colorIndices == null) {
    throw const DjvuException('DjVu FGbz palette carries no per-blit color data.');
  }
  final page = decodeDjvuJb2Page(
    encoded,
    expectedWidth: expectedWidth,
    expectedHeight: expectedHeight,
    inherited: inherited,
    collectBlits: true,
    budget: budget,
  );
  final blits = page.blits!;
  if (blits.length != colorIndices.length) {
    throw DjvuException(
      'DjVu FGbz colors ${colorIndices.length} blits, but the page places ${blits.length}.',
    );
  }
  return DjvuJb2ColorizedMask(
    width: page.width,
    height: page.height,
    colorMap: _paintBlitColors(blits, colorIndices, page.width, page.height),
    palette: colors,
  );
}

/// The full decode of one JB2 page stream: the bilevel mask plus, when
/// `collectBlits` is set, the native placement of every blit in decode
/// order. Ordinary parsing uses the two wrappers above; the comparison
/// tools read the blit list to check FGbz color association against the
/// native blit order.
final class DjvuJb2Page {
  /// Creates a decoded page result.
  const DjvuJb2Page({
    required this.width,
    required this.height,
    required this.mask,
    required this.blits,
  });

  /// Page width in pixels.
  final int width;

  /// Page height in pixels.
  final int height;

  /// The decoded bilevel mask.
  final DjvuJb2Mask mask;

  /// Every blit's placement in decode order, or null when not collected.
  final List<DjvuJb2BlitPlacement>? blits;
}

/// Decodes one JB2 page stream into [DjvuJb2Page].
DjvuJb2Page decodeDjvuJb2Page(
  final Uint8List encoded, {
  required final int expectedWidth,
  required final int expectedHeight,
  final DjvuJb2SharedDictionary? inherited,
  required final bool collectBlits,
  final DjvuDecodeBudget? budget,
}) {
  final zp = DjvuZpDecoder(encoded, truncatedMessage: 'Truncated DjVu JB2 arithmetic stream.');
  final nodeBudget = _ContextNodeBudget(budget);
  final recordType = _NumberContext(nodeBudget);
  final imageSize = _NumberContext(nodeBudget);
  final symbolWidth = _NumberContext(nodeBudget);
  final symbolHeight = _NumberContext(nodeBudget);
  final inheritedDictionarySize = _NumberContext(nodeBudget);
  final symbolIndex = _NumberContext(nodeBudget);
  final symbolWidthDifference = _NumberContext(nodeBudget);
  final symbolHeightDifference = _NumberContext(nodeBudget);
  final absoluteLeft = _NumberContext(nodeBudget);
  final absoluteTop = _NumberContext(nodeBudget);
  final commentLength = _NumberContext(nodeBudget);
  final commentByte = _NumberContext(nodeBudget);
  final coordinates = _CoordinateContexts(nodeBudget);
  final directContexts = Uint8List(1024);
  final refinementContexts = Uint8List(2048);

  var firstRecord = _decodeNumber(zp, recordType, 0, 11);
  var inheritedCount = 0;
  if (firstRecord == 9) {
    inheritedCount = _decodeNumber(zp, inheritedDictionarySize, 0, 262142);
    if (inheritedCount != 0 && inherited == null) {
      throw const DjvuException(
        'DjVu JB2 page requires a shared dictionary that was not provided.',
      );
    }
    if (inheritedCount > (inherited?.symbols.length ?? 0)) {
      throw const DjvuException(
        'DjVu JB2 inherited symbol count exceeds the shared dictionary size.',
      );
    }
    firstRecord = _decodeNumber(zp, recordType, 0, 11);
  }
  if (firstRecord != 0) {
    throw const DjvuException('Invalid DjVu JB2 start-of-image record.');
  }

  var width = _decodeNumber(zp, imageSize, 0, 262142);
  var height = _decodeNumber(zp, imageSize, 0, 262142);
  if (width == 0) width = 200;
  if (height == 0) height = 200;
  if (width != expectedWidth || height != expectedHeight) {
    throw const DjvuException('DjVu JB2 dimensions do not match the page INFO chunk.');
  }
  final pagePixels = width * height;
  if (pagePixels > _maxJb2PagePixels) {
    throw const DjvuException('DjVu JB2 page exceeds the 16-megapixel decode limit.');
  }
  if (zp.decodeBit(0).bit) {
    throw const DjvuException('Invalid reserved flag in DjVu JB2 image header.');
  }

  final page = Uint8List(pagePixels);
  // Native placements of every blit, in decode order, for the FGbz color
  // pass. Null keeps ordinary mask decodes from retaining them.
  final blits = collectBlits ? <DjvuJb2BlitPlacement>[] : null;
  // The combined dictionary is the inherited shared slice followed by the
  // symbols this page adds; match records index across the whole list and
  // page-local additions never flow back into the shared dictionary.
  final symbols = inheritedCount == 0
      ? <DjvuJb2Symbol>[]
      : List<DjvuJb2Symbol>.of(inherited!.symbols.sublist(0, inheritedCount));
  final shapeNumbers = List<int>.generate(inheritedCount, (final i) => i);
  var nextShapeNumber = inheritedCount;
  var storedDictionaryPixels = 0;
  var decodedSymbolPixels = 0;
  var blitPixels = 0;
  final layout = _Jb2Layout(height);
  var records = 0;
  var ended = false;

  while (!ended) {
    if (zp.syntheticBytes > _maxSyntheticBytes) {
      throw const DjvuException('Truncated DjVu JB2 arithmetic stream.');
    }
    if (records >= _maxJb2Records) {
      throw const DjvuException('DjVu JB2 page exceeds the 65536-record limit.');
    }
    records++;
    final type = _decodeNumber(zp, recordType, 0, 11);
    switch (type) {
      case 1:
      case 2:
      case 3:
      case 8:
        final symbol = _decodeDirectSymbol(
          zp,
          directContexts,
          symbolWidth,
          symbolHeight,
          decodedSymbolPixels,
          budget: budget,
        );
        decodedSymbolPixels += symbol.width * symbol.height;
        final shapeNumber = nextShapeNumber++;

        if (type == 1 || type == 3) {
          final (x, y) = _decodeSymbolCoordinates(
            zp,
            coordinates,
            layout,
            symbol.width,
            symbol.height,
          );
          blitPixels += symbol.width * symbol.height;
          if (blitPixels > _maxJb2BlitPixels) {
            throw const DjvuException('DjVu JB2 page exceeds the 64-megapixel blit-work limit.');
          }
          _blit(page, width, height, symbol, x, y);
          blits?.add(
            DjvuJb2BlitPlacement(left: x, bottom: y, symbol: symbol, shapeNumber: shapeNumber),
          );
        } else if (type == 8) {
          final left = _decodeNumber(zp, absoluteLeft, 1, width) - 1;
          final top = _decodeNumber(zp, absoluteTop, 1, height) - symbol.height;
          blitPixels += symbol.width * symbol.height;
          if (blitPixels > _maxJb2BlitPixels) {
            throw const DjvuException('DjVu JB2 page exceeds the 64-megapixel blit-work limit.');
          }
          _blit(page, width, height, symbol, left, top);
          blits?.add(
            DjvuJb2BlitPlacement(left: left, bottom: top, symbol: symbol, shapeNumber: shapeNumber),
          );
        }

        if (type == 1 || type == 2) {
          storedDictionaryPixels = _addStoredSymbol(symbols, symbol, storedDictionaryPixels);
          shapeNumbers.add(shapeNumber);
        }
      case 4:
      case 5:
      case 6:
        final reference = _referenceSymbol(symbols, zp, symbolIndex);
        final symbolWidthValue =
            reference.width + _decodeNumber(zp, symbolWidthDifference, -262143, 262142);
        final symbolHeightValue =
            reference.height + _decodeNumber(zp, symbolHeightDifference, -262143, 262142);
        final symbol = _decodeRefinedSymbol(
          zp,
          refinementContexts,
          symbolWidthValue,
          symbolHeightValue,
          reference,
          decodedSymbolPixels,
          budget: budget,
        );
        decodedSymbolPixels += symbol.width * symbol.height;
        final shapeNumber = nextShapeNumber++;

        if (type == 4 || type == 6) {
          final (x, y) = _decodeSymbolCoordinates(
            zp,
            coordinates,
            layout,
            symbol.width,
            symbol.height,
          );
          blitPixels += symbol.width * symbol.height;
          if (blitPixels > _maxJb2BlitPixels) {
            throw const DjvuException('DjVu JB2 page exceeds the 64-megapixel blit-work limit.');
          }
          _blit(page, width, height, symbol, x, y);
          blits?.add(
            DjvuJb2BlitPlacement(left: x, bottom: y, symbol: symbol, shapeNumber: shapeNumber),
          );
        }

        if (type == 4 || type == 5) {
          storedDictionaryPixels = _addStoredSymbol(symbols, symbol, storedDictionaryPixels);
          shapeNumbers.add(shapeNumber);
        }
      case 7:
        if (symbols.isEmpty) {
          throw const DjvuException('DjVu JB2 copy record references an empty dictionary.');
        }
        final index = _decodeNumber(zp, symbolIndex, 0, symbols.length - 1);
        if (index < 0 || index >= symbols.length) {
          throw const DjvuException('DjVu JB2 copy record references an invalid symbol.');
        }
        final symbol = symbols[index];
        final shapeNumber = shapeNumbers[index];
        final (x, y) = _decodeSymbolCoordinates(
          zp,
          coordinates,
          layout,
          symbol.width,
          symbol.height,
        );
        blitPixels += symbol.width * symbol.height;
        if (blitPixels > _maxJb2BlitPixels) {
          throw const DjvuException('DjVu JB2 page exceeds the 64-megapixel blit-work limit.');
        }
        _blit(page, width, height, symbol, x, y);
        blits?.add(
          DjvuJb2BlitPlacement(left: x, bottom: y, symbol: symbol, shapeNumber: shapeNumber),
        );
      case 9:
        throw const DjvuException(
          'DjVu JB2 page records that reset or inherit a shared dictionary are '
          'only valid at the start of the stream.',
        );
      case 10:
        final length = _decodeNumber(zp, commentLength, 0, 262142);
        if (length > _maxJb2CommentBytes) {
          throw const DjvuException('DjVu JB2 comment exceeds the 64 KiB limit.');
        }
        for (var index = 0; index < length; index++) {
          _decodeNumber(zp, commentByte, 0, 255);
        }
      case 11:
        ended = true;
      default:
        throw DjvuException('Invalid DjVu JB2 record type $type at record $records.');
    }
  }

  return DjvuJb2Page(
    width: width,
    height: height,
    mask: DjvuJb2Mask(width: width, height: height, pixels: page),
    blits: blits,
  );
}

/// Encodes a bilevel mask as a bottom-up, 1-bit BMP for reader display.
Uint8List encodeDjvuJb2Bmp(final DjvuJb2Mask mask) {
  final rowStride = ((mask.width + 31) ~/ 32) * 4;
  final pixelBytes = rowStride * mask.height;
  final pixelOffset = 14 + 40 + 8;
  final output = Uint8List(pixelOffset + pixelBytes);
  final view = ByteData.sublistView(output);
  output[0] = 0x42;
  output[1] = 0x4D;
  view.setUint32(2, output.length, Endian.little);
  view.setUint32(10, pixelOffset, Endian.little);
  view.setUint32(14, 40, Endian.little);
  view.setInt32(18, mask.width, Endian.little);
  view.setInt32(22, mask.height, Endian.little);
  view.setUint16(26, 1, Endian.little);
  view.setUint16(28, 1, Endian.little);
  view.setUint32(34, pixelBytes, Endian.little);
  view.setUint32(46, 2, Endian.little);
  view.setUint32(50, 2, Endian.little);
  // Palette index 0 is black ink; index 1 is white paper.
  output.setRange(58, 62, const <int>[255, 255, 255, 0]);

  for (var bmpRow = 0; bmpRow < mask.height; bmpRow++) {
    final sourceRow = mask.height - 1 - bmpRow;
    final destination = pixelOffset + bmpRow * rowStride;
    output.fillRange(destination, destination + rowStride, 0xFF);
    for (var column = 0; column < mask.width; column++) {
      if (mask.pixels[sourceRow * mask.width + column] != 0) {
        output[destination + column ~/ 8] &= ~(0x80 >> (column & 7));
      }
    }
  }
  return output;
}

DjvuJb2Symbol _decodeDirectSymbol(
  final DjvuZpDecoder zp,
  final Uint8List contexts,
  final _NumberContext widthContext,
  final _NumberContext heightContext,
  final int priorPixels, {
  final DjvuDecodeBudget? budget,
}) {
  final width = _decodeNumber(zp, widthContext, 0, 262142);
  final height = _decodeNumber(zp, heightContext, 0, 262142);
  return _chargedDirectBitmap(zp, contexts, width, height, priorPixels, null, budget: budget);
}

/// Decodes a direct symbol bitmap after its dimensions are known.
///
/// When [ledger] is supplied (shared-dictionary decode), the bitmap's pixels
/// are charged to the document dictionary ledger before allocation.
DjvuJb2Symbol _chargedDirectBitmap(
  final DjvuZpDecoder zp,
  final Uint8List contexts,
  final int width,
  final int height,
  final int priorPixels,
  final DjvuSharedDictionaryLedger? ledger, {
  final DjvuDecodeBudget? budget,
}) {
  final pixelCount = width * height;
  if (width < 0 || height < 0 || pixelCount > _maxJb2SymbolPixels) {
    throw const DjvuException('DjVu JB2 symbol dimensions exceed the 4-megapixel limit.');
  }
  if (priorPixels + pixelCount > _maxJb2DecodedSymbolPixels) {
    throw const DjvuException('DjVu JB2 page exceeds the 64-megapixel symbol-work limit.');
  }
  if (ledger != null) ledger.charge(pixelCount);
  budget?.reserve(pixels: 0, rasterBytes: 2 * pixelCount);

  if (pixelCount == 0) {
    return DjvuJb2Symbol(width: width, height: height, pixels: Uint8List(0));
  }
  final pixels = Uint8List(pixelCount);
  for (var row = 0; row < height; row++) {
    final previous1 = row - 1;
    final previous2 = row - 2;
    final rowStart = row * width;
    for (var column = 0; column < width; column++) {
      if (((rowStart + column) & 1023) == 0 && zp.syntheticBytes > _maxSyntheticBytes) {
        throw const DjvuException('Truncated DjVu JB2 symbol bitmap.');
      }
      final context =
          (_pixel(pixels, width, previous2, column - 1) << 9) |
          (_pixel(pixels, width, previous2, column) << 8) |
          (_pixel(pixels, width, previous2, column + 1) << 7) |
          (_pixel(pixels, width, previous1, column - 2) << 6) |
          (_pixel(pixels, width, previous1, column - 1) << 5) |
          (_pixel(pixels, width, previous1, column) << 4) |
          (_pixel(pixels, width, previous1, column + 1) << 3) |
          (_pixel(pixels, width, previous1, column + 2) << 2) |
          (_pixel(pixels, width, row, column - 2) << 1) |
          _pixel(pixels, width, row, column - 1);
      final decoded = zp.decodeBit(contexts[context]);
      pixels[rowStart + column] = decoded.bit ? 1 : 0;
      contexts[context] = decoded.state;
    }
  }
  return DjvuJb2Symbol(width: width, height: height, pixels: pixels);
}

DjvuJb2Symbol _decodeRefinedSymbol(
  final DjvuZpDecoder zp,
  final Uint8List contexts,
  final int width,
  final int height,
  final DjvuJb2Symbol reference,
  final int priorPixels, {
  final DjvuDecodeBudget? budget,
}) => _chargedRefinedBitmap(
  zp,
  contexts,
  width,
  height,
  reference,
  priorPixels,
  null,
  budget: budget,
);

/// Decodes a refined symbol bitmap after its dimensions are known.
///
/// When [ledger] is supplied (shared-dictionary decode), the bitmap's pixels
/// are charged to the document dictionary ledger before allocation.
DjvuJb2Symbol _chargedRefinedBitmap(
  final DjvuZpDecoder zp,
  final Uint8List contexts,
  final int width,
  final int height,
  final DjvuJb2Symbol reference,
  final int priorPixels,
  final DjvuSharedDictionaryLedger? ledger, {
  final DjvuDecodeBudget? budget,
}) {
  final pixelCount = width * height;
  if (width < 0 || height < 0 || pixelCount > _maxJb2SymbolPixels) {
    throw const DjvuException('DjVu JB2 refinement dimensions exceed the 4-megapixel limit.');
  }
  if (priorPixels + pixelCount > _maxJb2DecodedSymbolPixels) {
    throw const DjvuException('DjVu JB2 page exceeds the 64-megapixel symbol-work limit.');
  }
  if (ledger != null) ledger.charge(pixelCount);
  budget?.reserve(pixels: 0, rasterBytes: 2 * pixelCount);

  if (pixelCount == 0) {
    return DjvuJb2Symbol(width: width, height: height, pixels: Uint8List(0));
  }
  final pixels = Uint8List(pixelCount);
  final rowShift = (reference.height - 1) ~/ 2 - (height - 1) ~/ 2;
  final columnShift = (reference.width - 1) ~/ 2 - (width - 1) ~/ 2;
  for (var row = 0; row < height; row++) {
    final referenceRow = reference.height - height + row - rowShift;
    for (var column = 0; column < width; column++) {
      final index = row * width + column;
      if ((index & 1023) == 0 && zp.syntheticBytes > _maxSyntheticBytes) {
        throw const DjvuException('Truncated DjVu JB2 refinement bitmap.');
      }
      final context =
          (_pixel(pixels, width, row - 1, column - 1) << 10) |
          (_pixel(pixels, width, row - 1, column) << 9) |
          (_pixel(pixels, width, row - 1, column + 1) << 8) |
          (_pixel(pixels, width, row, column - 1) << 7) |
          (_pixel(reference.pixels, reference.width, referenceRow - 1, column + columnShift) << 6) |
          (_pixel(reference.pixels, reference.width, referenceRow, column + columnShift - 1) << 5) |
          (_pixel(reference.pixels, reference.width, referenceRow, column + columnShift) << 4) |
          (_pixel(reference.pixels, reference.width, referenceRow, column + columnShift + 1) << 3) |
          (_pixel(reference.pixels, reference.width, referenceRow + 1, column + columnShift - 1) <<
              2) |
          (_pixel(reference.pixels, reference.width, referenceRow + 1, column + columnShift) << 1) |
          _pixel(reference.pixels, reference.width, referenceRow + 1, column + columnShift + 1);
      final decoded = zp.decodeBit(contexts[context]);
      pixels[index] = decoded.bit ? 1 : 0;
      contexts[context] = decoded.state;
    }
  }
  return DjvuJb2Symbol(width: width, height: height, pixels: pixels);
}

int _pixel(final Uint8List pixels, final int width, final int row, final int column) {
  if (row < 0 || column < 0 || column >= width) return 0;
  final index = row * width + column;
  return index >= pixels.length ? 0 : pixels[index];
}

void _blit(
  final Uint8List page,
  final int pageWidth,
  final int pageHeight,
  final DjvuJb2Symbol symbol,
  final int x,
  final int bottomOriginY,
) {
  // JB2 rows are numbered from the bottom of the page, while the decoded
  // symbol bitmap and mask raster are stored top-down.
  final y = pageHeight - bottomOriginY - symbol.height;
  final startX = x < 0 ? 0 : x;
  final startY = y < 0 ? 0 : y;
  final endX = x + symbol.width > pageWidth ? pageWidth : x + symbol.width;
  final endY = y + symbol.height > pageHeight ? pageHeight : y + symbol.height;
  if (startX >= endX || startY >= endY) return;
  for (var row = startY; row < endY; row++) {
    final sourceStart = (row - y) * symbol.width + startX - x;
    final destinationStart = row * pageWidth + startX;
    for (var column = 0; column < endX - startX; column++) {
      if (symbol.pixels[sourceStart + column] != 0) {
        page[destinationStart + column] = 1;
      }
    }
  }
}

/// Paints every blit's palette color into a page color map.
///
/// The pass order mirrors the native foreground renderer: repeatedly take
/// the first remaining blit as its color group's leader, walk forward while
/// the blits' left coordinates never regress, and paint the gathered blits
/// of the leader's color. Later passes overwrite earlier ones, so a pixel
/// takes the color of the last pass covering it. The native loop spins when
/// a pass leader sits left of x=0; this pass paints that leader alone and
/// keeps making progress instead.
Uint16List _paintBlitColors(
  final List<DjvuJb2BlitPlacement> blits,
  final List<int> colorIndices,
  final int pageWidth,
  final int pageHeight,
) {
  final colorMap = Uint16List(pageWidth * pageHeight);
  final previous = List<int>.generate(blits.length + 1, (final i) => i - 1);
  final next = List<int>.generate(blits.length + 1, (final i) => i + 1);
  int head = 0;
  var steps = 0;
  while (head != blits.length) {
    final color = colorIndices[head];
    final painted = <int>[];
    var lastx = 0;
    var paintedLeader = false;
    var cursor = head;
    while (cursor != blits.length) {
      if (++steps > _maxJb2ColorScanSteps) {
        throw const DjvuException('DjVu FGbz color pass exceeds its 64-million-step work limit.');
      }
      final following = next[cursor];
      final left = blits[cursor].left;
      if (left < lastx) break;
      lastx = left;
      if (colorIndices[cursor] == color) {
        // Splice the blit out of the live chain and paint it with its group.
        painted.add(cursor);
        if (cursor == head) {
          head = following;
          paintedLeader = true;
        } else {
          next[previous[cursor]] = following;
          if (following != blits.length) previous[following] = previous[cursor];
        }
      }
      cursor = following;
    }
    if (!paintedLeader) {
      // A pass leader left of x=0 paints alone so the walk always advances.
      painted.add(head);
      head = next[head];
    }
    for (final blitNo in painted) {
      _stampColor(colorMap, pageWidth, pageHeight, blits[blitNo], colorIndices[blitNo] + 1);
    }
  }
  return colorMap;
}

/// Writes a blit's palette color over its ink pixels, clipped to the page.
void _stampColor(
  final Uint16List colorMap,
  final int pageWidth,
  final int pageHeight,
  final DjvuJb2BlitPlacement blit,
  final int colorValue,
) {
  final symbol = blit.symbol;
  final y = pageHeight - blit.bottom - symbol.height;
  final startX = blit.left < 0 ? 0 : blit.left;
  final startY = y < 0 ? 0 : y;
  final endX = blit.left + symbol.width > pageWidth ? pageWidth : blit.left + symbol.width;
  final endY = y + symbol.height > pageHeight ? pageHeight : y + symbol.height;
  if (startX >= endX || startY >= endY) return;
  for (var row = startY; row < endY; row++) {
    final sourceStart = (row - y) * symbol.width + startX - blit.left;
    final destinationStart = row * pageWidth + startX;
    for (var column = 0; column < endX - startX; column++) {
      if (symbol.pixels[sourceStart + column] != 0) {
        colorMap[destinationStart + column] = colorValue;
      }
    }
  }
}

DjvuJb2Symbol _cropSymbol(final DjvuJb2Symbol symbol) {
  var left = symbol.width;
  var top = symbol.height;
  var right = -1;
  var bottom = -1;
  for (var row = 0; row < symbol.height; row++) {
    final rowStart = row * symbol.width;
    for (var column = 0; column < symbol.width; column++) {
      if (symbol.pixels[rowStart + column] != 0) {
        if (column < left) left = column;
        if (column > right) right = column;
        if (row < top) top = row;
        if (row > bottom) bottom = row;
      }
    }
  }
  if (right < left || bottom < top) {
    return DjvuJb2Symbol(width: 0, height: 0, pixels: Uint8List(0));
  }
  final width = right - left + 1;
  final height = bottom - top + 1;
  final pixels = Uint8List(width * height);
  for (var row = 0; row < height; row++) {
    pixels.setRange(
      row * width,
      (row + 1) * width,
      symbol.pixels,
      (top + row) * symbol.width + left,
    );
  }
  return DjvuJb2Symbol(width: width, height: height, pixels: pixels);
}

/// Crops and stores a decoded symbol, enforcing the per-stream stored limits.
/// Returns the updated stored-pixel count.
int _addStoredSymbol(
  final List<DjvuJb2Symbol> symbols,
  final DjvuJb2Symbol symbol,
  final int priorStoredPixels,
) {
  if (symbols.length >= _maxJb2Records) {
    throw const DjvuException('DjVu JB2 symbol dictionary exceeds the record limit.');
  }
  final cropped = _cropSymbol(symbol);
  final storedPixels = priorStoredPixels + cropped.width * cropped.height;
  if (storedPixels > _maxJb2DictionaryPixels) {
    throw const DjvuException('DjVu JB2 symbol dictionary exceeds the 16-megapixel limit.');
  }
  symbols.add(cropped);
  return storedPixels;
}

/// Resolves a refinement or copy record's symbol index against the combined
/// inherited-plus-local symbol list.
DjvuJb2Symbol _referenceSymbol(
  final List<DjvuJb2Symbol> symbols,
  final DjvuZpDecoder zp,
  final _NumberContext symbolIndex,
) {
  if (symbols.isEmpty) {
    throw const DjvuException('DjVu JB2 refinement record references an empty dictionary.');
  }
  final index = _decodeNumber(zp, symbolIndex, 0, symbols.length - 1);
  if (index < 0 || index >= symbols.length) {
    throw const DjvuException('DjVu JB2 refinement record references an invalid symbol.');
  }
  return symbols[index];
}

(int, int) _decodeSymbolCoordinates(
  final DjvuZpDecoder zp,
  final _CoordinateContexts contexts,
  final _Jb2Layout layout,
  final int symbolWidth,
  final int symbolHeight,
) {
  final newLineBit = zp.decodeBit(contexts.offsetType);
  contexts.offsetType = newLineBit.state;
  late final int x;
  late final int y;
  if (newLineBit.bit) {
    final horizontalOffset = _decodeNumber(zp, contexts.horizontalOffset, -262143, 262142);
    final verticalOffset = _decodeNumber(zp, contexts.verticalOffset, -262143, 262142);
    x = layout.firstLeft + horizontalOffset;
    y = layout.firstBottom + verticalOffset - symbolHeight + 1;
    layout.firstLeft = x;
    layout.firstBottom = y;
    layout.baseline.fill(y);
  } else {
    final horizontalOffset = _decodeNumber(zp, contexts.sameLineHorizontalOffset, -262143, 262142);
    final verticalOffset = _decodeNumber(zp, contexts.sameLineVerticalOffset, -262143, 262142);
    x = layout.lastRight + horizontalOffset;
    y = layout.baseline.value + verticalOffset;
  }
  layout.baseline.add(y);
  layout.lastRight = x + symbolWidth - 1;
  return (x, y);
}

int _decodeNumber(final DjvuZpDecoder zp, final _NumberContext contexts, int low, int high) {
  var negative = false;
  var cutoff = 0;
  var range = 0xFFFFFFFF;
  var phase = 1;
  var node = 1;
  var iterations = 0;
  while (range != 1) {
    if (++iterations > 64) {
      throw const DjvuException('Invalid DjVu JB2 integer code.');
    }
    late final bool decision;
    if (low >= cutoff) {
      decision = true;
    } else if (high >= cutoff) {
      final decoded = zp.decodeBit(contexts.states[node]);
      contexts.states[node] = decoded.state;
      decision = decoded.bit;
    } else {
      decision = false;
    }
    node = decision ? contexts.right(node) : contexts.left(node);
    switch (phase) {
      case 1:
        negative = !decision;
        if (negative) {
          final temp = -low - 1;
          low = -high - 1;
          high = temp;
        }
        phase = 2;
        cutoff = 1;
      case 2:
        if (!decision) {
          phase = 3;
          range = (cutoff + 1) ~/ 2;
          if (range == 1) {
            cutoff = 0;
          } else {
            cutoff -= range ~/ 2;
          }
        } else {
          cutoff = cutoff * 2 + 1;
        }
      case 3:
        range ~/= 2;
        if (range == 0) range = 1;
        if (range != 1) {
          cutoff += decision ? range ~/ 2 : -(range ~/ 2);
        } else if (!decision) {
          cutoff--;
        }
      default:
        throw const DjvuException('Invalid DjVu JB2 integer phase.');
    }
  }
  return negative ? -cutoff - 1 : cutoff;
}

/// One decoded JB2 symbol bitmap, cropped to its ink bounds.
final class DjvuJb2Symbol {
  /// Creates a symbol bitmap.
  const DjvuJb2Symbol({required this.width, required this.height, required this.pixels});

  /// Symbol width in pixels.
  final int width;

  /// Symbol height in pixels.
  final int height;

  /// One byte per pixel in top-to-bottom order. One means black ink.
  final Uint8List pixels;
}

final class _CoordinateContexts {
  _CoordinateContexts(final _ContextNodeBudget budget)
    : horizontalOffset = _NumberContext(budget),
      verticalOffset = _NumberContext(budget),
      sameLineHorizontalOffset = _NumberContext(budget),
      sameLineVerticalOffset = _NumberContext(budget);

  int offsetType = 0;
  final _NumberContext horizontalOffset;
  final _NumberContext verticalOffset;
  final _NumberContext sameLineHorizontalOffset;
  final _NumberContext sameLineVerticalOffset;
}

final class _Jb2Layout {
  _Jb2Layout(final int imageHeight) : firstBottom = imageHeight - 1, baseline = _Baseline();

  int firstLeft = -1;
  int firstBottom;
  int lastRight = 0;
  final _Baseline baseline;
}

final class _Baseline {
  final List<int> _values = <int>[0, 0, 0];
  var _index = -1;

  int get value {
    final a = _values[0];
    final b = _values[1];
    final c = _values[2];
    if ((a >= b && a <= c) || (a <= b && a >= c)) return a;
    if ((b >= a && b <= c) || (b <= a && b >= c)) return b;
    return c;
  }

  void fill(final int value) {
    _values.fillRange(0, 3, value);
  }

  void add(final int value) {
    _index = (_index + 1) % 3;
    _values[_index] = value;
  }
}

final class _ContextNodeBudget {
  _ContextNodeBudget([this.budget]);
  final DjvuDecodeBudget? budget;
  var count = 2;

  void addNode() {
    if (count >= _maxJb2ContextNodes) {
      throw const DjvuException('DjVu JB2 arithmetic contexts exceed the allocation limit.');
    }
    budget?.reserve(pixels: 0, rasterBytes: 64);
    count++;
  }
}

final class _NumberContext {
  _NumberContext(final _ContextNodeBudget budget) : _budget = budget;

  final _ContextNodeBudget _budget;
  final List<int> states = <int>[0, 0];
  final List<int> _left = <int>[0, 0];
  final List<int> _right = <int>[0, 0];

  int left(final int node) {
    if (_left[node] == 0) {
      _budget.addNode();
      _left[node] = states.length;
      states.add(0);
      _left.add(0);
      _right.add(0);
    }
    return _left[node];
  }

  int right(final int node) {
    if (_right[node] == 0) {
      _budget.addNode();
      _right[node] = states.length;
      states.add(0);
      _left.add(0);
      _right.add(0);
    }
    return _right[node];
  }
}
