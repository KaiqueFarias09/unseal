part of '../parse_comic_book.dart';

/// Decodes the classic RAR 2.9/3.x compression stream used by RAR 4 files.
///
/// This covers the non-solid LZSS/Huffman stream used by ordinary CBR files. RAR VM filters and
/// PPMd blocks remain unsupported and are reported as a compressed entry that the comic parser
/// cannot decode.
Uint8List _decodeRar4Method29(final Uint8List packed, final int unpackedSize) {
  if (unpackedSize < 0) throw const FormatException('Invalid RAR4 output size.');
  if (unpackedSize == 0) return Uint8List(0);

  var windowSize = 0x20000;
  while (windowSize < unpackedSize) {
    windowSize <<= 1;
  }

  final decoder = _Rar4Decoder(Uint8List(windowSize));

  return decoder.decode(packed, unpackedSize);
}

final class _Rar4Decoder {
  _Rar4Decoder(this._output);

  static const int _mainCodeSize = 299;
  static const int _offsetCodeSize = 60;
  static const int _lowOffsetCodeSize = 17;
  static const int _lengthCodeSize = 28;
  static const int _tableSize =
      _mainCodeSize + _offsetCodeSize + _lowOffsetCodeSize + _lengthCodeSize;
  static const int _precodeSymbols = 20;

  static const List<int> _lengthBases = [
    0,
    1,
    2,
    3,
    4,
    5,
    6,
    7,
    8,
    10,
    12,
    14,
    16,
    20,
    24,
    28,
    32,
    40,
    48,
    56,
    64,
    80,
    96,
    112,
    128,
    160,
    192,
    224,
  ];

  static const List<int> _lengthBits = [
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
    2,
    2,
    2,
    2,
    3,
    3,
    3,
    3,
    4,
    4,
    4,
    4,
    5,
    5,
    5,
    5,
  ];

  static const List<int> _offsetBases = [
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
    327680,
    393216,
    458752,
    524288,
    589824,
    655360,
    720896,
    786432,
    851968,
    917504,
    983040,
    1048576,
    1310720,
    1572864,
    1835008,
    2097152,
    2359296,
    2621440,
    2883584,
    3145728,
    3407872,
    3670016,
    3932160,
  ];

  static const List<int> _offsetBits = [
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
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    16,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
    18,
  ];

  static const List<int> _shortBases = [0, 4, 8, 16, 32, 64, 128, 192];
  static const List<int> _shortBits = [2, 2, 3, 4, 5, 6, 6, 6];

  final Uint8List _output;
  final Uint8List _lengthTable = Uint8List(_tableSize);
  final List<int> _oldOffset = [0, 0, 0, 0];

  _Huffman? _mainCode;
  _Huffman? _offsetCode;
  _Huffman? _lowOffsetCode;
  _Huffman? _lengthCode;
  int _writePtr = 0;
  int _lastOffset = 0;
  int _lastLength = 0;
  int _lastLowOffset = 0;
  int _lowOffsetRepeats = 0;

  Uint8List decode(final Uint8List packed, final int unpackedSize) {
    final bits = _BitReader(packed);
    _parseCodes(bits);
    final target = unpackedSize;
    final mask = _output.length - 1;
    while (_writePtr < target) {
      final symbol = _mainCode!.decode(bits);
      if (_writeLiteralOrControl(symbol, bits, mask)) continue;

      final match = _decodeMatch(symbol, bits);
      if (match.skipped) continue;
      _lastOffset = match.offset;
      _lastLength = match.length;
      _copy(match.offset, match.length, target, mask);
    }

    return Uint8List.fromList(_output.sublist(0, target));
  }

  bool _writeLiteralOrControl(final int symbol, final _BitReader bits, final int mask) {
    if (symbol < 256) {
      _output[_writePtr++ & mask] = symbol;

      return true;
    }
    if (symbol == 256) {
      _parseNewFile(bits);

      return true;
    }
    if (symbol == 257) {
      throw const FormatException('RAR4 VM filters are not supported.');
    }

    return false;
  }

  void _parseNewFile(final _BitReader bits) {
    final newFile = bits.read(1) == 0;
    if (newFile && bits.read(1) == 0) return;
    _parseCodes(bits);
  }

