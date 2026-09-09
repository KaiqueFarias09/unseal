/// MMR (Group 4 fax) coding as JBIG2 applies it: the same T.6
/// algorithm as PDF's CCITTFaxDecode with `/K -1`, reading from a
/// byte window of the JBIG2 segment payload.
///
/// Ported from pdf.js v3.11.174 `src/core/ccitt.js`
/// (`CCITTFaxDecoder`, itself a port of XPDF's implementation,
/// Apache-2.0), narrowed to what `decodeMMRBitmap` in
/// `src/core/jbig2.js` uses: `BlackIs1: true`, `K = -1`, fixed
/// columns/rows, end-of-block mode only. The fax tables are pdf.js's
/// lookup tables flattened to parallel const lists; parity comments
/// point at the source blocks.
library;

import 'dart:typed_data';

import '../../exceptions/pdf_exception.dart';

// pdf.js ccitt.js ccittEOL / ccittEOF
const int _ccittEOF = -1;
const int _twoDimPass = 0;
const int _twoDimHoriz = 1;
const int _twoDimVert0 = 2;
const int _twoDimVertR1 = 3;
const int _twoDimVertL1 = 4;
const int _twoDimVertR2 = 5;
const int _twoDimVertL2 = 6;
const int _twoDimVertR3 = 7;
const int _twoDimVertL3 = 8;

// pdf.js ccitt.js twoDimTable
const List<int> _twoDimTableBits = <int>[
  -1,
  -1,
  7,
  7,
  6,
  6,
  6,
  6,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
];
// pdf.js ccitt.js twoDimTable
const List<int> _twoDimTableCodes = <int>[
  -1,
  -1,
  8,
  7,
  6,
  6,
  5,
  5,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
];

// pdf.js ccitt.js whiteTable1
const List<int> _whiteTable1Bits = <int>[
  -1,
  12,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  11,
  11,
  12,
  12,
  12,
  12,
  12,
  12,
  11,
  11,
  11,
  11,
  12,
  12,
  12,
  12,
];
// pdf.js ccitt.js whiteTable1
const List<int> _whiteTable1Codes = <int>[
  -1,
  -2,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  1792,
  1792,
  1984,
  2048,
  2112,
  2176,
  2240,
  2304,
  1856,
  1856,
  1920,
  1920,
  2368,
  2432,
  2496,
  2560,
];

// pdf.js ccitt.js whiteTable2
const List<int> _whiteTable2Bits = <int>[
  -1,
  -1,
  -1,
  -1,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  8,
  8,
  8,
  8,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  7,
  7,
  7,
  7,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  7,
  7,
  7,
  7,
  8,
  8,
  8,
  8,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  8,
  8,
  8,
  8,
  7,
  7,
  7,
  7,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  7,
  7,
  7,
  7,
  8,
  8,
  8,
  8,
  9,
  9,
  9,
  9,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  7,
  7,
  7,
  7,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  8,
  8,
  8,
  8,
  9,
  9,
  8,
  8,
  8,
  8,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  7,
  7,
  7,
  7,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
];
// pdf.js ccitt.js whiteTable2
const List<int> _whiteTable2Codes = <int>[
  -1,
  -1,
  -1,
  -1,
  29,
  29,
  30,
  30,
  45,
  45,
  46,
  46,
  22,
  22,
  22,
  22,
  23,
  23,
  23,
  23,
  47,
  47,
  48,
  48,
  13,
  13,
  13,
  13,
  13,
  13,
  13,
  13,
  20,
  20,
  20,
  20,
  33,
  33,
  34,
  34,
  35,
  35,
  36,
  36,
  37,
  37,
  38,
  38,
  19,
  19,
  19,
  19,
  31,
  31,
  32,
  32,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  53,
  53,
  54,
  54,
  26,
  26,
  26,
  26,
  39,
  39,
  40,
  40,
  41,
  41,
  42,
  42,
  43,
  43,
  44,
  44,
  21,
  21,
  21,
  21,
  28,
  28,
  28,
  28,
  61,
  61,
  62,
  62,
  63,
  63,
  0,
  0,
  320,
  320,
  384,
  384,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  27,
  27,
  27,
  27,
  59,
  59,
  60,
  60,
  1472,
  1536,
  1600,
  1728,
  18,
  18,
  18,
  18,
  24,
  24,
  24,
  24,
  49,
  49,
  50,
  50,
  51,
  51,
  52,
  52,
  25,
  25,
  25,
  25,
  55,
  55,
  56,
  56,
  57,
  57,
  58,
  58,
  192,
  192,
  192,
  192,
  192,
  192,
  192,
  192,
  1664,
  1664,
  1664,
  1664,
  1664,
  1664,
  1664,
  1664,
  448,
  448,
  512,
  512,
  704,
  768,
  640,
  640,
  576,
  576,
  832,
  896,
  960,
  1024,
  1088,
  1152,
  1216,
  1280,
  1344,
  1408,
  256,
  256,
  256,
  256,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  128,
  128,
  128,
  128,
  128,
  128,
  128,
  128,
  128,
  128,
  128,
  128,
  128,
  128,
  128,
  128,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  16,
  16,
  16,
  16,
  16,
  16,
  16,
  16,
  17,
  17,
  17,
  17,
  17,
  17,
  17,
  17,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  5,
  14,
  14,
  14,
  14,
  14,
  14,
  14,
  14,
  15,
  15,
  15,
  15,
  15,
  15,
  15,
  15,
  64,
  64,
  64,
  64,
  64,
  64,
  64,
  64,
  64,
  64,
  64,
  64,
  64,
  64,
  64,
  64,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  6,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
];

