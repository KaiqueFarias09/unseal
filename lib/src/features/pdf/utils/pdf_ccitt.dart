import 'dart:typed_data';

import '../exceptions/pdf_exception.dart';
import '../header/pdf_object.dart';
import 'pdf_ccitt_tables.dart';

/// Safety net 1: absurd `/Columns`/`/Rows` combinations are rejected
/// up front instead of allocating.
const int _maxColumns = 1 << 16;
const int _maxRows = 1 << 20;

/// Safety net 2: the drain loop caps the returned payload size.
const int _maxOutputBytes = 64 << 20;

/// Decodes a CCITTFaxDecode payload (ITU-T T.4/T.6 fax coding) into
/// packed 1-bit rows: most significant bit first, `1` = black, rows
/// padded to whole bytes — the input contract documented on
/// `PdfBitmap` (utils/pdf_bitmap.dart).
///
/// Parameters come from the stream's `/DecodeParms`: `/K` selects
/// the coding (0 = Group 3 1D, < 0 = Group 4, > 0 = Group 3 2D)
/// alongside `/Columns`, `/Rows`, `/BlackIs1`, `/EncodedByteAlign`,
/// `/EndOfLine`, `/EndOfBlock` and `/DamagedRowsBeforeError`. Like
/// pdf.js, the `/BlackIs1` flag and a `/Decode [1 0]` array flip the
/// sample polarity inside the decoder, so callers always receive
/// rows in the default `/Decode [0 1]` convention (0 = black).
///
/// Ground truth: pdf.js v3.11.174 `src/core/ccitt.js`
/// (`CCITTFaxDecoder` + the `CCITTFaxStream.readBlock` drain loop).
/// Port with parity comments pointing at it. pdf.js is Apache-2.0
/// (Copyright 2012 Mozilla Foundation; the original CCITT stream
/// implementation is a JavaScript port of XPDF's, Copyright
/// 1996-2003 Glyph & Cog, LLC, also Apache-2.0).
///
/// Two deliberate deviations from pdf.js, both safety nets so a
/// malformed stream degrades as [PdfException] instead of hanging
/// or exhausting memory (the fuzz discipline):
/// 1. absurd `/Columns`/`/Rows` combinations are rejected up front;
/// 2. the drain loop caps the returned payload size, and a row that
///    consumes no input bits forces EOF (pdf.js spins forever on the
///    same input inside its stream worker).
Uint8List decodeCcittFax(
  final Uint8List data,
  final PdfObject? parm,
  final PdfObject? Function(PdfObject object) resolve,
) {
  var k = 0;
  var columns = 1728;
  var rows = 0;
  var endOfLine = false;
  var encodedByteAlign = false;
  var endOfBlock = true;
  var blackIs1 = false;
  var damagedRowsBeforeError = 0;
  var decodeInverts = false;

  if (parm is PdfDictionary) {
    k = _intValue(resolve(parm['K'] ?? const PdfNull()), fallback: 0);
    columns = _intValue(resolve(parm['Columns'] ?? const PdfNull()), fallback: 1728);
    rows = _intValue(resolve(parm['Rows'] ?? const PdfNull()), fallback: 0);
    endOfLine = _boolValue(resolve(parm['EndOfLine'] ?? const PdfNull()));
    encodedByteAlign = _boolValue(resolve(parm['EncodedByteAlign'] ?? const PdfNull()));
    final endOfBlockValue = resolve(parm['EndOfBlock'] ?? const PdfNull());
    if (endOfBlockValue is PdfBool) endOfBlock = endOfBlockValue.value;
    blackIs1 = _boolValue(resolve(parm['BlackIs1'] ?? const PdfNull()));
    damagedRowsBeforeError = _intValue(
      resolve(parm['DamagedRowsBeforeError'] ?? const PdfNull()),
      fallback: 0,
    );
    final decode = resolve(parm['Decode'] ?? const PdfNull());
    if (decode is PdfArray && decode.items.length >= 2) {
      final low = resolve(decode.items[0]);
      final high = resolve(decode.items[1]);
      if (low is PdfNumber && high is PdfNumber) {
        // `[1 0]` inverts: sample 1 (black) must map to gray 0.
        decodeInverts = !(low.value == 0 && high.value == 1);
      }
    }
  }
  if (columns <= 0) columns = 1728;
  if (columns > _maxColumns || rows > _maxRows) {
    throw PdfException('CCITTFaxDecode geometry out of range: ${columns}x$rows.');
  }

  final decoder = _CcittFaxDecoder(
    data,
    encoding: k,
    eoline: endOfLine,
    byteAlign: encodedByteAlign,
    columns: columns,
    rows: rows,
    eoblock: endOfBlock,
    black: blackIs1 || decodeInverts,
    damagedRowsBeforeError: damagedRowsBeforeError,
  );

  // pdf.js ccitt.js CCITTFaxStream <readBlock>: drain one byte per
  // `readNextChar` until the decoder signals EOF.
  final chunks = BytesBuilder(copy: false);
  while (!decoder.eof) {
    final byte = decoder.readNextChar();
    if (byte == ccittEof) break;
    chunks.addByte(byte);
    if (chunks.length > _maxOutputBytes) {
      throw const PdfException('CCITTFaxDecode output exceeded the size cap.');
    }
  }
  return chunks.toBytes();
}

