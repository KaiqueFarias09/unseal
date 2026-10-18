import 'dart:typed_data';

import '../../foundation/images/ccitt/ccitt_tables.dart';
import 'tiff_exception.dart';

/// The strict, row-oriented CCITT fax decoder for TIFF pages.
///
/// TIFF declares the exact width and height of every strip, so this
/// decoder owns its synchronization instead of reusing the stream-
/// oriented (PDF) fax decoder: rows are decoded with the leading-zero
/// reference-line convention of ITU-T T.6, the declared row count is
/// authoritative, and a malformed code fails typed. The pdf.js-derived
/// tables in `foundation/images/ccitt/` are reused unchanged — they are
/// the proven T.4/T.6 code data.
///
/// The output is `rows` packed rows of `ceil(columns / 8)` bytes, most
/// significant bit first, where a set bit means BLACK (ink). Callers
/// map bits to display levels through the photometric tag.
class TiffCcittMode {
  const TiffCcittMode._(this.name, this.is2dCapable);

  /// Group 4 (T.6 two-dimensional coding, no end-of-line codes).
  static const TiffCcittMode g4 = TiffCcittMode._('g4', true);

  /// Group 3 one-dimensional coding (optional end-of-line codes).
  static const TiffCcittMode g3_1d = TiffCcittMode._('g3-1d', false);

  /// Group 3 two-dimensional coding (end-of-line code + 1-bit tag).
  static const TiffCcittMode g3_2d = TiffCcittMode._('g3-2d', true);

  /// Diagnostic name for failure messages.
  final String name;

  /// Whether this mode can decode 2D rows.
  final bool is2dCapable;
}

/// Decodes one CCITT strip to packed ink rows.
///
/// [byteAlignedRows] starts every row on a byte boundary (TIFF
/// compression 2 and Group 3 fill-bit files); [endOfLine] requires the
/// 000000000001 end-of-line code before every row (Group 3); for
/// [TiffCcittMode.g3_2d] the 1-bit line tag after each end-of-line
/// code selects that row's coding. A strip that ends before [rows]
/// rows are decoded, or whose codes leave a row short, throws
/// [TiffException].
Uint8List decodeTiffCcittStrip(
  final Uint8List encoded, {
  required final TiffCcittMode mode,
  required final int columns,
  required final int rows,
  required final bool byteAlignedRows,
  required final bool endOfLine,
}) {
  final reader = _CcittBitReader(encoded);
  if (mode == TiffCcittMode.g4) {
    // Skip any leading all-zero fill before the first row's codes.
    while (reader.hasBits && reader.lookBits(12) == 0) {
      reader.eatBits(1);
    }
  }
  final rowBytes = (columns + 7) ~/ 8;
  final out = Uint8List(rowBytes * rows);
  // The reference line: the previous row's run lengths, white first.
  // The initial reference is libtiff's imaginary all-white line
  // (a full-width white run, then the zero terminator).
  var refRuns = <int>[columns, 0];
  for (var row = 0; row < rows; row++) {
    if (endOfLine) {
      _consumeEndOfLine(reader, row);
    } else if (byteAlignedRows) {
      reader.alignToByte();
    }
    var line2D = mode == TiffCcittMode.g4;
    if (mode == TiffCcittMode.g3_2d) {
      line2D = reader.lookBits(1) == 0;
      reader.eatBits(1);
    }
    final runs = line2D
        ? _decode2dRow(reader, columns, row, refRuns)
        : _decode1dRow(reader, columns, row);
    _emitInkRuns(out, row * rowBytes, runs, columns);
    refRuns = runs..add(0);
  }
  return out;
}

/// Scans the G3 fill-bit zeros and consumes the end-of-line code.
void _consumeEndOfLine(final _CcittBitReader reader, final int row) {
  var scanned = 0;
  while (reader.hasBits && scanned < 64) {
    if (reader.lookBits(12) == 1) {
      reader.eatBits(12);
      return;
    }
    reader.eatBits(1);
    scanned++;
  }
  throw TiffException('TIFF CCITT row $row is missing its end-of-line code.');
}

/// One-dimensional coding: alternating white and black runs, the first
/// white. Returns the row's run lengths.
List<int> _decode1dRow(final _CcittBitReader reader, final int columns, final int row) {
  final runs = <int>[];
  var position = 0;
  var isBlack = false;
  var guard = 8 * columns + 512;
  while (position < columns) {
    if (--guard < 0) {
      throw TiffException('TIFF CCITT row $row failed to terminate.');
    }
    final run = isBlack ? _readBlackRun(reader, row) : _readWhiteRun(reader, row);
    position += run;
    if (position > columns) position = columns;
    runs.add(run);
    isBlack = !isBlack;
  }
  return runs;
}

