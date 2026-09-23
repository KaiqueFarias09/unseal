import 'dart:typed_data';

import '../../foundation/exceptions/unseal_exception.dart';

/// LZX frames inside CHM, using one state until the next reset-table boundary.
///
/// The E8 postfilter follows Microsoft's [MS-PATCH 2.2.2](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-patch/e6c8366d-a8c3-4f34-aa5d-56f44f938a09)
/// translation rules, cross-checked against the independent [CHMLib decoder](https://github.com/jedwing/CHMLib/blob/master/src/lzx.c).
/// The CHM frame protocol is cross-checked against Apache-2.0 [jchmlib](https://github.com/chimenchen/jchmlib).
final class ChmLzxDecoder {
  /// Creates a decoder for a power-of-two history window between 32 KiB and 2 MiB.
  ChmLzxDecoder(this.windowBits)
    : assert(windowBits >= 15 && windowBits <= 21),
      _window = Uint8List(1 << windowBits),
      _mainLengths = List<int>.filled(
        256 +
            ((windowBits == 21
                    ? 50
                    : windowBits == 20
                    ? 42
                    : windowBits * 2) *
                8),
        0,
      ),
      _lengthLengths = List<int>.filled(249, 0);

  /// Binary logarithm of the history window size.
  final int windowBits;
  final Uint8List _window;
  final List<int> _mainLengths;
  final List<int> _lengthLengths;
  int _windowPos = 0;
  int _r0 = 1;
  int _r1 = 1;
  int _r2 = 1;
  int _blockType = 0;
  int _blockRemaining = 0;
  int _blockLength = 0;
  int _intelSize = 0;
  int _intelPosition = 0;
  int _frames = 0;
  bool _headerRead = false;
  bool _intelStarted = false;
  _Huffman? _mainTree;
  _Huffman? _lengthTree;
  _Huffman? _alignedTree;

  static const _extraBits = <int>[
    0,
    0,
    0,
    0,
    1,
    1,
    2,
    2,
    3,
    3,
    4,
    4,
    5,
    5,
    6,
    6,
    7,
    7,
    8,
    8,
    9,
    9,
    10,
    10,
    11,
    11,
    12,
    12,
    13,
    13,
    14,
    14,
    15,
    15,
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
    17,
    17,
    17,
    17,
    17,
    17,
    17,
  ];
  static const _positionBase = <int>[
    0,
    1,
    2,
    3,
    4,
    6,
    8,
    12,
    16,
    24,
    32,
    48,
    64,
    96,
    128,
    192,
    256,
    384,
    512,
    768,
    1024,
    1536,
    2048,
    3072,
    4096,
    6144,
    8192,
    12288,
    16384,
    24576,
    32768,
    49152,
    65536,
    98304,
    131072,
    196608,
    262144,
    393216,
    524288,
    655360,
    786432,
    917504,
    1048576,
    1179648,
    1310720,
    1441792,
    1572864,
    1703936,
    1835008,
    1966080,
    2097152,
  ];

  /// Clears the history at an LZXC reset interval.
  void reset() {
    _window.fillRange(0, _window.length, 0);
    _mainLengths.fillRange(0, _mainLengths.length, 0);
    _lengthLengths.fillRange(0, _lengthLengths.length, 0);
    _windowPos = 0;
    _r0 = _r1 = _r2 = 1;
    _blockType = _blockRemaining = _blockLength = 0;
    _intelSize = _intelPosition = _frames = 0;
    _headerRead = _intelStarted = false;
    _mainTree = _lengthTree = _alignedTree = null;
  }

