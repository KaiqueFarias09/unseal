import 'dart:typed_data';

import 'djvu_exception.dart';
import 'zp_tables.dart';

/// Shared adaptive ZP arithmetic decoder used by DjVu image codecs.
final class DjvuZpDecoder {
  /// Creates a bounded decoder for one DjVu ZP arithmetic stream.
  ///
  /// Set [allowShortPayload] only for codecs where a short progressive chunk is
  /// valid; missing arithmetic bits are padded with `0xff` as specified.
  DjvuZpDecoder(
    this._data, {
    required final String truncatedMessage,
    final bool allowShortPayload = false,
  }) : _truncatedMessage = truncatedMessage {
    if (_data.length < 2 && !allowShortPayload) {
      throw DjvuException(_truncatedMessage);
    }
    _code = (_readByte() << 8) | _readByte();
    _refill();
    _fence = _code < 0x7FFF ? _code : 0x7FFF;
  }

  final Uint8List _data;
  final String _truncatedMessage;
  var _a = 0;
  late int _code;
  late int _fence;
  var _bitBuffer = 0;
  var _bitCount = 0;
  var _position = 0;

  /// Number of synthetic 0xff bytes read after the payload ended.
  int get syntheticBytes => _position > _data.length ? _position - _data.length : 0;

  int _readByte() {
    final byte = _position < _data.length ? _data[_position] : 0xFF;
    _position++;
    return byte;
  }

  void _refill() {
    while (_bitCount <= 24) {
      _bitBuffer = ((_bitBuffer << 8) | _readByte()) & 0xFFFFFFFF;
      _bitCount += 8;
    }
  }

  /// Decodes one bit with its adaptive probability [state].
  ({bool bit, int state}) decodeBit(final int state) {
    if (state < 0 || state >= zpProbability.length) {
      throw const DjvuException('Invalid DjVu ZP context state.');
    }
    final mps = state & 1;
    final z = _a + zpProbability[state];
    if (z <= _fence) {
      _a = z;
      return (bit: mps != 0, state: state);
    }

    final boundary = 0x6000 + ((_a + z) >> 2);
    final clamped = z < boundary ? z : boundary;
    if (clamped > _code) {
      final complement = 0x10000 - clamped;
      _a = (_a + complement) & 0xFFFF;
      _code = (_code + complement) & 0xFFFF;
      final next = zpLpsNext[state];
      _renormalize();
      return (bit: mps == 0, state: next);
    }

    var next = state;
    if (_a >= zpThreshold[state]) next = zpMpsNext[state];
    _bitCount--;
    _a = (clamped << 1) & 0xFFFF;
    _code = ((_code << 1) | ((_bitBuffer >> (_bitCount & 31)) & 1)) & 0xFFFF;
    if (_bitCount < 16) _refill();
    _fence = _code < 0x7FFF ? _code : 0x7FFF;
    return (bit: mps != 0, state: next);
  }

  /// Decodes one bit in the IW44 passthrough mode, without adapting a context.
  bool decodePassthroughIw44() {
    final z = 0x8000 + (3 * _a ~/ 8);
    if (z > _code) {
      final complement = 0x10000 - z;
      _a = (_a + complement) & 0xFFFF;
      _code = (_code + complement) & 0xFFFF;
      _renormalize();
      return true;
    }

    _bitCount--;
    _a = (z << 1) & 0xFFFF;
    _code = ((_code << 1) | ((_bitBuffer >> (_bitCount & 31)) & 1)) & 0xFFFF;
    if (_bitCount < 16) _refill();
    _fence = _code < 0x7FFF ? _code : 0x7FFF;
    return false;
  }

  void _renormalize() {
    var shift = 0;
    while (shift < 16 && ((_a >> (15 - shift)) & 1) != 0) {
      shift++;
    }
    _bitCount -= shift;
    _a = (_a << shift) & 0xFFFF;
    final mask = (1 << shift) - 1;
    _code = ((_code << shift) | ((_bitBuffer >> (_bitCount & 31)) & mask)) & 0xFFFF;
    if (_bitCount < 16) _refill();
    _fence = _code < 0x7FFF ? _code : 0x7FFF;
  }
}