// pdf.js ccitt.js blackTable1
const List<int> _blackTable1Bits = <int>[
  -1,
  -1,
  12,
  12,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  11,
  11,
  11,
  11,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  12,
  12,
  13,
  13,
  13,
  13,
  12,
  12,
  12,
  12,
  13,
  13,
  13,
  13,
  12,
  12,
  12,
  12,
  13,
  13,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  13,
  13,
  12,
  12,
  12,
  12,
  12,
  12,
  13,
  13,
  12,
  12,
  12,
  12,
  13,
  13,
  13,
  13,
  13,
  13,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
];
// pdf.js ccitt.js blackTable1
const List<int> _blackTable1Codes = <int>[
  -1,
  -1,
  -2,
  -2,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  -1,
  1792,
  1792,
  1792,
  1792,
  1984,
  1984,
  2048,
  2048,
  2112,
  2112,
  2176,
  2176,
  2240,
  2240,
  2304,
  2304,
  1856,
  1856,
  1856,
  1856,
  1920,
  1920,
  1920,
  1920,
  2368,
  2368,
  2432,
  2432,
  2496,
  2496,
  2560,
  2560,
  18,
  18,
  18,
  18,
  18,
  18,
  18,
  18,
  52,
  52,
  640,
  704,
  768,
  832,
  55,
  55,
  56,
  56,
  1280,
  1344,
  1408,
  1472,
  59,
  59,
  60,
  60,
  1536,
  1600,
  24,
  24,
  24,
  24,
  25,
  25,
  25,
  25,
  1664,
  1728,
  320,
  320,
  384,
  384,
  448,
  448,
  512,
  576,
  53,
  53,
  54,
  54,
  896,
  960,
  1024,
  1088,
  1152,
  1216,
  64,
  64,
  64,
  64,
  64,
  64,
  64,
  64,
];