  /// Expands one CHM 32 KiB frame from its compressed bytes.
  Uint8List decodeFrame(final Uint8List input, final int outputLength) {
    if (outputLength < 0 || outputLength > 32768) {
      throw const InvalidBookException('CHM LZX frame exceeds 32 KiB.');
    }
    final bits = _LzxBits(input);
    if (!_headerRead) {
      if (bits.read(1) != 0) {
        _intelSize = (bits.read(16) << 16) | bits.read(16);
      }
      _headerRead = true;
    }
    final result = Uint8List(outputLength);
    var out = 0;
    while (out < outputLength) {
      if (_blockRemaining == 0) _readBlockHeader(bits);
      final take = _blockRemaining < outputLength - out ? _blockRemaining : outputLength - out;
      if (take <= 0 || _windowPos + take > _window.length) {
        throw const InvalidBookException('Invalid CHM LZX block length.');
      }
      _blockRemaining -= take;
      var left = take;
      if (_blockType == 3) {
        for (var i = 0; i < take; i++) {
          final value = bits.readRawByte();
          result[out++] = value;
          _window[_windowPos++] = value;
        }
      } else {
        while (left > 0) {
          final symbol = _mainTree!.read(bits);
          if (symbol < 256) {
            _window[_windowPos++] = symbol;
            result[out++] = symbol;
            left--;
            continue;
          }
          final matchSymbol = symbol - 256;
          var length = matchSymbol & 7;
          if (length == 7) length += _lengthTree!.read(bits);
          length += 2;
          final slot = matchSymbol >> 3;
          if (slot >= _extraBits.length || length > left) {
            throw const InvalidBookException('Invalid CHM LZX match.');
          }
          int offset;
          if (slot == 0) {
            offset = _r0;
          } else if (slot == 1) {
            offset = _r1;
            _r1 = _r0;
            _r0 = offset;
          } else if (slot == 2) {
            offset = _r2;
            _r2 = _r0;
            _r0 = offset;
          } else {
            if (slot == 3) {
              offset = 1;
            } else {
              final extra = _extraBits[slot];
              offset = _positionBase[slot] - 2;
              if (_blockType == 2 && extra >= 3) {
                if (extra > 3) offset += bits.read(extra - 3) << 3;
                offset += _alignedTree!.read(bits);
              } else {
                offset += bits.read(extra);
              }
            }
            _r2 = _r1;
            _r1 = _r0;
            _r0 = offset;
          }
          if (offset <= 0 || offset > _window.length || _windowPos + length > _window.length) {
            throw const InvalidBookException('CHM LZX match exceeds its window.');
          }
          for (var i = 0; i < length; i++) {
            final source = (_windowPos - offset) & (_window.length - 1);
            final value = _window[source];
            _window[_windowPos++] = value;
            result[out++] = value;
          }
          left -= length;
        }
      }
    }
    if (_windowPos == _window.length) _windowPos = 0;
    if (_frames++ < 32768 && _intelSize != 0 && _intelStarted && result.length > 6) {
      _reverseIntelE8(result);
    }
    _intelPosition += outputLength;
    return result;
  }

  void _readBlockHeader(final _LzxBits bits) {
    if (_blockType == 3) {
      if (_blockLength.isOdd) bits.readRawByte();
      bits.resetWords();
    }
    _blockType = bits.read(3);
    _blockLength = _blockRemaining = (bits.read(16) << 8) | bits.read(8);
    if (_blockLength <= 0) throw const InvalidBookException('Empty CHM LZX block.');
    if (_blockType == 2) {
      _alignedTree = _Huffman(List<int>.generate(8, (_) => bits.read(3)));
    }
    if (_blockType == 1 || _blockType == 2) {
      _readLengths(bits, _mainLengths, 0, 256);
      _readLengths(bits, _mainLengths, 256, _mainLengths.length);
      _mainTree = _Huffman(_mainLengths);
      if (_mainLengths[0xe8] != 0) _intelStarted = true;
      _readLengths(bits, _lengthLengths, 0, 249);
      _lengthTree = _Huffman(_lengthLengths);
    } else if (_blockType == 3) {
      _intelStarted = true;
      bits.alignToRawWords();
      _r0 = bits.readRawUint32();
      _r1 = bits.readRawUint32();
      _r2 = bits.readRawUint32();
    } else {
      throw const InvalidBookException('Unsupported CHM LZX block type.');
    }
  }