/// `/K` fallback and `/Columns` coercion: integers pass through,
/// reals truncate, anything else falls back.
int _intValue(final PdfObject? object, {required final int fallback}) {
  final value = object;
  if (value is PdfNumber) return value.value.toInt();
  return fallback;
}

/// `/EndOfLine`-style boolean parameter: only an explicit `true`
/// enables the behavior.
bool _boolValue(final PdfObject? object) => object is PdfBool && object.value;

/// The bit-level CCITT fax decoder: a faithful port of pdf.js
/// v3.11.174 `src/core/ccitt.js` (`CCITTFaxDecoder`).
///
/// The bit reader mirrors pdf.js exactly: at end of input `_lookBits`
/// returns the zero-padded window while buffered bits remain and the
/// EOF sentinel once they drain to zero through `_eatBits`.
final class _CcittFaxDecoder {
  /// Creates a decoder over [source] with pdf.js's option names.
  _CcittFaxDecoder(
    this.source, {
    required this.encoding,
    required this.eoline,
    required this.byteAlign,
    required this.columns,
    required this.rows,
    required this.eoblock,
    required this.black,
    required this.damagedRowsBeforeError,
  }) : codingLine = Uint32List(columns + 1),
       refLine = Uint32List(columns + 2) {
    // pdf.js ccitt.js <constructor>: skip a leading all-zero run and
    // any EOL prefix, then read the first row's 1D/2D tag for K > 0.
    nextLine2D = encoding < 0;
    codingLine[0] = columns;

    int code1;
    while ((code1 = _lookBits(12)) == 0) {
      _eatBits(1);
    }
    if (code1 == 1) {
      _eatBits(12);
    }
    if (encoding > 0) {
      nextLine2D = _lookBits(1) == 0;
      _eatBits(1);
    }
  }

  /// The payload bytes, read MSB-first through [_lookBits].
  final Uint8List source;

  /// `/K`: 0 = Group 3 1D, < 0 = Group 4, > 0 = Group 3 2D.
  final int encoding;

  /// `/EndOfLine`: expect EOL codes between rows.
  final bool eoline;

  /// `/EncodedByteAlign`: re-align to a byte boundary before each row.
  final bool byteAlign;

  /// `/Columns`: row width in pixels.
  final int columns;

  /// `/Rows`: row-count bound carried for pdf.js parity (the drain
  /// loop reads until the stream signals EOF either way).
  final int rows;

  /// `/EndOfBlock`: honor EOFB codes and stop on them.
  final bool eoblock;

  /// `/BlackIs1` + a `/Decode [1 0]` array, folded into one flag
  /// with pdf.js's meaning: when true, `readNextChar` flips its
  /// default sample polarity (0 = black) per byte.
  final bool black;

  /// `/DamagedRowsBeforeError`: pdf.js's decoder accepts this
  /// parameter but its recovery loop is driven by the EOL search
  /// itself; carried for signature parity (a malformed stream still
  /// ends in a [PdfException] from the caller's drain loop).
  final int damagedRowsBeforeError;

  final Uint32List codingLine;
  final Uint32List refLine;

  bool eof = false;
  bool err = false;
  bool rowsDone = false;
  int codingPos = 0;
  int row = 0;
  bool nextLine2D = false;
  int inputBits = 0;
  int inputBuf = 0;
  int outputBits = 0;
  int _sourcePos = 0;

  /// Bits left unread at the start of the current row; a row that
  /// finishes without consuming any forces EOF (see the class doc).
  int _bitsRemainingAtRowStart = -1;

