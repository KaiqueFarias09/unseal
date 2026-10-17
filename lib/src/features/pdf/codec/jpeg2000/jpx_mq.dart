import 'dart:typed_data';

import 'jpx_exception.dart';

/// The MQC probability-state machine as one flat table of 94 entries
/// (47 states x MPS/LPS sense), transcribed from OpenJPEG's `mqc.c`
/// `mqc_states` at revision 8314119b. Each entry packs
/// `qeval, mps, nmps, nlps`; entries `mps + 2 * prob` are the context
/// seeds selected by `opj_mqc_setstate`.
const List<int> _kMqStates = <int>[
  // qeval, mps, nmps, nlps
  0x5601, 0, 2, 3, //
  0x5601, 1, 3, 2, //
  0x3401, 0, 4, 12, //
  0x3401, 1, 5, 13, //
  0x1801, 0, 6, 18, //
  0x1801, 1, 7, 19, //
  0x0ac1, 0, 8, 24, //
  0x0ac1, 1, 9, 25, //
  0x0521, 0, 10, 58, //
  0x0521, 1, 11, 59, //
  0x0221, 0, 76, 66, //
  0x0221, 1, 77, 67, //
  0x5601, 0, 14, 13, //
  0x5601, 1, 15, 12, //
  0x5401, 0, 16, 28, //
  0x5401, 1, 17, 29, //
  0x4801, 0, 18, 28, //
  0x4801, 1, 19, 29, //
  0x3801, 0, 20, 28, //
  0x3801, 1, 21, 29, //
  0x3001, 0, 22, 34, //
  0x3001, 1, 23, 35, //
  0x2401, 0, 24, 36, //
  0x2401, 1, 25, 37, //
  0x1c01, 0, 26, 40, //
  0x1c01, 1, 27, 41, //
  0x1601, 0, 58, 42, //
  0x1601, 1, 59, 43, //
  0x5601, 0, 30, 29, //
  0x5601, 1, 31, 28, //
  0x5401, 0, 32, 28, //
  0x5401, 1, 33, 29, //
  0x5101, 0, 34, 30, //
  0x5101, 1, 35, 31, //
  0x4801, 0, 36, 32, //
  0x4801, 1, 37, 33, //
  0x3801, 0, 38, 34, //
  0x3801, 1, 39, 35, //
  0x3401, 0, 40, 36, //
  0x3401, 1, 41, 37, //
  0x3001, 0, 42, 38, //
  0x3001, 1, 43, 39, //
  0x2801, 0, 44, 38, //
  0x2801, 1, 45, 39, //
  0x2401, 0, 46, 40, //
  0x2401, 1, 47, 41, //
  0x2201, 0, 48, 42, //
  0x2201, 1, 49, 43, //
  0x1c01, 0, 50, 44, //
  0x1c01, 1, 51, 45, //
  0x1801, 0, 52, 46, //
  0x1801, 1, 53, 47, //
  0x1601, 0, 54, 48, //
  0x1601, 1, 55, 49, //
  0x1401, 0, 56, 50, //
  0x1401, 1, 57, 51, //
  0x1201, 0, 58, 52, //
  0x1201, 1, 59, 53, //
  0x1101, 0, 60, 54, //
  0x1101, 1, 61, 55, //
  0x0ac1, 0, 62, 56, //
  0x0ac1, 1, 63, 57, //
  0x09c1, 0, 64, 58, //
  0x09c1, 1, 65, 59, //
  0x08a1, 0, 66, 60, //
  0x08a1, 1, 67, 61, //
  0x0521, 0, 68, 62, //
  0x0521, 1, 69, 63, //
  0x0441, 0, 70, 64, //
  0x0441, 1, 71, 65, //
  0x02a1, 0, 72, 66, //
  0x02a1, 1, 73, 67, //
  0x0221, 0, 74, 68, //
  0x0221, 1, 75, 69, //
  0x0141, 0, 76, 70, //
  0x0141, 1, 77, 71, //
  0x0111, 0, 78, 72, //
  0x0111, 1, 79, 73, //
  0x0085, 0, 80, 74, //
  0x0085, 1, 81, 75, //
  0x0049, 0, 82, 76, //
  0x0049, 1, 83, 77, //
  0x0025, 0, 84, 78, //
  0x0025, 1, 85, 79, //
  0x0015, 0, 86, 80, //
  0x0015, 1, 87, 81, //
  0x0009, 0, 88, 82, //
  0x0009, 1, 89, 83, //
  0x0005, 0, 90, 84, //
  0x0005, 1, 91, 85, //
  0x0001, 0, 90, 86, //
  0x0001, 1, 91, 87, //
  0x5601, 0, 92, 92, //
  0x5601, 1, 93, 93, //
];

/// Number of contexts tier 1 uses (ZC 0-8, SC 9-13, MAG 14-16, AGG 17,
/// UNI 18).
const int kJpxContextCount = 19;