  _Rar4Match _decodeMatch(final int symbol, final _BitReader bits) {
    if (symbol == 258) {
      if (_lastLength == 0) return const _Rar4Match.skip();

      return _Rar4Match(offset: _lastOffset, length: _lastLength);
    }
    if (symbol <= 262) return _decodeRecentMatch(symbol, bits);
    if (symbol <= 270) return _decodeShortMatch(symbol, bits);

    return _decodeLongMatch(symbol, bits);
  }

  _Rar4Match _decodeRecentMatch(final int symbol, final _BitReader bits) {
    final offsetIndex = symbol - 259;
    final offset = _oldOffset[offsetIndex];
    final length = _readLength(bits);
    _rememberOffset(offset, offsetIndex);

    return _Rar4Match(offset: offset, length: length);
  }

  _Rar4Match _decodeShortMatch(final int symbol, final _BitReader bits) {
    final shortIndex = symbol - 263;
    var offset = _shortBases[shortIndex] + 1;
    final extraBits = _shortBits[shortIndex];
    if (extraBits > 0) offset += bits.read(extraBits);
    _rememberOffset(offset);

    return _Rar4Match(offset: offset, length: 2);
  }

  _Rar4Match _decodeLongMatch(final int symbol, final _BitReader bits) {
    final lengthIndex = symbol - 271;
    if (lengthIndex >= _lengthBases.length) {
      throw const FormatException('Invalid RAR4 match length.');
    }

    var length = _lengthBases[lengthIndex] + 3;
    final extraBits = _lengthBits[lengthIndex];
    if (extraBits > 0) length += bits.read(extraBits);

    final offset = _decodeLongOffset(bits);
    if (offset >= 0x40000) length++;
    if (offset >= 0x2000) length++;
    _rememberOffset(offset);

    return _Rar4Match(offset: offset, length: length);
  }

  int _decodeLongOffset(final _BitReader bits) {
    final offsetSymbol = _offsetCode!.decode(bits);
    if (offsetSymbol >= _offsetBases.length) {
      throw const FormatException('Invalid RAR4 match offset.');
    }

    var offset = _offsetBases[offsetSymbol] + 1;
    final offsetBits = _offsetBits[offsetSymbol];
    if (offsetBits == 0) return offset;
    if (offsetSymbol <= 9) return offset + bits.read(offsetBits);

    if (offsetBits > 4) offset += bits.read(offsetBits - 4) << 4;
    if (_lowOffsetRepeats > 0) {
      _lowOffsetRepeats--;

      return offset + _lastLowOffset;
    }

    final lowOffset = _lowOffsetCode!.decode(bits);
    if (lowOffset == 16) {
      _lowOffsetRepeats = 15;

      return offset + _lastLowOffset;
    }
    _lastLowOffset = lowOffset;

    return offset + lowOffset;
  }

  void _rememberOffset(final int offset, [final int from = 3]) {
    for (var i = from; i > 0; i--) {
      _oldOffset[i] = _oldOffset[i - 1];
    }
    _oldOffset[0] = offset;
  }

  int _readLength(final _BitReader bits) {
    final symbol = _lengthCode!.decode(bits);
    if (symbol >= _lengthBases.length) {
      throw const FormatException('Invalid RAR4 match length.');
    }

    final extraBits = _lengthBits[symbol];

    return _lengthBases[symbol] + 2 + (extraBits == 0 ? 0 : bits.read(extraBits));
  }

  void _copy(final int offset, final int length, final int target, final int mask) {
    if (offset <= 0 || offset > _writePtr) {
      throw const FormatException('RAR4 match offset is out of range.');
    }
    if (_writePtr + length > target) {
      throw const FormatException('RAR4 match exceeds the declared size.');
    }
    for (var i = 0; i < length; i++) {
      _output[_writePtr & mask] = _output[(_writePtr - offset) & mask];
      _writePtr++;
    }
  }

