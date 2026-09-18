/// MMR (Group 4 fax) coding as JBIG2 applies it: the same T.6
/// algorithm as PDF's CCITTFaxDecode with `/K -1`, reading from a
/// byte window of the JBIG2 segment payload.
///
/// Ported from pdf.js v3.11.174 `src/core/ccitt.js`
/// (`CCITTFaxDecoder`, itself a port of XPDF's implementation,
/// Apache-2.0), narrowed to what `decodeMMRBitmap` in
/// `src/core/jbig2.js` uses: `BlackIs1: true`, `K = -1`, fixed
/// columns/rows and end-of-block mode only. It shares the canonical
/// CCITT lookup tables with the PDF stream decoder so fixes to the
/// T.6 codes cannot drift between the two paths.
library;

import 'dart:typed_data';

import '../../exceptions/pdf_exception.dart';
import '../ccitt/ccitt_tables.dart';

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
  bool _nextLine2D = true;
  int _inputBits = 0;
  int _inputBuf = 0;
  int _outputBits = 0;

  bool get eof => _eof;

  /// Reads the next packed output byte, or -1 at end of data.
  // pdf.js ccitt.js readNextChar
  int readNextChar() {
    if (_eof) return -1;
    if (_outputBits == 0 && !_startNextRow()) return -1;

    return _readOutputByte();
  }

  bool _startNextRow() {
    if (_eof) return false;
    if (_nextLine2D) {
      _decodeTwoDimensionalRow();
    } else {
      _decodeOneDimensionalRow();
    }
    final gotEol = _consumeRowTerminator();
    if (_eoblock && gotEol) _consumeEndOfBlock();
    _outputBits = _codingLine[0] > 0
        ? _codingLine[(_codingPos = 0)]
        : _codingLine[(_codingPos = 1)];

    return true;
  }

  void _decodeTwoDimensionalRow() {
    var i = 0;
    while (_codingLine[i] < _columns) {
      _refLine[i] = _codingLine[i];
      i++;
    }
    _refLine[i++] = _columns;
    _refLine[i] = _columns;
    _codingLine[0] = 0;
    _codingPos = 0;
    var refPos = 0;
    var blackPixels = 0;
    while (_codingLine[_codingPos] < _columns) {
      final result = _applyTwoDimensionalCode(_getTwoDimCode(), refPos, blackPixels);
      refPos = result.$1;
      blackPixels = result.$2;
    }
  }

  (int, int) _applyTwoDimensionalCode(final int code, int refPos, int blackPixels) {
    switch (code) {
      case twoDimPass:
        _addPixels(_refLine[refPos + 1], blackPixels);
        if (_refLine[refPos + 1] < _columns) refPos += 2;
      case twoDimHoriz:
        final runs = _readHorizontalRuns(blackPixels);
        _addPixels(_codingLine[_codingPos] + runs.$1, blackPixels);
        if (_codingLine[_codingPos] < _columns) {
          _addPixels(_codingLine[_codingPos] + runs.$2, blackPixels ^ 1);
        }
        while (_refLine[refPos] <= _codingLine[_codingPos] && _refLine[refPos] < _columns) {
          refPos += 2;
        }
      case twoDimVertR3:
        _addPixels(_refLine[refPos] + 3, blackPixels);
        blackPixels ^= 1;
        if (_codingLine[_codingPos] < _columns) {
          refPos = _advanceReference(refPos);
        }
      case twoDimVertR2:
        _addPixels(_refLine[refPos] + 2, blackPixels);
        blackPixels ^= 1;
        if (_codingLine[_codingPos] < _columns) {
          refPos = _advanceReference(refPos);
        }
      case twoDimVertR1:
        _addPixels(_refLine[refPos] + 1, blackPixels);
        blackPixels ^= 1;
        if (_codingLine[_codingPos] < _columns) {
          refPos = _advanceReference(refPos);
        }
      case twoDimVert0:
        _addPixels(_refLine[refPos], blackPixels);
        blackPixels ^= 1;
        if (_codingLine[_codingPos] < _columns) {
          refPos = _advanceReference(refPos);
        }
      case twoDimVertL3:
        _addPixelsNeg(_refLine[refPos] - 3, blackPixels);
        blackPixels ^= 1;
        if (_codingLine[_codingPos] < _columns) refPos = _advanceNegativeReference(refPos);
      case twoDimVertL2:
        _addPixelsNeg(_refLine[refPos] - 2, blackPixels);
        blackPixels ^= 1;
        if (_codingLine[_codingPos] < _columns) refPos = _advanceNegativeReference(refPos);
      case twoDimVertL1:
        _addPixelsNeg(_refLine[refPos] - 1, blackPixels);
        blackPixels ^= 1;
        if (_codingLine[_codingPos] < _columns) refPos = _advanceNegativeReference(refPos);
      case ccittEof:
        _addPixels(_columns, 0);
        _eof = true;
      default:
        _addPixels(_columns, 0);
    }

    return (refPos, blackPixels);
  }

  (int, int) _readHorizontalRuns(final int blackPixels) {
    var first = 0;
    var second = 0;
    var run = 0;
    if (blackPixels != 0) {
      do {
        first += run = _getBlackCode();
      } while (run >= 64);
      do {
        second += run = _getWhiteCode();
      } while (run >= 64);
    } else {
      do {
        first += run = _getWhiteCode();
      } while (run >= 64);
      do {
        second += run = _getBlackCode();
      } while (run >= 64);
    }

    return (first, second);
  }

  int _advanceReference(int refPos) {
    refPos++;
    while (_refLine[refPos] <= _codingLine[_codingPos] && _refLine[refPos] < _columns) {
      refPos += 2;
    }

    return refPos;
  }

  int _advanceNegativeReference(int refPos) {
    refPos = refPos > 0 ? refPos - 1 : refPos + 1;
    while (_refLine[refPos] <= _codingLine[_codingPos] && _refLine[refPos] < _columns) {
      refPos += 2;
    }

    return refPos;
  }

  void _decodeOneDimensionalRow() {
    _codingLine[0] = 0;
    _codingPos = 0;
    var blackPixels = 0;
    while (_codingLine[_codingPos] < _columns) {
      var run = 0;
      var code = 0;
      if (blackPixels != 0) {
        do {
          run += code = _getBlackCode();
        } while (code >= 64);
      } else {
        do {
          run += code = _getWhiteCode();
        } while (code >= 64);
      }
      _addPixels(_codingLine[_codingPos] + run, blackPixels);
      blackPixels ^= 1;
    }
  }

  bool _consumeRowTerminator() {
    var code = _lookBits(12);
    while (code == 0) {
      _eatBits(1);
      code = _lookBits(12);
    }
    if (code == 1) {
      _eatBits(12);

      return true;
    }
    if (code == ccittEof) _eof = true;

    return false;
  }

  void _consumeEndOfBlock() {
    final code = _lookBits(12);
    if (code != 1) return;
    _eatBits(12);
    _eof = true;
  }

  int _readOutputByte() {
    int c;
    if (_outputBits >= 8) {
      c = _codingPos & 1 != 0 ? 0 : 0xFF;
      _outputBits -= 8;
      if (_outputBits == 0 && _codingLine[_codingPos] < _columns) {
        _codingPos++;
        _outputBits = _codingLine[_codingPos] - _codingLine[_codingPos - 1];
      }
    } else {
      c = _readPartialOutputByte();
    }
    // BlackIs1 is always true for JBIG2 MMR: invert.
    c ^= 0xFF;

    return c;
  }

  int _readPartialOutputByte() {
    var bits = 8;
    var c = 0;
    do {
      if (_outputBits > bits) {
        c <<= bits;
        if (_codingPos & 1 == 0) c |= 0xFF >> (8 - bits);
        _outputBits -= bits;
        bits = 0;
      } else {
        c <<= _outputBits;
        if (_codingPos & 1 == 0) c |= 0xFF >> (8 - _outputBits);
        bits -= _outputBits;
        _outputBits = 0;
        if (_codingLine[_codingPos] < _columns) {
          _codingPos++;
          _outputBits = _codingLine[_codingPos] - _codingLine[_codingPos - 1];
        } else if (bits > 0) {
          c <<= bits;
          bits = 0;
        }
      }
    } while (bits != 0);

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
    if (code == ccittEof) {
      return ccittEof;
    }

    final entry = twoDimTable[code];
    if (entry[0] > 0) {
      _eatBits(entry[0]);
      return entry[1];
    }

    return ccittEof;
  }

  // pdf.js ccitt.js _getWhiteCode (eoblock branch only)
  int _getWhiteCode() {
    final code = _lookBits(12);
    if (code == ccittEof) {
      return 1;
    }

    final entry = code >> 5 == 0 ? whiteTable1[code] : whiteTable2[code >> 3];
    if (entry[0] > 0) {
      _eatBits(entry[0]);
      return entry[1];
    }
    _eatBits(1);

    return 1;
  }

  // pdf.js ccitt.js _getBlackCode (eoblock branch only)
  int _getBlackCode() {
    final code = _lookBits(13);
    if (code == ccittEof) {
      return 1;
    }

    late final List<int> entry;
    if (code >> 7 == 0) {
      entry = blackTable1[code];
    } else if (code >> 9 == 0) {
      entry = blackTable2[(code >> 1) - 64];
    } else {
      entry = blackTable3[code >> 7];
    }
    if (entry[0] > 0) {
      _eatBits(entry[0]);
      return entry[1];
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
          return ccittEof;
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
