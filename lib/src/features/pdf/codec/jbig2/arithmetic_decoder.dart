/// Arithmetic (MQ) decoder for JBIG2 region coding.
///
/// Ported from pdf.js v3.11.174 `src/core/arithmetic_decoder.js`
/// (`ArithmeticDecoder`), Apache-2.0; parity comments point at the
/// source blocks. Implements the QM-coder decode procedure of
/// JPEG 2000 Part I Annex C.3, as pdf.js applies it to JBIG2
/// streams.
library;

import 'dart:typed_data';

import '../../exceptions/pdf_exception.dart';

/// Table C-2 (`QeTable` in pdf.js): index -> (qe, nmps, nlps, switch).
// pdf.js arithmetic_decoder.js QeTable
const List<int> _qeValues = <int>[
  0x5601, 0x3401, 0x1801, 0x0AC1, 0x0521, 0x0221, 0x5601, 0x5401, //
  0x4801, 0x3801, 0x3001, 0x2401, 0x1C01, 0x1601, 0x5601, 0x5401, //
  0x5101, 0x4801, 0x3801, 0x3401, 0x3001, 0x2801, 0x2401, 0x2201, //
  0x1C01, 0x1801, 0x1601, 0x1401, 0x1201, 0x1101, 0x0AC1, 0x09C1, //
  0x08A1, 0x0521, 0x0441, 0x02A1, 0x0221, 0x0141, 0x0111, 0x0085, //
  0x0049, 0x0025, 0x0015, 0x0009, 0x0005, 0x0001, 0x5601, //
];
const List<int> _nmps = <int>[
  1, 2, 3, 4, 5, 38, 7, 8, 9, 10, 11, 12, 13, 29, 15, 16, 17, 18, 19, 20, //
  21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, //
  39, 40, 41, 42, 43, 44, 45, 45, 46,
];
const List<int> _nlps = <int>[
  1, 6, 9, 12, 29, 33, 6, 14, 14, 14, 17, 18, 20, 21, 14, 14, 15, 16, 17, //
  18, 19, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, //
  35, 36, 37, 38, 39, 40, 41, 42, 43, 46,
];
// switchFlag of every entry, entry 46 last.
const List<int> _switchFlag = <int>[
  1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

/// The MQ arithmetic decoder (`ArithmeticDecoder` in pdf.js).
final class Jbig2ArithmeticDecoder {
  /// C.3.5 Initialisation of the decoder (INITDEC).
  Jbig2ArithmeticDecoder(this._data, this._bp, this._dataEnd) {
    _chigh = _bp < _data.length ? _data[_bp] : 0;
    _byteIn();
    _chigh = ((_chigh << 7) & 0xFFFF) | ((_clow >> 9) & 0x7F);
    _clow = (_clow << 7) & 0xFFFF;
    _ct -= 7;
    _a = 0x8000;
  }

  final Uint8List _data;
  int _bp;
  final int _dataEnd;

  int _chigh = 0;
  int _clow = 0;
  int _ct = 0;
  int _a = 0;

  /// Total decisions this instance may make. Legitimate streams ride
  /// the 0xFF flush state for thousands of decisions per input byte on
  /// skewed contexts, so the budget is a generous multiple of the data
  /// size; a truncated or hostile stream that would otherwise spin an
  /// out-of-band-terminated caller loop forever hits it and fails.
  late final int _decisionBudget = _data.length < 16 ? 1 << 16 : 4096 * _data.length;
  int _decisions = 0;

  /// C.3.4 Compressed data input (BYTEIN).
  // pdf.js arithmetic_decoder.js byteIn
  void _byteIn() {
    // Reads past the data end act as the standard's 0xFF stuffing, so
    // truncated data degrades into an all-MPS stream instead of a raw
    // out-of-range error.
    final byte = _bp < _data.length ? _data[_bp] : 0xFF;
    final next = _bp + 1 < _data.length ? _data[_bp + 1] : 0x00;
    if (byte == 0xFF) {
      if (next > 0x8F) {
        _clow += 0xFF00;
        _ct = 8;
      } else {
        _bp++;
        _clow += (_bp < _data.length ? _data[_bp] : 0) << 9;
        _ct = 7;
      }
    } else {
      _bp++;
      // The segment window bounds the real data (pdf.js's dataEnd);
      // bytes past it — or past a truncated payload — stuff 0xFF.
      _clow += (_bp < _dataEnd && _bp < _data.length ? _data[_bp] : 0xFF) << 8;
      _ct = 8;
    }
    if (_clow > 0xFFFF) {
      _chigh += _clow >> 16;
      _clow &= 0xFFFF;
    }
  }

  /// C.3.2 Decoding a decision (DECODE).
  ///
  /// [contexts] packs each context into one byte: the highest 7 bits
  /// carry the index, the lowest bit the MPS. [pos] selects the entry.
  // pdf.js arithmetic_decoder.js readBit
  int readBit(final Uint8List contexts, final int pos) {
    if (++_decisions > _decisionBudget) {
      throw const PdfException('JBIG2 error: arithmetic decode budget exhausted.');
    }
    var cxIndex = contexts[pos] >> 1;
    var cxMps = contexts[pos] & 1;
    final qe = _qeValues[cxIndex];
    var d = 0;
    var a = _a - qe;

    if (_chigh < qe) {
      // exchangeLps
      if (a < qe) {
        a = qe;
        d = cxMps;
        cxIndex = _nmps[cxIndex];
      } else {
        a = qe;
        d = 1 ^ cxMps;
        if (_switchFlag[cxIndex] == 1) {
          cxMps = d;
        }
        cxIndex = _nlps[cxIndex];
      }
    } else {
      _chigh -= qe;
      if ((a & 0x8000) != 0) {
        _a = a;
        return cxMps;
      }
      // exchangeMps
      if (a < qe) {
        d = 1 ^ cxMps;
        if (_switchFlag[cxIndex] == 1) {
          cxMps = d;
        }
        cxIndex = _nlps[cxIndex];
      } else {
        d = cxMps;
        cxIndex = _nmps[cxIndex];
      }
    }

    // C.3.3 renormD
    do {
      if (_ct == 0) {
        _byteIn();
      }
      a <<= 1;
      _chigh = ((_chigh << 1) & 0xFFFF) | ((_clow >> 15) & 1);
      _clow = (_clow << 1) & 0xFFFF;
      _ct--;
    } while ((a & 0x8000) == 0);
    _a = a;

    contexts[pos] = (cxIndex << 1) | cxMps;
    return d;
  }
}