  void _parseCodes(final _BitReader bits) {
    bits.alignToByte();
    if (bits.read(1) != 0) {
      throw const FormatException('RAR4 PPMd blocks are not supported.');
    }
    if (bits.read(1) == 0) _lengthTable.fillRange(0, _tableSize, 0);

    final precodeLengths = Uint8List(_precodeSymbols);
    for (var i = 0; i < _precodeSymbols;) {
      final length = bits.read(4);
      precodeLengths[i++] = length;
      if (length != 0xF) continue;

      final zeros = bits.read(4);
      if (zeros == 0) continue;
      i--;
      for (var j = 0; j < zeros + 2 && i < _precodeSymbols; j++) {
        precodeLengths[i++] = 0;
      }
    }

    final precode = _Huffman(precodeLengths, _precodeSymbols);
    for (var i = 0; i < _tableSize;) {
      final value = precode.decode(bits);
      if (value < 16) {
        _lengthTable[i] = (_lengthTable[i] + value) & 0xF;
        i++;

        continue;
      }

      final count = value == 16
          ? bits.read(3) + 3
          : value == 17
          ? bits.read(7) + 11
          : value == 18
          ? bits.read(3) + 3
          : bits.read(7) + 11;
      if (value == 16 || value == 17) {
        if (i == 0) throw const FormatException('Invalid RAR4 table repeat.');
        for (var j = 0; j < count && i < _tableSize; j++) {
          _lengthTable[i] = _lengthTable[i - 1];
          i++;
        }
      } else {
        for (var j = 0; j < count && i < _tableSize; j++) {
          _lengthTable[i++] = 0;
        }
      }
    }

    _mainCode = _Huffman(Uint8List.sublistView(_lengthTable, 0, _mainCodeSize), _mainCodeSize);
    _offsetCode = _Huffman(
      Uint8List.sublistView(_lengthTable, _mainCodeSize, _mainCodeSize + _offsetCodeSize),
      _offsetCodeSize,
    );
    _lowOffsetCode = _Huffman(
      Uint8List.sublistView(
        _lengthTable,
        _mainCodeSize + _offsetCodeSize,
        _mainCodeSize + _offsetCodeSize + _lowOffsetCodeSize,
      ),
      _lowOffsetCodeSize,
    );
    _lengthCode = _Huffman(
      Uint8List.sublistView(_lengthTable, _mainCodeSize + _offsetCodeSize + _lowOffsetCodeSize),
      _lengthCodeSize,
    );
    _lowOffsetRepeats = 0;
  }
}

final class _Rar4Match {
  const _Rar4Match({required this.offset, required this.length}) : skipped = false;

  const _Rar4Match.skip() : offset = 0, length = 0, skipped = true;

  final int offset;
  final int length;
  final bool skipped;
}

final class _BitReader {
  _BitReader(this._bytes);

  final Uint8List _bytes;
  int _position = 0;

  bool has(final int count) => _position + count <= _bytes.length * 8;

  int read(final int count) {
    if (!has(count)) throw const FormatException('Truncated RAR4 stream.');
    final value = peek(count);
    _position += count;

    return value;
  }

  int peek(final int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      final position = _position + i;
      final bit = position < _bytes.length * 8
          ? (_bytes[position >> 3] >> (7 - (position & 7))) & 1
          : 0;
      value = (value << 1) | bit;
    }

    return value;
  }

  void consume(final int count) {
    if (!has(count)) throw const FormatException('Truncated RAR4 stream.');
    _position += count;
  }

  void alignToByte() => _position = (_position + 7) & ~7;
}

final class _Huffman {
  _Huffman(final Uint8List lengths, final int count) {
    var maxLength = 0;
    for (var i = 0; i < count; i++) {
      if ((lengths[i] & 0xF) > maxLength) maxLength = lengths[i] & 0xF;
    }
    if (maxLength == 0) {
      _maxLength = 1;
      _table = Int32List(2)..fillRange(0, 2, -1);

      return;
    }
    if (maxLength > 16) throw const FormatException('Invalid RAR4 Huffman length.');

    _maxLength = maxLength;
    _table = Int32List(1 << maxLength)..fillRange(0, 1 << maxLength, -1);
    var code = 0;
    for (var length = 1; length <= maxLength; length++) {
      for (var symbol = 0; symbol < count; symbol++) {
        if ((lengths[symbol] & 0xF) != length) continue;
        if (code >= (1 << length)) {
          throw const FormatException('Oversubscribed RAR4 Huffman table.');
        }
        final shift = maxLength - length;
        final entry = (length << 16) | symbol;
        final start = code << shift;
        for (var i = 0; i < 1 << shift; i++) {
          _table[start + i] = entry;
        }
        code++;
      }
      code <<= 1;
    }
  }

  late final int _maxLength;
  late final Int32List _table;

  int decode(final _BitReader bits) {
    final entry = _table[bits.peek(_maxLength)];
    if (entry < 0) throw const FormatException('Invalid RAR4 Huffman code.');

    final length = entry >> 16;
    bits.consume(length);

    return entry & 0xFFFF;
  }
}
