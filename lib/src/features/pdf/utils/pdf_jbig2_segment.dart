/// JBIG2 (ITU-T T.88) segment model: the header structures and the
/// integer/bit decoding procedures the region decoders share.
///
/// Ported from pdf.js v3.11.174 `src/core/jbig2.js`, Apache-2.0;
/// parity comments point at the mirrored functions. Only the
/// embedded format PDFs use is wired up here — the file header of
/// the standalone format is handled in `decodeJbig2`.
library;

import 'dart:typed_data';

import '../exceptions/pdf_exception.dart';
import 'pdf_jbig2_arithmetic.dart';

/// The segment types (7.3) pdf.js names; `null` entries are
/// reserved codes that never reach the switch.
// pdf.js jbig2.js SegmentTypes
const List<String?> jbig2SegmentTypes = <String?>[
  'SymbolDictionary',
  null,
  null,
  null,
  'IntermediateTextRegion',
  null,
  'ImmediateTextRegion',
  'ImmediateLosslessTextRegion',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  'PatternDictionary',
  null,
  null,
  null,
  'IntermediateHalftoneRegion',
  null,
  'ImmediateHalftoneRegion',
  'ImmediateLosslessHalftoneRegion',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  'IntermediateGenericRegion',
  null,
  'ImmediateGenericRegion',
  'ImmediateLosslessGenericRegion',
  'IntermediateGenericRefinementRegion',
  null,
  'ImmediateGenericRefinementRegion',
  'ImmediateLosslessGenericRefinementRegion',
  null,
  null,
  null,
  null,
  'PageInformation',
  'EndOfPage',
  'EndOfStripe',
  'EndOfFile',
  'Profiles',
  'Tables',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  'Extension',
];

// pdf.js jbig2.js CodingTemplates
/// The four generic-region coding templates (6.2.5.3).
const List<List<Point>> jbig2CodingTemplates = <List<Point>>[
  <Point>[
    Point(-1, -2), Point(0, -2), Point(1, -2), Point(-2, -1), //
    Point(-1, -1), Point(0, -1), Point(1, -1), Point(2, -1),
    Point(-4, 0), Point(-3, 0), Point(-2, 0), Point(-1, 0),
  ],
  <Point>[
    Point(-1, -2),
    Point(0, -2),
    Point(1, -2),
    Point(2, -2),
    Point(-2, -1),
    Point(-1, -1),
    Point(0, -1),
    Point(1, -1),
    Point(2, -1),
    Point(-3, 0),
    Point(-2, 0),
    Point(-1, 0),
  ],
  <Point>[
    Point(-1, -2),
    Point(0, -2),
    Point(1, -2),
    Point(-2, -1),
    Point(-1, -1),
    Point(0, -1),
    Point(1, -1),
    Point(-2, 0),
    Point(-1, 0),
  ],
  <Point>[
    Point(-3, -1),
    Point(-2, -1),
    Point(-1, -1),
    Point(0, -1),
    Point(1, -1),
    Point(-4, 0),
    Point(-3, 0),
    Point(-2, 0),
    Point(-1, 0),
  ],
];

// pdf.js jbig2.js RefinementTemplates
/// The two generic-refinement coding/reference template sets (6.3).
const List<Jbig2RefinementTemplate> jbig2RefinementTemplates = <Jbig2RefinementTemplate>[
  Jbig2RefinementTemplate(
    coding: <Point>[Point(0, -1), Point(1, -1), Point(-1, 0)],
    reference: <Point>[
      Point(0, -1), Point(1, -1), Point(-1, 0), Point(0, 0), //
      Point(1, 0), Point(-1, 1), Point(0, 1), Point(1, 1),
    ],
  ),
  Jbig2RefinementTemplate(
    coding: <Point>[Point(-1, -1), Point(0, -1), Point(1, -1), Point(-1, 0)],
    reference: <Point>[
      Point(0, -1), Point(-1, 0), Point(0, 0), Point(1, 0), //
      Point(0, 1), Point(1, 1),
    ],
  ),
];