/// Two-dimensional coding (T.6, and T.4 2D with the line tag already
/// consumed by the caller).
///
/// [refRuns] holds the reference row's run lengths, white run first,
/// with libtiff's trailing zero. The walk maintains `a0` (the coding
/// position), `b1` (the next reference change position) and `pb` (the
/// index of the reference run following b1) exactly as libtiff's
/// EXPAND2D does — including the backward `pb` step a negative
/// vertical mode requires.
List<int> _decode2dRow(
  final _CcittBitReader reader,
  final int columns,
  final int row,
  final List<int> refRuns,
) {
  final runs = <int>[];
  var runsEmitted = 0;
  var runLength = 0;
  var a0 = 0;
  var pbIndex = 0;
  var b1 = refRuns.isEmpty ? columns : refRuns[0];
  if (pbIndex < refRuns.length) pbIndex = 1;
  var guard = 8 * columns + 512;

  // libtiff CHECK_b1: after this row's first run, skip reference run
  // pairs while b1 has not passed a0.
  void checkB1() {
    if (runsEmitted != 0) {
      while (b1 <= a0 && b1 < columns && pbIndex < refRuns.length) {
        b1 += _refRun(refRuns, pbIndex) + _refRun(refRuns, pbIndex + 1);
        pbIndex += 2;
      }
    }
  }

  // libtiff SETVALUE: the stored run length is the accumulated makeup
  // run plus the terminating code; a0 advances by the run.
  void setValue(final int terminatingCode) {
    runs.add(runLength + terminatingCode);
    a0 += terminatingCode;
    runLength = 0;
    runsEmitted++;
  }

  int refAt(final int index) => _refRun(refRuns, index);

  while (a0 < columns) {
    if (--guard < 0) {
      throw TiffException('TIFF CCITT row $row failed to terminate.');
    }
    final mode = _read2dMode(reader, row);
    switch (mode) {
      case Ccitt2dMode.pass:
        checkB1();
        b1 += refAt(pbIndex);
        runLength += b1 - a0;
        a0 = b1;
        b1 += refAt(pbIndex + 1);
        pbIndex += 2;
      case Ccitt2dMode.horizontal:
        checkB1();
        // The run order follows the emitted-runs parity: white first on
        // an even count, black first on an odd count.
        final blackFirst = runsEmitted.isOdd;
        for (var half = 0; half < 2; half++) {
          final readBlack = blackFirst ? half == 0 : half == 1;
          // The run readers return the full run (makeups plus the
          // terminating code).
          setValue(readBlack ? _readBlackRun(reader, row) : _readWhiteRun(reader, row));
        }
      case Ccitt2dMode.vert0:
        checkB1();
        setValue(b1 - a0);
        b1 += refAt(pbIndex);
        pbIndex++;
      case Ccitt2dMode.vertR1:
      case Ccitt2dMode.vertR2:
      case Ccitt2dMode.vertR3:
        final delta = switch (mode) {
          Ccitt2dMode.vertR1 => 1,
          Ccitt2dMode.vertR2 => 2,
          Ccitt2dMode.vertR3 => 3,
          _ => 0,
        };
        checkB1();
        setValue(b1 - a0 + delta);
        b1 += refAt(pbIndex);
        pbIndex++;
      case Ccitt2dMode.vertL1:
      case Ccitt2dMode.vertL2:
      case Ccitt2dMode.vertL3:
        final delta = switch (mode) {
          Ccitt2dMode.vertL1 => 1,
          Ccitt2dMode.vertL2 => 2,
          Ccitt2dMode.vertL3 => 3,
          _ => 0,
        };
        checkB1();
        if (b1 < a0 + delta) {
          throw TiffException('TIFF CCITT row $row has a negative vertical mode before a0.');
        }
        setValue(b1 - a0 - delta);
        if (pbIndex > 0) {
          b1 -= refAt(pbIndex - 1);
          pbIndex--;
        }
    }
  }
  return runs;
}

/// The reference run length at [index]; past the list, zero (the
/// imaginary trailing run libtiff appends).
int _refRun(final List<int> refRuns, final int index) =>
    index < refRuns.length ? refRuns[index] : 0;

/// Paints the ink runs of one row from its run lengths (white, black,
/// white, ...).
void _emitInkRuns(final Uint8List out, final int rowBase, final List<int> runs, final int columns) {
  var position = 0;
  for (var index = 0; index < runs.length && position < columns; index++) {
    final end = (position + runs[index]).clamp(0, columns);
    if (index.isOdd) {
      _setBits(out, rowBase, position, end);
    }
    position = end;
  }
}