  /// One output byte per call, packed MSB-first with pdf.js's
  /// white-as-1 convention flipped by [black] (`readNextChar`).
  int readNextChar() {
    if (eof) {
      return ccittEof;
    }
    final refLine = this.refLine;
    final codingLine = this.codingLine;
    final columns = this.columns;

    int refPos, blackPixels, bits, i;

    if (outputBits == 0) {
      if (rowsDone) {
        eof = true;
      }
      if (eof) {
        return ccittEof;
      }
      err = false;

      int code1, code2, code3;
      if (nextLine2D) {
        for (i = 0; codingLine[i] < columns; ++i) {
          refLine[i] = codingLine[i];
        }
        refLine[i++] = columns;
        refLine[i] = columns;
        codingLine[0] = 0;
        codingPos = 0;
        refPos = 0;
        blackPixels = 0;

        // Safety net: a valid 2D row consumes at least one changing
        // element per code, so this bound is far above any real row.
        var remainingCodes = 8 * columns + 512;
        while (codingLine[codingPos] < columns) {
          if (--remainingCodes < 0) {
            throw const PdfException('CCITTFaxDecode 2D row failed to terminate.');
          }
          code1 = _getTwoDimCode();
          switch (code1) {
            case twoDimPass:
              _addPixels(refLine[refPos + 1], blackPixels);
              if (refLine[refPos + 1] < columns) {
                refPos += 2;
              }
            case twoDimHoriz:
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
              _addPixels(codingLine[codingPos] + code1, blackPixels);
              if (codingLine[codingPos] < columns) {
                _addPixels(codingLine[codingPos] + code2, blackPixels ^ 1);
              }
              while (refLine[refPos] <= codingLine[codingPos] && refLine[refPos] < columns) {
                refPos += 2;
              }
            case twoDimVertR3:
              _addPixels(refLine[refPos] + 3, blackPixels);
              blackPixels ^= 1;
              if (codingLine[codingPos] < columns) {
                ++refPos;
                while (refLine[refPos] <= codingLine[codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case twoDimVertR2:
              _addPixels(refLine[refPos] + 2, blackPixels);
              blackPixels ^= 1;
              if (codingLine[codingPos] < columns) {
                ++refPos;
                while (refLine[refPos] <= codingLine[codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case twoDimVertR1:
              _addPixels(refLine[refPos] + 1, blackPixels);
              blackPixels ^= 1;
              if (codingLine[codingPos] < columns) {
                ++refPos;
                while (refLine[refPos] <= codingLine[codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case twoDimVert0:
              _addPixels(refLine[refPos], blackPixels);
              blackPixels ^= 1;
              if (codingLine[codingPos] < columns) {
                ++refPos;
                while (refLine[refPos] <= codingLine[codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case twoDimVertL3:
              _addPixelsNeg(refLine[refPos] - 3, blackPixels);
              blackPixels ^= 1;
              if (codingLine[codingPos] < columns) {
                if (refPos > 0) {
                  --refPos;
                } else {
                  ++refPos;
                }
                while (refLine[refPos] <= codingLine[codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case twoDimVertL2:
              _addPixelsNeg(refLine[refPos] - 2, blackPixels);
              blackPixels ^= 1;
              if (codingLine[codingPos] < columns) {
                if (refPos > 0) {
                  --refPos;
                } else {
                  ++refPos;
                }
                while (refLine[refPos] <= codingLine[codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case twoDimVertL1:
              _addPixelsNeg(refLine[refPos] - 1, blackPixels);
              blackPixels ^= 1;
              if (codingLine[codingPos] < columns) {
                if (refPos > 0) {
                  --refPos;
                } else {
                  ++refPos;
                }
                while (refLine[refPos] <= codingLine[codingPos] && refLine[refPos] < columns) {
                  refPos += 2;
                }
              }
            case ccittEof:
              _addPixels(columns, 0);
              eof = true;
            default:
              // pdf.js logs `info("bad 2d code")` and degrades; the
              // malformed-row accounting stays the same.
              _addPixels(columns, 0);
              err = true;
          }
        }
      } else {
        codingLine[0] = 0;
        codingPos = 0;
        blackPixels = 0;
        // Every 1D code returns a run of at least one pixel (the EOF
        // fallback included), so `codingLine` reaches `columns` and
        // the row terminates.
        while (codingLine[codingPos] < columns) {
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
          _addPixels(codingLine[codingPos] + code1, blackPixels);
          blackPixels ^= 1;
        }
      }

      var gotEol = false;

      if (byteAlign) {
        inputBits &= ~7;
      }

      if (!eoblock && row == rows - 1) {
        rowsDone = true;
      } else {
        code1 = _lookBits(12);
        if (eoline) {
          while (code1 != ccittEof && code1 != 1) {
            _eatBits(1);
            code1 = _lookBits(12);
          }
        } else {
          while (code1 == 0) {
            _eatBits(1);
            code1 = _lookBits(12);
          }
        }
        if (code1 == 1) {
          _eatBits(12);
          gotEol = true;
        } else if (code1 == ccittEof) {
          eof = true;
        }
      }

      if (!eof && encoding > 0 && !rowsDone) {
        nextLine2D = _lookBits(1) == 0;
        _eatBits(1);
      }

      if (eoblock && gotEol && byteAlign) {
        code1 = _lookBits(12);
        if (code1 == 1) {
          _eatBits(12);
          if (encoding > 0) {
            _lookBits(1);
            _eatBits(1);
          }
          if (encoding >= 0) {
            for (i = 0; i < 4; ++i) {
              code1 = _lookBits(12);
              // pdf.js logs `bad rtc code` on a mismatch; the run
              // continues exactly the same way.
              _eatBits(12);
              if (encoding > 0) {
                _lookBits(1);
                _eatBits(1);
              }
            }
          }
          eof = true;
        }
      } else if (err && eoline) {
        while (true) {
          code1 = _lookBits(13);
          if (code1 == ccittEof) {
            eof = true;
            return ccittEof;
          }
          if (code1 >> 1 == 1) {
            break;
          }
          _eatBits(1);
        }
        _eatBits(12);
        if (encoding > 0) {
          _eatBits(1);
          nextLine2D = (code1 & 1) == 0;
        }
      }

      outputBits = codingLine[0] > 0 ? codingLine[(codingPos = 0)] : codingLine[(codingPos = 1)];
      row++;

      // Safety net: pdf.js relies on its stream to end; here a row
      // that consumed no input bits would repeat forever on hostile
      // payloads, so force EOF at the first non-progress row.
      final bitsRemaining = (source.length - _sourcePos) * 8 + inputBits;
      if (bitsRemaining == _bitsRemainingAtRowStart) {
        eof = true;
      }
      _bitsRemainingAtRowStart = bitsRemaining;
    }

    int c;
    if (outputBits >= 8) {
      c = (codingPos & 1) != 0 ? 0 : 0xff;
      outputBits -= 8;
      if (outputBits == 0 && codingLine[codingPos] < columns) {
        codingPos++;
        outputBits = codingLine[codingPos] - codingLine[codingPos - 1];
      }
    } else {
      bits = 8;
      c = 0;
      do {
        if (outputBits > bits) {
          c <<= bits;
          if ((codingPos & 1) == 0) {
            c |= 0xff >> (8 - bits);
          }
          outputBits -= bits;
          bits = 0;
        } else {
          c <<= outputBits;
          if ((codingPos & 1) == 0) {
            c |= outputBits == 8 ? 0xff : 0xff >> (8 - outputBits);
          }
          bits -= outputBits;
          outputBits = 0;
          if (codingLine[codingPos] < columns) {
            codingPos++;
            outputBits = codingLine[codingPos] - codingLine[codingPos - 1];
          } else if (bits > 0) {
            c <<= bits;
            bits = 0;
          }
        }
      } while (bits != 0);
    }
    if (black) {
      c ^= 0xff;
    }
    return c;
  }

  // pdf.js ccitt.js <_addPixels>
  void _addPixels(final int a1Raw, final int blackPixels) {
    final codingLine = this.codingLine;
    var codingPos = this.codingPos;
    var a1 = a1Raw;

    if (a1 > codingLine[codingPos]) {
      if (a1 > columns) {
        err = true;
        a1 = columns;
      }
      if (((codingPos & 1) ^ blackPixels) != 0) {
        ++codingPos;
      }

      codingLine[codingPos] = a1;
    }
    this.codingPos = codingPos;
  }

  // pdf.js ccitt.js <_addPixelsNeg>
  void _addPixelsNeg(final int a1Raw, final int blackPixels) {
    final codingLine = this.codingLine;
    var codingPos = this.codingPos;
    var a1 = a1Raw;

    if (a1 > codingLine[codingPos]) {
      if (a1 > columns) {
        err = true;
        a1 = columns;
      }
      if (((codingPos & 1) ^ blackPixels) != 0) {
        ++codingPos;
      }

      codingLine[codingPos] = a1;
    } else if (a1 < codingLine[codingPos]) {
      if (a1 < 0) {
        err = true;
        a1 = 0;
      }
      while (codingPos > 0 && a1 < codingLine[codingPos - 1]) {
        --codingPos;
      }
      codingLine[codingPos] = a1;
    }

    this.codingPos = codingPos;
  }

  /// Run length of a failed table lookup: pdf.js's `_findTableCode`
  /// returns a `found`/`value` pair where a miss keeps decoding going
  /// with a one-pixel run.
  static const int _tableMiss = 0;

  // pdf.js ccitt.js <_findTableCode>: returns (found, runLength).
  (bool, int) _findTableCode(
    final int start,
    final int end,
    final List<List<int>> table, [
    final int limit = 0,
  ]) {
    for (var i = start; i <= end; ++i) {
      var code = _lookBits(i);
      if (code == ccittEof) {
        return (true, 1);
      }
      if (i < end) {
        code <<= end - i;
      }
      if (limit == 0 || code >= limit) {
        final entry = table[code - limit];
        if (entry[0] == i) {
          _eatBits(i);
          return (true, entry[1]);
        }
      }
    }
    return (false, _tableMiss);
  }

  // pdf.js ccitt.js <_getTwoDimCode>
  int _getTwoDimCode() {
    int code;
    if (eoblock) {
      code = _lookBits(7);
      if (code >= 0 && code < twoDimTable.length) {
        final entry = twoDimTable[code];
        if (entry[0] > 0) {
          _eatBits(entry[0]);
          return entry[1];
        }
      }
    } else {
      final (found, value) = _findTableCode(1, 7, twoDimTable);
      if (found) {
        return value;
      }
    }
    return ccittEof;
  }

  // pdf.js ccitt.js <_getWhiteCode>
  int _getWhiteCode() {
    int code;
    if (eoblock) {
      code = _lookBits(12);
      if (code == ccittEof) {
        return 1;
      }

      final entry = code >> 5 == 0 ? whiteTable1[code] : whiteTable2[code >> 3];

      if (entry[0] > 0) {
        _eatBits(entry[0]);
        return entry[1];
      }
    } else {
      var (found, value) = _findTableCode(1, 9, whiteTable2);
      if (found) {
        return value;
      }

      (found, value) = _findTableCode(11, 12, whiteTable1);
      if (found) {
        return value;
      }
    }
    _eatBits(1);
    return 1;
  }

  // pdf.js ccitt.js <_getBlackCode>
  int _getBlackCode() {
    int code;
    if (eoblock) {
      code = _lookBits(13);
      if (code == ccittEof) {
        return 1;
      }
      List<int> entry;
      if (code >> 7 == 0) {
        entry = blackTable1[code];
      } else if (code >> 9 == 0 && code >> 7 != 0) {
        entry = blackTable2[(code >> 1) - 64];
      } else {
        entry = blackTable3[code >> 7];
      }

      if (entry[0] > 0) {
        _eatBits(entry[0]);
        return entry[1];
      }
    } else {
      var (found, value) = _findTableCode(2, 6, blackTable3);
      if (found) {
        return value;
      }

      (found, value) = _findTableCode(7, 12, blackTable2, 64);
      if (found) {
        return value;
      }

      (found, value) = _findTableCode(10, 13, blackTable1);
      if (found) {
        return value;
      }
    }
    _eatBits(1);
    return 1;
  }

  /// Peeks [n] bits without consuming them, MSB-first over [source]
  /// (pdf.js ccitt.js <_lookBits>): the EOF sentinel once the input
  /// is exhausted with no buffered bits, the zero-padded window while
  /// buffered bits remain. pdf.js only fires the sentinel at exactly
  /// zero and spins forever if `_eatBits` drives the counter negative
  /// on hostile input; firing it at `<= 0` is the one deliberate
  /// reader deviation and keeps every path terminating.
  int _lookBits(final int n) {
    while (inputBits < n) {
      if (_sourcePos >= source.length) {
        if (inputBits <= 0) {
          return ccittEof;
        }
        return (inputBuf << (n - inputBits)) & (0xffff >> (16 - n));
      }
      inputBuf = (inputBuf << 8) | source[_sourcePos++];
      inputBits += 8;
    }
    return (inputBuf >> (inputBits - n)) & (0xffff >> (16 - n));
  }

  // pdf.js ccitt.js <_eatBits>
  void _eatBits(final int n) {
    inputBits -= n;
  }
}