// pdf.js jbig2.js ReusedContexts (6.2.5.7)
/// The pseudo-pixel context per generic template (6.2.5.7).
const List<int> jbig2ReusedContexts = <int>[0x9B25, 0x0795, 0x00E5, 0x0195];

// pdf.js jbig2.js RefinementReusedContexts
/// The pseudo-pixel context per refinement template (6.3.2.6).
const List<int> jbig2RefinementReusedContexts = <int>[0x0020, 0x0008];

/// A template pixel offset; pdf.js uses `{x, y}` object literals.
class Point {
  /// Creates the offset ([x], [y]).
  const Point(this.x, this.y);

  /// Horizontal pixel offset (negative = left of the current pixel).
  final int x;

  /// Vertical pixel offset (negative = above the current pixel).
  final int y;
}

/// The coding/reference template pair of the refinement decoder.
class Jbig2RefinementTemplate {
  /// Creates the template pair from [coding] and [reference] offsets.
  const Jbig2RefinementTemplate({required this.coding, required this.reference});

  /// The coding-pixel offsets relative to the current pixel.
  final List<Point> coding;

  /// The reference-pixel offsets relative to the current pixel.
  final List<Point> reference;
}

/// Reads a big-endian unsigned 16-bit word, pdf.js `readUint16`.
int jbig2ReadUint16(final Uint8List data, final int offset) {
  if (offset + 1 >= data.length) {
    throw const PdfException('JBIG2 error: truncated segment data.');
  }
  return (data[offset] << 8) | data[offset + 1];
}

/// Reads a big-endian unsigned 32-bit word, pdf.js `readUint32`.
int jbig2ReadUint32(final Uint8List data, final int offset) {
  if (offset + 3 >= data.length) {
    throw const PdfException('JBIG2 error: truncated segment data.');
  }
  return ((data[offset] << 24) |
          (data[offset + 1] << 16) |
          (data[offset + 2] << 8) |
          data[offset + 3]) &
      0xFFFFFFFF;
}

/// Reads a signed byte, pdf.js `readInt8`.
int jbig2ReadInt8(final Uint8List data, final int offset) {
  if (offset >= data.length) {
    throw const PdfException('JBIG2 error: truncated segment data.');
  }
  return data[offset].toSigned(8);
}

/// ceil(log2(x)) for positive x, pdf.js `log2` (0 for x <= 0).
int jbig2Log2(final int x) {
  if (x <= 0) {
    return 0;
  }
  var value = x;
  var bits = 0;
  while (value > 1) {
    value >>= 1;
    bits++;
  }
  return (1 << bits) >= x ? bits : bits + 1;
}

const int _maxInt32 = 0x7FFFFFFF;
const int _minInt32 = -0x80000000;

/// Annex A.2 — arithmetic integer decoding procedure
/// (`decodeInteger` in pdf.js); returns null on the out-of-band
/// pattern or on a value outside the 32-bit range. The [contexts]
/// table comes from the segment's own context cache, keyed by
/// [procedure], exactly as pdf.js's `contextCache.getContexts(id)`.
// pdf.js jbig2.js decodeInteger
int? decodeJbig2Integer(
  final Uint8List contexts,
  final String procedure,
  final Jbig2ArithmeticDecoder decoder,
) {
  final table = contexts;
  final prevHolder = <int>[1];

  int readBits(final int length) {
    var v = 0;
    for (var i = 0; i < length; i++) {
      final bit = decoder.readBit(table, prevHolder[0]);
      prevHolder[0] = prevHolder[0] < 256
          ? ((prevHolder[0] << 1) | bit)
          : (((prevHolder[0] << 1) | bit) & 511) | 256;
      v = (v << 1) | bit;
    }
    return v;
  }

  final sign = readBits(1);
  // A.2 value ranges: 2, 4+4, 6+20, 8+84, 12+340, 32+4436 bits.
  int value;
  if (readBits(1) == 0) {
    value = readBits(2);
  } else if (readBits(1) == 0) {
    value = readBits(4) + 4;
  } else if (readBits(1) == 0) {
    value = readBits(6) + 20;
  } else if (readBits(1) == 0) {
    value = readBits(8) + 84;
  } else if (readBits(1) == 0) {
    value = readBits(12) + 340;
  } else {
    value = readBits(32) + 4436;
  }
  // pdf.js leaves `signedValue` undefined when sign is set and the
  // magnitude is zero; that undefined flows out as the out-of-band
  // null, so keep the null instead of folding it to 0.
  int? signedValue;
  if (sign == 0) {
    signedValue = value;
  } else if (value > 0) {
    signedValue = -value;
  }
  // Ensure that the integer value doesn't underflow or overflow.
  if (signedValue != null && signedValue >= _minInt32 && signedValue <= _maxInt32) {
    return signedValue;
  }

  return null;
}