/// Sets ink bits for [start]..[end) in one packed row.
void _setBits(final Uint8List out, final int rowBase, final int start, final int end) {
  for (var x = start; x < end; x++) {
    out[rowBase + (x >> 3)] |= 0x80 >> (x & 7);
  }
}

/// The T.6 two-dimensional vertical/pass/horizontal modes.
enum Ccitt2dMode {
  /// Skip to b2 of the reference line.
  pass,

  /// Code two runs explicitly.
  horizontal,

  /// Vertical mode, 0-pixel shift.
  vert0,

  /// Vertical mode, one pixel right.
  vertR1,

  /// Vertical mode, one pixel left.
  vertL1,

  /// Vertical mode, two pixels right.
  vertR2,

  /// Vertical mode, two pixels left.
  vertL2,

  /// Vertical mode, three pixels right.
  vertR3,

  /// Vertical mode, three pixels left.
  vertL3,
}

Ccitt2dMode _read2dMode(final _CcittBitReader reader, final int row) {
  final window = reader.lookBits(7);
  if (window >= 0 && window < twoDimTable.length) {
    final entry = twoDimTable[window];
    if (entry[0] > 0) {
      reader.eatBits(entry[0]);
      return switch (entry[1]) {
        0 => Ccitt2dMode.pass,
        1 => Ccitt2dMode.horizontal,
        2 => Ccitt2dMode.vert0,
        3 => Ccitt2dMode.vertR1,
        4 => Ccitt2dMode.vertL1,
        5 => Ccitt2dMode.vertR2,
        6 => Ccitt2dMode.vertL2,
        7 => Ccitt2dMode.vertR3,
        8 => Ccitt2dMode.vertL3,
        _ => throw TiffException('TIFF CCITT row $row has an unknown 2D mode.'),
      };
    }
  }
  throw TiffException('TIFF CCITT row $row has an invalid 2D code.');
}

int _readWhiteRun(final _CcittBitReader reader, final int row) {
  var total = 0;
  while (true) {
    final window = reader.lookBits(12);
    final entry = window >> 5 == 0 ? whiteTable1[window] : whiteTable2[window >> 3];
    if (entry[0] <= 0) {
      throw TiffException('TIFF CCITT row $row has an invalid white run code.');
    }
    reader.eatBits(entry[0]);
    total += entry[1];
    if (entry[1] < 64) return total;
  }
}

int _readBlackRun(final _CcittBitReader reader, final int row) {
  var total = 0;
  while (true) {
    final window = reader.lookBits(13);
    List<int> entry;
    if (window >> 7 == 0) {
      entry = blackTable1[window];
    } else if (window >> 9 == 0 && window >> 7 != 0) {
      entry = blackTable2[(window >> 1) - 64];
    } else {
      entry = blackTable3[window >> 7];
    }
    if (entry[0] <= 0) {
      throw TiffException('TIFF CCITT row $row has an invalid black run code.');
    }
    reader.eatBits(entry[0]);
    total += entry[1];
    if (entry[1] < 64) return total;
  }
}

/// MSB-first bit reader over the strip bytes.
final class _CcittBitReader {
  _CcittBitReader(this.source);

  final Uint8List source;
  int _position = 0;
  int _bufferedBits = 0;
  int _buffer = 0;
  var _exhausted = false;

  bool get hasBits => !_exhausted || _bufferedBits > 0;

  /// Skips to the next byte boundary: only the unread bits of the byte
  /// currently being consumed are dropped, never the whole bytes the
  /// 12/13-bit lookahead has already buffered (libtiff's
  /// `ClrBits(BitsAvail % 8)` at the end of a modified Huffman row).
  void alignToByte() => eatBits(_bufferedBits & 7);

  /// The next [count] bits, most significant first; exhausted input
  /// contributes zero bits (row termination guards catch truncation).
  int lookBits(final int count) {
    while (_bufferedBits < count && !_exhausted) {
      if (_position >= source.length) {
        _exhausted = true;
        break;
      }
      _buffer = (_buffer << 8) | source[_position++];
      _bufferedBits += 8;
    }
    if (_bufferedBits < count) {
      return (_buffer << (count - _bufferedBits)) & ((1 << count) - 1);
    }
    return (_buffer >> (_bufferedBits - count)) & ((1 << count) - 1);
  }

  void eatBits(final int count) {
    _bufferedBits -= count;
    if (_bufferedBits < 0) _bufferedBits = 0;
    _buffer &= (1 << _bufferedBits) - 1;
  }
}