/// Arithmetic decoder for the JPEG 2000 MQ coder (15444-1 Annex C),
/// following OpenJPEG's software-conventions decoder including the
/// byte-stuffing rule (a queued 0xFF contributes 7 bits) and the
/// reads-past-the-segment-end behavior the reference relies on.
final class JpxMqDecoder {
  /// Starts MQ decoding `length` bytes at `offset` of `data`.
  /// Reads may walk past the segment end into the underlying buffer
  /// exactly like the reference decoder, whose pass counts bound every
  /// loop.
  JpxMqDecoder(this._data, this._offset, this._length, {final Uint16List? contextState})
    : _state = contextState ?? _fresh() {
    if (_offset < 0 || _length < 0 || _offset + _length > _data.length) {
      throw const JpxException('Code-block segment escapes the codestream.');
    }
    _bp = _offset;
    if (_length == 0) {
      _c = 0xFF << 16;
    } else {
      _c = _data[_offset] << 16;
    }
    _byteIn();
    _c <<= 7;
    _ct -= 7;
    _a = 0x8000;
  }

  static Uint16List _fresh() {
    final state = Uint16List(kJpxContextCount);
    state[18] = 92;
    state[17] = 6;
    state[0] = 8;
    return state;
  }

  /// Raw (bypass) decoding of `length` bytes at `offset` of `data`:
  /// no arithmetic initialization, bits consumed MSB-first with the
  /// 0xFF termination rule.
  JpxMqDecoder.raw(this._data, this._offset, this._length, {final Uint16List? contextState})
    : _state = contextState ?? _fresh() {
    if (_offset < 0 || _length < 0 || _offset + _length > _data.length) {
      throw const JpxException('Code-block segment escapes the codestream.');
    }
    _bp = _offset;
    _c = 0;
    _ct = 0;
    _a = 0x8000;
  }

  final Uint8List _data;
  final int _offset;
  final int _length;

  final Uint16List _state;

  int _bp = 0;
  int _c = 0;
  int _a = 0;
  int _ct = 0;

  /// Bytes past the segment answer the synthetic 0xFF 0xFF marker
  /// OpenJPEG plants at `data[len]`, so overreads terminate the
  /// arithmetic decoder instead of consuming the next codeblock.
  int _byteAt(final int index) {
    if (index >= _offset + _length) {
      return 0xFF;
    }
    return index < 0 ? 0 : _data[index];
  }

  /// Restores the standard initial context states: zero-probability
  /// everywhere, with the uniform context at entry 92, the aggregation
  /// context at entry 6 and the ZC base context at entry 8.
  static Uint16List freshContextState() {
    final state = Uint16List(kJpxContextCount);
    state[18] = 92; // uniform
    state[17] = 6; // aggregation
    state[0] = 8; // zc
    return state;
  }

  /// Replaces the context states, implementing the RESET code-block
  /// style between passes.
  void loadContextState(final Uint16List state) {
    _state.setRange(0, kJpxContextCount, state);
  }

  void _byteIn() {
    final next = _byteAt(_bp + 1);
    if (_byteAt(_bp) == 0xFF) {
      if (next > 0x8F) {
        _c += 0xFF00;
        _ct = 8;
      } else {
        _bp++;
        _c += next << 9;
        _ct = 7;
      }
    } else {
      _bp++;
      _c += next << 8;
      _ct = 8;
    }
  }

  void _renorm() {
    do {
      if (_ct == 0) {
        _byteIn();
      }
      _a <<= 1;
      _c <<= 1;
      _ct--;
    } while (_a < 0x8000);
  }

  /// Decodes one decision in context [ctxno].
  int decode(final int ctxno) {
    if (ctxno < 0 || ctxno >= kJpxContextCount) {
      throw const JpxException('JPEG 2000 context number out of range.');
    }
    final entry = _state[ctxno];
    final qeval = _kMqStates[entry * 4];
    final mps = _kMqStates[entry * 4 + 1];
    _a -= qeval;
    int decision;
    if ((_c >> 16) < qeval) {
      // LPS exchange.
      if (_a < qeval) {
        _a = qeval;
        decision = mps;
        _state[ctxno] = _kMqStates[entry * 4 + 2];
      } else {
        _a = qeval;
        decision = 1 - mps;
        _state[ctxno] = _kMqStates[entry * 4 + 3];
      }
      _renorm();
    } else {
      _c -= qeval << 16;
      if ((_a & 0x8000) == 0) {
        // MPS exchange.
        if (_a < qeval) {
          decision = 1 - mps;
          _state[ctxno] = _kMqStates[entry * 4 + 3];
        } else {
          decision = mps;
          _state[ctxno] = _kMqStates[entry * 4 + 2];
        }
        _renorm();
      } else {
        decision = mps;
      }
    }
    return decision;
  }

  /// Decodes one raw (bypass) bit; a 0xFF followed by a byte above
  /// 0x8F is the synthetic end marker that yields zero bits.
  int decodeRaw() {
    if (_ct == 0) {
      final current = _byteAt(_bp);
      if (current == 0xFF) {
        final next = _byteAt(_bp + 1);
        if (next > 0x8F) {
          _c = 0xFF;
          _ct = 8;
        } else {
          _c = next;
          _bp++;
          _ct = 7;
        }
      } else {
        _c = current;
        _bp++;
        _ct = 8;
      }
    }
    _ct--;
    return (_c >> _ct) & 1;
  }
}