/// A.3 — the IAID decoding procedure (`decodeIAID` in pdf.js). The
/// IAID contexts are cached per segment under the reserved id `IAID`
/// (pdf.js reserves slot 3 of the context cache for it).
// pdf.js jbig2.js decodeIAID
int decodeJbig2Iaid(
  final Uint8List contexts,
  final Jbig2ArithmeticDecoder decoder,
  final int codeLength,
) {
  final table = contexts;
  var prev = 1;
  for (var i = 0; i < codeLength; i++) {
    final bit = decoder.readBit(table, prev);
    prev = (prev << 1) | bit;
  }
  if (codeLength < 31) {
    return prev & ((1 << codeLength) - 1);
  }

  return prev & 0x7FFFFFFF;
}

/// The reserved context-cache id of the IAID table (pdf.js reserves
/// `3`, the slot right after the named procedures).
const String jbig2IaidContextId = '3';

/// One parsed segment header (7.2).
class Jbig2SegmentHeader {
  /// Creates the header from the parsed 7.2 fields.
  Jbig2SegmentHeader({
    required this.number,
    required this.type,
    required this.typeName,
    required this.deferredNonRetain,
    required this.pageAssociation,
    required this.length,
    required this.headerEnd,
    required this.referredTo,
    required this.retainBits,
  });

  /// Segment number (7.2.5).
  final int number;

  /// The segment type code (7.3).
  final int type;

  /// The pdf.js name of the segment type.
  final String typeName;

  /// The deferred-non-retain flag (7.2.6).
  final bool deferredNonRetain;

  /// The page this segment belongs to (7.2.7).
  final int pageAssociation;

  /// The segment data length (7.2.7).
  final int length;

  /// Byte offset just past the header (where the data starts).
  final int headerEnd;

  /// The referred-to segment numbers (7.2.5).
  final List<int> referredTo;

  /// The retain flags (7.2.5).
  final List<int> retainBits;
}