// pdf.js ccitt.js blackTable2
const List<int> _blackTable2Bits = <int>[
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  11,
  11,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  11,
  11,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  8,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  9,
  12,
  12,
  12,
  12,
  12,
  12,
  11,
  11,
  11,
  11,
  12,
  12,
  12,
  12,
  12,
  12,
  11,
  11,
  12,
  12,
  10,
  10,
  10,
  10,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
  7,
];
// pdf.js ccitt.js blackTable2
const List<int> _blackTable2Codes = <int>[
  13,
  13,
  13,
  13,
  13,
  13,
  13,
  13,
  13,
  13,
  13,
  13,
  13,
  13,
  13,
  13,
  23,
  23,
  50,
  51,
  44,
  45,
  46,
  47,
  57,
  58,
  61,
  256,
  16,
  16,
  16,
  16,
  17,
  17,
  17,
  17,
  48,
  49,
  62,
  63,
  30,
  31,
  32,
  33,
  40,
  41,
  22,
  22,
  14,
  14,
  14,
  14,
  14,
  14,
  14,
  14,
  14,
  14,
  14,
  14,
  14,
  14,
  14,
  14,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  10,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  11,
  15,
  15,
  15,
  15,
  15,
  15,
  15,
  15,
  128,
  192,
  26,
  27,
  28,
  29,
  19,
  19,
  20,
  20,
  34,
  35,
  36,
  37,
  38,
  39,
  21,
  21,
  42,
  43,
  0,
  0,
  0,
  0,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
  12,
];

// pdf.js ccitt.js blackTable3
const List<int> _blackTable3Bits = <int>[
  -1,
  -1,
  -1,
  -1,
  6,
  6,
  5,
  5,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
];
// pdf.js ccitt.js blackTable3
const List<int> _blackTable3Codes = <int>[
  -1,
  -1,
  -1,
  -1,
  9,
  8,
  7,
  7,
  6,
  6,
  6,
  6,
  5,
  5,
  5,
  5,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  4,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  3,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
];

/// A byte-source view over one segment payload: `_lookBits` pulls
/// whole bytes (0xFF fills past the end, matching pdf.js's `Reader`
/// used by `decodeMMRBitmap`, where `next()` returns -1 at EOF and
/// `CCITTFaxDecoder` pads with 1-bits through `0xff` semantics).
final class _MmrSource {
  _MmrSource(this.data, this.start, this.end)
    : assert(start >= 0 && start <= data.length),
      assert(end >= start && end <= data.length);

  final Uint8List data;
  int position = 0;
  final int start;
  final int end;

  int next() {
    if (position >= end) {
      return -1;
    }

    return data[start + position++];
  }
}

/// The MMR decoder state machine (`CCITTFaxDecoder` in pdf.js with
/// `K = -1`, `BlackIs1: true`, `EndOfBlock` per call site).
final class _CcittFaxDecoder {
  // pdf.js ccitt.js constructor (K=-1, no EndOfLine, no
  // EncodedByteAlign, eoblock configurable, black=true).
  _CcittFaxDecoder(this._source, {required final int columns, required final bool endOfBlock})
    : _columns = columns,
      _eoblock = endOfBlock,
      _codingLine = Uint32List(columns + 1),
      _refLine = Uint32List(columns + 2) {
    _codingLine[0] = columns;
    _nextLine2D = true; // encoding < 0
    var code1 = _lookBits(12);
    while (code1 == 0) {
      _eatBits(1);
      code1 = _lookBits(12);
    }
    if (code1 == 1) {
      _eatBits(12);
    }
  }

  final _MmrSource _source;
  final int _columns;
  final bool _eoblock;

  // pdf.js surfaces its `err`/`rowsDone` state through info() logs and
  // single-row EOF handling only; the MMR path tolerates damaged rows
  // and never sets rowsDone (eoblock mode owns termination here).
  bool _eof = false;

  final Uint32List _codingLine;
  final Uint32List _refLine;
  int _codingPos = 0;
  int _row = 0;
  bool _nextLine2D = true;
  int _inputBits = 0;
  int _inputBuf = 0;
  int _outputBits = 0;

  bool get eof => _eof;