  void _readLengths(final _LzxBits bits, final List<int> target, final int first, final int end) {
    final preTree = _Huffman(List<int>.generate(20, (_) => bits.read(4)));
    var index = first;
    while (index < end) {
      final symbol = preTree.read(bits);
      if (symbol == 17 || symbol == 18) {
        final count = symbol == 17 ? bits.read(4) + 4 : bits.read(5) + 20;
        if (index + count > end) throw const InvalidBookException('CHM LZX code length overrun.');
        target.fillRange(index, index + count, 0);
        index += count;
      } else if (symbol == 19) {
        final count = bits.read(1) + 4;
        final delta = preTree.read(bits);
        if (index + count > end) throw const InvalidBookException('CHM LZX code length overrun.');
        final value = (target[index] - delta + 17) % 17;
        target.fillRange(index, index + count, value);
        index += count;
      } else {
        target[index] = (target[index] - symbol + 17) % 17;
        index++;
      }
    }
  }

  void _reverseIntelE8(final Uint8List data) {
    var position = _intelPosition;
    for (var i = 0; i < data.length - 10;) {
      if (data[i++] != 0xe8) {
        position++;
        continue;
      }
      final relative = ByteData.sublistView(data).getInt32(i, Endian.little);
      if (relative >= -position && relative < _intelSize) {
        final translated = relative >= 0 ? relative - position : relative + _intelSize;
        ByteData.sublistView(data).setInt32(i, translated, Endian.little);
      }
      i += 4;
      position += 5;
    }
  }
}

final class _LzxBits {
  _LzxBits(this.input);

  final Uint8List input;
  int offset = 0;
  int _buffer = 0;
  int _count = 0;

  void resetWords() {
    _buffer = 0;
    _count = 0;
  }

  void alignToRawWords() {
    // A 16-bit lookahead word may have been fetched but not consumed.
    if (_count > 16) offset -= 2;
    resetWords();
  }

  int read(final int count) {
    if (count == 0) return 0;
    if (count < 0 || count > 24) throw const InvalidBookException('Invalid CHM LZX bit count.');
    while (_count < count) {
      if (offset + 1 >= input.length) {
        throw const InvalidBookException('Truncated CHM LZX stream.');
      }
      final word = input[offset] | (input[offset + 1] << 8);
      offset += 2;
      _buffer = (_buffer << 16) | word;
      _count += 16;
    }
    _count -= count;
    final value = (_buffer >> _count) & ((1 << count) - 1);
    _buffer &= (1 << _count) - 1;
    return value;
  }

  int readRawByte() {
    if (offset >= input.length) throw const InvalidBookException('Truncated CHM LZX stream.');
    return input[offset++];
  }

  int readRawUint32() {
    if (offset + 4 > input.length) throw const InvalidBookException('Truncated CHM LZX stream.');
    final result = ByteData.sublistView(input).getUint32(offset, Endian.little);
    offset += 4;
    return result;
  }
}

final class _Huffman {
  _Huffman(final List<int> lengths) {
    final counts = List<int>.filled(17, 0);
    for (final length in lengths) {
      if (length < 0 || length > 16) {
        throw const InvalidBookException('Invalid CHM LZX Huffman length.');
      }
      if (length != 0) counts[length]++;
    }
    var code = 0;
    final next = List<int>.filled(17, 0);
    for (var bits = 1; bits <= 16; bits++) {
      code = (code + counts[bits - 1]) << 1;
      if (code + counts[bits] > 1 << bits) {
        throw const InvalidBookException('Oversubscribed CHM LZX Huffman tree.');
      }
      next[bits] = code;
    }
    for (var symbol = 0; symbol < lengths.length; symbol++) {
      final length = lengths[symbol];
      if (length == 0) continue;
      (_byLength[length] ??= <int, int>{})[next[length]++] = symbol;
    }
  }

  final Map<int, Map<int, int>> _byLength = <int, Map<int, int>>{};

  int read(final _LzxBits bits) {
    var code = 0;
    for (var length = 1; length <= 16; length++) {
      code = (code << 1) | bits.read(1);
      final symbol = _byLength[length]?[code];
      if (symbol != null) return symbol;
    }
    throw const InvalidBookException('Invalid CHM LZX Huffman symbol.');
  }
}