/// Parses one segment header at [start] (`readSegmentHeader`).
// pdf.js jbig2.js readSegmentHeader
Jbig2SegmentHeader readJbig2SegmentHeader(final Uint8List data, final int start) {
  if (start + 11 > data.length) {
    throw const PdfException('JBIG2 error: truncated segment header.');
  }
  final number = jbig2ReadUint32(data, start);
  final flags = data[start + 4];
  final segmentType = flags & 0x3F;
  final typeName = segmentType < jbig2SegmentTypes.length ? jbig2SegmentTypes[segmentType] : null;
  if (typeName == null) {
    throw PdfException('JBIG2 error: invalid segment type: $segmentType');
  }
  final deferredNonRetain = flags & 0x80 != 0;

  final pageAssociationFieldSize = flags & 0x40 != 0;
  final referredFlags = data[start + 5];
  var referredToCount = (referredFlags >> 5) & 7;
  final retainBits = <int>[referredFlags & 31];
  var position = start + 6;
  if (referredFlags == 7) {
    referredToCount = jbig2ReadUint32(data, position - 1) & 0x1FFFFFFF;
    position += 3;
    var bytes = (referredToCount + 7) >> 3;
    retainBits[0] = data[position];
    position++;
    while (--bytes > 0) {
      retainBits.add(data[position]);
      position++;
    }
  } else if (referredFlags == 5 || referredFlags == 6) {
    throw const PdfException('JBIG2 error: invalid referred-to flags');
  }

  var referredToSegmentNumberSize = 4;
  if (number <= 256) {
    referredToSegmentNumberSize = 1;
  } else if (number <= 65536) {
    referredToSegmentNumberSize = 2;
  }
  final referredTo = <int>[];
  for (var i = 0; i < referredToCount; i++) {
    if (position + referredToSegmentNumberSize > data.length) {
      throw const PdfException('JBIG2 error: truncated referred-to list.');
    }
    var numberValue = 0;
    if (referredToSegmentNumberSize == 1) {
      numberValue = data[position];
    } else if (referredToSegmentNumberSize == 2) {
      numberValue = jbig2ReadUint16(data, position);
    } else {
      numberValue = jbig2ReadUint32(data, position);
    }
    referredTo.add(numberValue);
    position += referredToSegmentNumberSize;
  }
  int pageAssociation;
  if (!pageAssociationFieldSize) {
    pageAssociation = data[position];
    position++;
  } else {
    pageAssociation = jbig2ReadUint32(data, position);
    position += 4;
  }
  var length = jbig2ReadUint32(data, position);
  position += 4;

  if (length == 0xFFFFFFFF) {
    // 7.2.7 Segment data length, unknown segment length.
    if (segmentType == 38) {
      // ImmediateGenericRegion
      final genericRegionInfo = readJbig2RegionSegmentInformation(data, position);
      final genericRegionSegmentFlags = data[position + jbig2RegionSegmentInformationFieldLength];
      final genericRegionMmr = genericRegionSegmentFlags & 1 != 0;
      // searching for the segment end
      const searchPatternLength = 6;
      final searchPattern = Uint8List(searchPatternLength);
      if (!genericRegionMmr) {
        searchPattern[0] = 0xFF;
        searchPattern[1] = 0xAC;
      }
      searchPattern[2] = (genericRegionInfo.height >> 24) & 0xFF;
      searchPattern[3] = (genericRegionInfo.height >> 16) & 0xFF;
      searchPattern[4] = (genericRegionInfo.height >> 8) & 0xFF;
      searchPattern[5] = genericRegionInfo.height & 0xFF;
      var found = false;
      for (var i = position; i < data.length; i++) {
        var j = 0;
        while (j < searchPatternLength && i + j < data.length && searchPattern[j] == data[i + j]) {
          j++;
        }
        if (j == searchPatternLength) {
          length = i + searchPatternLength;
          found = true;
          break;
        }
      }
      if (!found) {
        throw const PdfException('JBIG2 error: segment end was not found');
      }
    } else {
      throw const PdfException('JBIG2 error: invalid unknown segment length');
    }
  }

  return Jbig2SegmentHeader(
    number: number,
    type: segmentType,
    typeName: typeName,
    deferredNonRetain: deferredNonRetain,
    pageAssociation: pageAssociation,
    length: length,
    headerEnd: position,
    referredTo: referredTo,
    retainBits: retainBits,
  );
}

/// 7.4.1 Region segment information field
/// (`readRegionSegmentInformation`).
class Jbig2RegionSegmentInformation {
  /// Creates the 7.4.1 field values.
  const Jbig2RegionSegmentInformation({
    required this.width,
    required this.height,
    required this.x,
    required this.y,
    required this.combinationOperator,
  });

  /// Region width in pixels.
  final int width;

  /// Region height in pixels.
  final int height;

  /// Horizontal placement on the page.
  final int x;

  /// Vertical placement on the page.
  final int y;

  /// The external combination operator (6.1).
  final int combinationOperator;
}

/// The byte length of the region segment information field.
const int jbig2RegionSegmentInformationFieldLength = 17;

/// Reads the 7.4.1 field at [start].
// pdf.js jbig2.js readRegionSegmentInformation
Jbig2RegionSegmentInformation readJbig2RegionSegmentInformation(
  final Uint8List data,
  final int start,
) {
  return Jbig2RegionSegmentInformation(
    width: jbig2ReadUint32(data, start),
    height: jbig2ReadUint32(data, start + 4),
    x: jbig2ReadUint32(data, start + 8),
    y: jbig2ReadUint32(data, start + 12),
    combinationOperator: data[start + 16] & 7,
  );
}