  /// Reads the next packed output byte, or -1 at end of data.
  // pdf.js ccitt.js readNextChar
  int readNextChar() {
    if (_eof) {
      return -1;
    }
    final refLine = _refLine;
    final codingLine = _codingLine;
    final columns = _columns;

    int refPos, blackPixels, bits;

    if (_outputBits == 0) {
      if (_eof) {
        return -1;
      }

      int code1, code2, code3;
      if (_nextLine2D) {
        var i = 0;
        while (codingLine[i] < columns) {
          refLine[i] = codingLine[i];
          i++;
        }
        refLine[i++] = columns;
        refLine[i] = columns;
        codingLine[0] = 0;
        _codingPos = 0;
        refPos = 0;
        blackPixels = 0;

        while (codingLine[_codingPos] < columns) {
          code1 = _getTwoDimCode();
          switch (code1) {
            case _twoDimPass:
              _addPixels(refLine[refPos + 1], blackPixels);
              if (refLine[refPos + 1] < columns) {
                refPos += 2;
              }
            case _twoDimHoriz:
              code1 = code2 = 0;
              if (blackPixels != 0) {
                do {
                  code1 += code3 = _getBlackCode();
                } while (code3 >= 64);
                do {
                  code2 += code3 = _getWhiteCode();
                } while (code3 >= 64);
              } else {
                do {
                  code1 += code3 = _getWhiteCode();
                } while (code3 >= 64);
                do {
                  code2 += code3 = _getBlackCode();
                } while (code3 >= 64);
              }
              _addPixels(codingLine[_codingPos] + code1, blackPixels);
              if (codingLine[_codingPos] < columns) {
                _addPixels(codingLine[_codingPos] + code2, blackPixels ^ 1);
              }
              while (refLine[refPos] <= codingLine[_codingPos] && refLine[refPos] < columns) {
                refPos += 2;
              }
            case _twoDimVertR3:
              _addPixels(refLine[refPos] + 3, blackPixels);
              blackPixels ^= 1;
              if (codingLine[_codingPos] < columns) {
                refPos++;
                while (refLine[refPos] <= codingLine[_codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case _twoDimVertR2:
              _addPixels(refLine[refPos] + 2, blackPixels);
              blackPixels ^= 1;
              if (codingLine[_codingPos] < columns) {
                refPos++;
                while (refLine[refPos] <= codingLine[_codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case _twoDimVertR1:
              _addPixels(refLine[refPos] + 1, blackPixels);
              blackPixels ^= 1;
              if (codingLine[_codingPos] < columns) {
                refPos++;
                while (refLine[refPos] <= codingLine[_codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case _twoDimVert0:
              _addPixels(refLine[refPos], blackPixels);
              blackPixels ^= 1;
              if (codingLine[_codingPos] < columns) {
                refPos++;
                while (refLine[refPos] <= codingLine[_codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case _twoDimVertL3:
              _addPixelsNeg(refLine[refPos] - 3, blackPixels);
              blackPixels ^= 1;
              if (codingLine[_codingPos] < columns) {
                refPos = refPos > 0 ? refPos - 1 : refPos + 1;
                while (refLine[refPos] <= codingLine[_codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case _twoDimVertL2:
              _addPixelsNeg(refLine[refPos] - 2, blackPixels);
              blackPixels ^= 1;
              if (codingLine[_codingPos] < columns) {
                refPos = refPos > 0 ? refPos - 1 : refPos + 1;
                while (refLine[refPos] <= codingLine[_codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case _twoDimVertL1:
              _addPixelsNeg(refLine[refPos] - 1, blackPixels);
              blackPixels ^= 1;
              if (codingLine[_codingPos] < columns) {
                refPos = refPos > 0 ? refPos - 1 : refPos + 1;
                while (refLine[refPos] <= codingLine[_codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case _ccittEOF:
              _addPixels(columns, 0);
              _eof = true;
            default:
              // pdf.js info("bad 2d code") — tolerated, marks the row.
              _addPixels(columns, 0);
          }
        }
      } else {
        codingLine[0] = 0;
        _codingPos = 0;
        blackPixels = 0;
        while (codingLine[_codingPos] < columns) {
          code1 = 0;
          if (blackPixels != 0) {
            do {
              code1 += code3 = _getBlackCode();
            } while (code3 >= 64);
          } else {
            do {
              code1 += code3 = _getWhiteCode();
            } while (code3 >= 64);
          }
          _addPixels(codingLine[_codingPos] + code1, blackPixels);
          blackPixels ^= 1;
        }
      }

      var gotEOL = false;

      // byteAlign (EncodedByteAlign) is always false in the MMR use.

      if (_eoblock && _row == 0) {
        // Nothing special: pdf.js checks !eoblock && row == rows - 1
        // first; with eoblock always true here we go to the EOL scan.
      }
      code1 = _lookBits(12);
      // eoline is always false in the MMR use.
      while (code1 == 0) {
        _eatBits(1);
        code1 = _lookBits(12);
      }
      if (code1 == 1) {
        _eatBits(12);
        gotEOL = true;
      } else if (code1 == _ccittEOF) {
        _eof = true;
      }

      // encoding > 0 never holds for MMR (K = -1): skip the 2D flag.

      if (_eoblock && gotEOL) {
        code1 = _lookBits(12);
        if (code1 == 1) {
          _eatBits(12);
          // encoding >= 0 RTC scan never applies (K = -1).
          _eof = true;
        }
      }

      _outputBits = codingLine[0] > 0 ? codingLine[(_codingPos = 0)] : codingLine[(_codingPos = 1)];
      _row++;
    }

    int c;
    if (_outputBits >= 8) {
      c = _codingPos & 1 != 0 ? 0 : 0xFF;
      _outputBits -= 8;
      if (_outputBits == 0 && codingLine[_codingPos] < columns) {
        _codingPos++;
        _outputBits = codingLine[_codingPos] - codingLine[_codingPos - 1];
      }
    } else {
      bits = 8;
      c = 0;
      do {
        if (_outputBits > bits) {
          c <<= bits;
          if (_codingPos & 1 == 0) {
            c |= 0xFF >> (8 - bits);
          }
          _outputBits -= bits;
          bits = 0;
        } else {
          c <<= _outputBits;
          if (_codingPos & 1 == 0) {
            c |= 0xFF >> (8 - _outputBits);
          }
          bits -= _outputBits;
          _outputBits = 0;
          if (codingLine[_codingPos] < columns) {
            _codingPos++;
            _outputBits = codingLine[_codingPos] - codingLine[_codingPos - 1];
          } else if (bits > 0) {
            c <<= bits;
            bits = 0;
          }
        }
      } while (bits != 0);
    }
    // BlackIs1 is always true for JBIG2 MMR: invert.
    c ^= 0xFF;

    return c;
  }

  // pdf.js ccitt.js _addPixels
  void _addPixels(final int a1Value, final int blackPixels) {
    final codingLine = _codingLine;
    var codingPos = _codingPos;
    var a1 = a1Value;

    if (a1 > codingLine[codingPos]) {
      if (a1 > _columns) {
        a1 = _columns;
      }
      if ((codingPos & 1) ^ blackPixels != 0) {
        codingPos++;
      }
      codingLine[codingPos] = a1;
    }
    _codingPos = codingPos;
  }

  // pdf.js ccitt.js _addPixelsNeg
  void _addPixelsNeg(final int a1Value, final int blackPixels) {
    final codingLine = _codingLine;
    var codingPos = _codingPos;
    var a1 = a1Value;

    if (a1 > codingLine[codingPos]) {
      if (a1 > _columns) {
        a1 = _columns;
      }
      if ((codingPos & 1) ^ blackPixels != 0) {
        codingPos++;
      }
      codingLine[codingPos] = a1;
    } else if (a1 < codingLine[codingPos]) {
      if (a1 < 0) {
        a1 = 0;
      }
      while (codingPos > 0 && a1 < codingLine[codingPos - 1]) {
        codingPos--;
      }
      codingLine[codingPos] = a1;
    }
    _codingPos = codingPos;
  }

  // pdf.js ccitt.js _findTableCode
  // (unused in eoblock mode; kept out to avoid dead code)

  // pdf.js ccitt.js _getTwoDimCode (eoblock branch only)
  int _getTwoDimCode() {
    final code = _lookBits(7);
    if (code == _ccittEOF) {
      return _ccittEOF;
    }
    final pBits = _twoDimTableBits[code];
    if (pBits > 0) {
      _eatBits(pBits);
      return _twoDimTableCodes[code];
    }
    return _ccittEOF;
  }

  // pdf.js ccitt.js _getWhiteCode (eoblock branch only)
  int _getWhiteCode() {
    final code = _lookBits(12);
    if (code == _ccittEOF) {
      return 1;
    }
    final pBits = code >> 5 == 0 ? _whiteTable1Bits[code] : _whiteTable2Bits[code >> 3];
    if (pBits > 0) {
      _eatBits(pBits);
      return code >> 5 == 0 ? _whiteTable1Codes[code] : _whiteTable2Codes[code >> 3];
    }
    _eatBits(1);
    return 1;
  }

  // pdf.js ccitt.js _getBlackCode (eoblock branch only)
  int _getBlackCode() {
    final code = _lookBits(13);
    if (code == _ccittEOF) {
      return 1;
    }
    int bits;
    int value;
    if (code >> 7 == 0) {
      bits = _blackTable1Bits[code];
      value = _blackTable1Codes[code];
    } else if (code >> 9 == 0) {
      bits = _blackTable2Bits[(code >> 1) - 64];
      value = _blackTable2Codes[(code >> 1) - 64];
    } else {
      bits = _blackTable3Bits[code >> 7];
      value = _blackTable3Codes[code >> 7];
    }
    if (bits > 0) {
      _eatBits(bits);
      return value;
    }
    _eatBits(1);
    return 1;
  }

  // pdf.js ccitt.js _lookBits
  int _lookBits(final int n) {
    int c;
    while (_inputBits < n) {
      c = _source.next();
      if (c == -1) {
        if (_inputBits == 0) {
          return _ccittEOF;
        }
        return (_inputBuf << (n - _inputBits)) & (0xFFFF >> (16 - n));
      }
      _inputBuf = (_inputBuf << 8) | c;
      _inputBits += 8;
    }
    return (_inputBuf >> (_inputBits - n)) & (0xFFFF >> (16 - n));
  }

  // pdf.js ccitt.js _eatBits
  void _eatBits(final int n) {
    _inputBits -= n;
    if (_inputBits < 0) {
      _inputBits = 0;
    }
  }
}

/// Decodes an MMR-coded bitmap (`decodeMMRBitmap` in pdf.js's
/// jbig2.js): [endOfBlock] mirrors the `endOfBlock` flag pdf.js passes
/// (true for halftone gray planes, false elsewhere, so EOFB codes
/// terminate each plane).
// pdf.js jbig2.js decodeMMRBitmap
List<Uint8List> decodeMmrBitmap(
  final Uint8List data,
  final int start,
  final int end,
  final int width,
  final int height, {
  final bool endOfBlock = false,
}) {
  if (width <= 0 || height <= 0) {
    throw PdfException('JBIG2 MMR region has invalid dimensions ${width}x$height.');
  }
  final decoder = _CcittFaxDecoder(
    _MmrSource(data, start, end),
    columns: width,
    endOfBlock: endOfBlock,
  );
  final bitmap = List<Uint8List>.generate(height, (_) => Uint8List(width));
  var currentByte = 0;
  var eof = false;

  for (var y = 0; y < height; y++) {
    final row = bitmap[y];
    var shift = -1;
    for (var x = 0; x < width; x++) {
      if (shift < 0) {
        currentByte = decoder.readNextChar();
        if (currentByte == -1) {
          // Set the rest of the bits to zero.
          currentByte = 0;
          eof = true;
        }
        shift = 7;
      }
      row[x] = (currentByte >> shift) & 1;
      shift--;
    }
  }

  if (endOfBlock && !eof) {
    // Read until EOFB has been consumed.
    const lookForEofLimit = 5;
    for (var i = 0; i < lookForEofLimit; i++) {
      if (decoder.readNextChar() == -1) {
        break;
      }
    }
  }

  return bitmap;
}
