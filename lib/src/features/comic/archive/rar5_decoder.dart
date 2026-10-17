/// Decodes the RAR 5 LZ/Huffman compression stream (algorithm version
/// 0, methods 1-5).
///
/// A bounded adaptation of the [rardecode](https://github.com/nwaples/rardecode)
/// Go implementation (BSD-2-Clause, pinned at `ad22ba91a2ab`) —
/// `decode50.go`, `decode_reader.go`, `huffman.go`, `bit_reader.go`, and
/// the V5 filters of `filters.go`. See `THIRD_PARTY_NOTICES.md`.
///
/// The stream is a sequence of blocks. Each block header carries a bit
/// limit, a byte checksum, and optional Huffman code-length tables; the
/// block's symbols fill a circular window of `max(dictionary, 256 KiB)`
/// bytes that matches copy from. Filters (delta, E8, E8/E9, ARM) are
/// decoded inline and applied to window copies as the output streams
/// past them, so LZ matches always reference pre-filter bytes — the
/// exact semantics the Go decoder implements.
///
/// Output is written into a buffer of exactly `uncompressedSize` bytes;
/// every allocation here is bounded by the declared dictionary and the
/// declared output size, which callers validate before calling (see
/// `Rar5EntryHeader.unsupportedReason`). Corruption fails with
/// [FormatException]; the public readers translate that into typed
/// comic failures naming the entry.
library;

import 'dart:typed_data';

/// Block-symbol table sizes of the RAR 5.0 algorithm.
const int _mainSize5 = 306;
const int _offsetSize5 = 64;
const int _lowoffsetSize5 = 16;
const int _lengthSize5 = 44;
const int _tableSize5 = _mainSize5 + _offsetSize5 + _lowoffsetSize5 + _lengthSize5;

/// The window is never smaller than 256 KiB, mirroring the reference
/// decoder; matches cannot exceed the declared dictionary anyway.
const int _minWindowSize = 0x40000;

/// Maximum queued filter blocks before the stream is rejected — the
/// same work limit the reference decoder applies.
const int _maxQueuedFilters = 8192;

/// File-size constant the E8/E9 filters convert addresses against.
const int _filterFileSize = 0x1000000;

/// Raised when the packed stream is exhausted before its bit limit.
/// Mirrors `ErrDecoderOutOfData`: this is corruption, not a block end.
class _Rar5OutOfDataException implements Exception {
  const _Rar5OutOfDataException();
}

/// Raised when the current block's bit limit is reached. Mirrors
/// `io.EOF` at the bit limit: the block is over.
class _Rar5BlockEndException implements Exception {
  const _Rar5BlockEndException();
}

/// Bit reader over the packed data with a per-block bit limit.
///
/// Reads are MSB-first. Bits are pulled byte-at-a-time; when the limit
/// is hit mid-symbol the reader reports a block end, and when the
/// stream ends before the limit it reports out-of-data. Header bytes
/// bypass the cached bits so the next block starts at a byte boundary —
/// the exact behavior of `rar5BitReader`.
final class _Rar5BitReader {
  _Rar5BitReader(this._data);

  final Uint8List _data;
  int _position = 0;
  int _value = 0;
  int _bits = 0;
  int _limit = 0;

  /// Reads [count] bits, or throws when the block limit or the data
  /// ends first.
  int readBits(final int count) {
    while (count > _bits) {
      if (_limit == 0) throw const _Rar5BlockEndException();
      if (_position >= _data.length) throw const _Rar5OutOfDataException();
      _value = ((_value << 8) | _data[_position++]) & 0xFFFFFFFFFF;
      _bits += 8;
      _limit -= 8;
      if (_limit < 0) {
        // Overshot the limit inside this byte: drop the extra bits.
        final drop = -_limit;
        _limit = 0;
        _value >>= drop;
        _bits -= drop;
      }
    }
    _bits -= count;

    return (_value >> _bits) & ((1 << count) - 1);
  }

  /// Reads one byte, straight from the data when no bits are cached.
  int readByte() {
    if (_bits == 0) {
      if (_position >= _data.length) throw const _Rar5OutOfDataException();

      return _data[_position++];
    }

    return readBits(8);
  }

  /// Starts a new block with [bitCount] usable bits, discarding any
  /// cached bits.
  void setLimit(final int bitCount) {
    _limit = bitCount;
    _bits = 0;
  }
}

/// Canonical Huffman decoder with quick-lookup tables — the port of
/// `huffmanDecoder`.
final class _Rar5Huffman {
  static const int _maxCodeLength = 15;
  static const int _maxQuickBits = 10;
  static const int _maxQuickSize = 1 << _maxQuickBits;

  final Uint16List _limit = Uint16List(_maxCodeLength + 1);
  final Uint16List _pos = Uint16List(_maxCodeLength + 1);
  late Uint16List _symbol;
  int _min = 0;
  late int _quickBits;
  final Uint8List _quickLength = Uint8List(_maxQuickSize);
  final Uint16List _quickSymbol = Uint16List(_maxQuickSize);

  /// Builds the decode tables from [codeLengths] (one length per
  /// symbol, 0 = unused).
  void init(final List<int> codeLengths) {
    final count = Uint16List(_maxCodeLength + 1);
    for (final length in codeLengths) {
      if (length == 0) continue;
      count[length]++;
    }

    _pos[0] = 0;
    _limit[0] = 0;
    _min = 0;
    for (var i = 1; i <= _maxCodeLength; i++) {
      _limit[i] = (_limit[i - 1] + (count[i] << (_maxCodeLength - i))) & 0xFFFF;
      _pos[i] = (_pos[i - 1] + count[i - 1]) & 0xFFFF;
      if (_min == 0 && _limit[i] > 0) _min = i;
    }

    _symbol = Uint16List(codeLengths.length);
    for (var i = 0; i < _maxCodeLength + 1; i++) {
      count[i] = _pos[i];
    }
    for (var i = 0; i < codeLengths.length; i++) {
      final length = codeLengths[i];
      if (length != 0) {
        _symbol[count[length]] = i;
        count[length]++;
      }
    }

    _quickBits = codeLengths.length >= 298 ? _maxQuickBits : _maxQuickBits - 3;

    var bits = 1;
    for (var i = 0; i < 1 << _quickBits; i++) {
      final value = i << (_maxCodeLength - _quickBits);

      while (value >= _limit[bits] && bits < _maxCodeLength) {
        bits++;
      }
      _quickLength[i] = bits;

      var distance = value - _limit[bits - 1];
      distance >>= _maxCodeLength - bits;

      final index = _pos[bits] + distance;
      _quickSymbol[i] = index < _symbol.length ? _symbol[index] : 0;
    }
  }

  /// Reads one symbol from [reader]. The 15-bit peek falls back to one
  /// bit at a time when the block limit ends mid-symbol — the exact
  /// behavior that lets block boundaries cut between symbols.
  int readSymbol(final _Rar5BitReader reader) {
    int bits;
    int value;
    try {
      value = reader.readBits(_maxCodeLength);
    } on _Rar5BlockEndException {
      // The block ended mid-peek: decode from the bits that remain.
      value = 0;
      for (bits = 1; bits <= _maxCodeLength; bits++) {
        final bit = reader.readBits(1);
        value |= bit << (_maxCodeLength - bits);
        if (value < _limit[bits]) break;
      }
      return _symbolAt(value, bits);
    }

    if (value < _limit[_quickBits]) {
      final index = value >> (_maxCodeLength - _quickBits);
      reader._bits += _maxCodeLength - _quickLength[index];

      return _quickSymbol[index];
    }

    bits = _min;
    while (bits < _maxCodeLength) {
      if (value < _limit[bits]) {
        reader._bits += _maxCodeLength - bits;
        break;
      }
      bits++;
    }

    return _symbolAt(value, bits);
  }

  int _symbolAt(final int value, final int bits) {
    var distance = value - _limit[bits - 1];
    distance >>= _maxCodeLength - bits;

    final index = _pos[bits] + distance;
    if (index >= _symbol.length) {
      throw const FormatException('RAR5: Huffman decode failed.');
    }

    return _symbol[index];
  }

  /// Deep copy for solid-state checkpoints: a solid continuation may
  /// decode with the carried tables, so snapshots must preserve them.
  _Rar5Huffman copy() {
    final clone = _Rar5Huffman()
      .._limit.setAll(0, _limit)
      .._pos.setAll(0, _pos)
      .._min = _min
      .._quickBits = _quickBits
      .._quickLength.setAll(0, _quickLength)
      .._quickSymbol.setAll(0, _quickSymbol);
    clone._symbol = Uint16List.fromList(_symbol);

    return clone;
  }

  /// Replaces this decoder's tables with a deep copy of [other].
  void restore(final _Rar5Huffman other) {
    _limit.setAll(0, other._limit);
    _pos.setAll(0, other._pos);
    _symbol = Uint16List.fromList(other._symbol);
    _min = other._min;
    _quickBits = other._quickBits;
    _quickLength.setAll(0, other._quickLength);
    _quickSymbol.setAll(0, other._quickSymbol);
  }
}

/// Reads the 20-entry precode and then the full code-length table —
/// the port of `readCodeLengthTable`.
void _readCodeLengthTable(final _Rar5BitReader reader, final List<int> codeLength) {
  final bitLength = List<int>.filled(20, 0);
  for (var i = 0; i < bitLength.length; i++) {
    var nibble = reader.readBits(4);
    if (nibble == 0xF) {
      final skip = reader.readBits(4);
      if (skip > 0) {
        i += skip + 1;
        continue;
      }
      nibble = 0;
    }
    bitLength[i] = nibble;
  }

  final precode = _Rar5Huffman()..init(bitLength);

  for (var i = 0; i < codeLength.length; i++) {
    final symbol = precode.readSymbol(reader);

    if (symbol < 16) {
      codeLength[i] = symbol;
      continue;
    }

    int runLength;
    int runValue;
    switch (symbol) {
      case 16:
      case 18:
        runLength = reader.readBits(3) + 3;
      default:
        runLength = reader.readBits(7) + 11;
    }
    if (symbol < 18) {
      // Symbols 16 and 17 repeat the previous length.
      if (i == 0) {
        throw const FormatException('RAR5: invalid code length table.');
      }
      runValue = codeLength[i - 1];
    } else {
      runValue = 0;
    }
    for (; runLength > 0 && i < codeLength.length; i++) {
      codeLength[i] = runValue;
      runLength--;
    }
    i--;
  }
}

/// Converts a length-table slot into a match length — `slotToLength`.
int _slotToLength(final _Rar5BitReader reader, final int slot) {
  var length = slot;
  if (slot >= 8) {
    final extraBits = slot ~/ 4 - 1;
    length = (4 | (slot & 3)) << extraBits;
    if (extraBits > 0) {
      length |= reader.readBits(extraBits);
    }
  }

  return length + 2;
}

/// Reads the encoded integer V5 filter headers use — `readFilter5Data`.
int _readFilterData(final _Rar5BitReader reader) {
  final byteCount = reader.readBits(2) + 1;

  var data = 0;
  for (var i = 0; i < byteCount; i++) {
    data |= reader.readBits(8) << (i * 8);
  }

  return data;
}

/// One queued filter region: `offset` bytes relative to the previous
/// queue entry and `length` bytes long, transformed by `kind` with
/// `param`.
final class _Rar5FilterBlock {
  _Rar5FilterBlock(this.offset, this.length, this.kind, this.param);

  int offset;
  final int length;
  final _Rar5FilterKind kind;
  final int param;

  _Rar5FilterBlock copy() => _Rar5FilterBlock(offset, length, kind, param);
}

enum _Rar5FilterKind { delta, e8, e8e9, arm }

/// The decode state: circular window, queued filters, and the block
/// stream — the port of `decodeReader` plus `decoder50`.
///
/// One instance carries the dictionary across a solid chain: entries
/// with the solid bit decode against the carried window, Huffman
/// tables, recent offsets, and filter queue, exactly like the
/// reference decoder's persistent `decodeReader`
/// (`init(reset: !solid)`). Entries without the bit reset to a fresh
/// window. Every entry still owns a complete framed block stream —
/// only the dictionary continues — so the eager parse, the comparator,
/// and every session drive the same decoder, one chain per caller.
final class Rar5SolidDecoder {
  /// Creates a decoder with an empty dictionary; the first entry of a
  /// chain decodes exactly like a non-solid one.
  Rar5SolidDecoder();

  Uint8List _window = Uint8List(_minWindowSize);
  int _readIndex = 0;
  int _writeIndex = 0;
  int _overflowLength = 0;
  int _overflowOffset = 0;

  final _Rar5Huffman _mainDecoder = _Rar5Huffman();
  final _Rar5Huffman _offsetDecoder = _Rar5Huffman();
  final _Rar5Huffman _lowOffsetDecoder = _Rar5Huffman();
  final _Rar5Huffman _lengthDecoder = _Rar5Huffman();

  final Int32List _offsets = Int32List(4);
  int _length = 0;
  bool _lastBlock = false;

  /// Filter queue, each offset relative to the previous entry. A solid
  /// continuation keeps the queue; a reset drops it.
  final List<_Rar5FilterBlock> _filters = [];

  // Per-entry decode state (never crosses entries).
  _Rar5BitReader? _bitReader;
  final Uint8List _codeLength = Uint8List(_tableSize5);
  bool _decoderEnded = false;
  int _total = 0;
  Uint8List _outBuffer = Uint8List(0);
  int _outPosition = 0;

  /// Decodes one entry's framed stream into exactly [uncompressedSize]
  /// bytes, continuing the carried dictionary when [solid] is set.
  ///
  /// [packed] is the entry's data area and [windowSize] its declared
  /// dictionary (`0x20000 << dictExp`). The window only grows: a solid
  /// continuation with a larger declared dictionary rotates the carried
  /// history into a bigger buffer — the exact copy the reference
  /// decoder makes, stale tail included. Corruption throws
  /// [FormatException]; every allocation is bounded by the declared
  /// dictionary and output size, which callers validate before calling
  /// (see `Rar5EntryHeader.unsupportedReason`).
  Uint8List decodeEntry({
    required final Uint8List packed,
    required final int uncompressedSize,
    required final int windowSize,
    required final bool solid,
  }) {
    if (uncompressedSize < 0) {
      throw const FormatException('RAR5: invalid output size.');
    }
    if (uncompressedSize == 0) return Uint8List(0);
    if (windowSize < 0x20000 || (windowSize & (windowSize - 1)) != 0) {
      throw const FormatException('RAR5: invalid dictionary size.');
    }

    // The reference decoder's init(reset: !solid): a reset entry gets a
    // cleared window, filter queue, and recent offsets; a solid
    // continuation keeps all of them and only grows the window. The
    // read index always equals the write index between entries.
    final wantedWindow = windowSize < _minWindowSize ? _minWindowSize : windowSize;
    if (!solid) {
      _window = Uint8List(wantedWindow);
      _readIndex = 0;
      _writeIndex = 0;
      _filters.clear();
      _offsets.fillRange(0, _offsets.length, 0);
      _length = 0;
    } else if (wantedWindow > _window.length) {
      final oldLength = _window.length;
      final grown = Uint8List(wantedWindow);
      final tail = oldLength - _writeIndex;
      grown.setRange(0, tail, _window, _writeIndex);
      grown.setRange(tail, tail + _writeIndex, _window);
      _window = grown;
      _readIndex = oldLength;
      _writeIndex = oldLength;
    }
    _overflowLength = 0;
    _lastBlock = false;
    _decoderEnded = false;
    _total = 0;
    _outBuffer = Uint8List(0);
    _outPosition = 0;
    _bitReader = _Rar5BitReader(packed);

    final output = Uint8List(uncompressedSize);
    try {
      _run(output);
    } on _Rar5OutOfDataException {
      throw const FormatException('RAR5: stream ended before the declared output size.');
    } on RangeError {
      throw const FormatException('RAR5: corrupt stream state.');
    }

    return output;
  }

  /// Point-in-time copy of the dictionary state, taken between entries
  /// (read index equals write index there). Sessions checkpoint these
  /// to bound backward-access replay work.
  Rar5SolidState captureState() {
    return Rar5SolidState._(
      window: Uint8List.fromList(_window),
      readIndex: _readIndex,
      writeIndex: _writeIndex,
      main: _mainDecoder.copy(),
      offset: _offsetDecoder.copy(),
      lowOffset: _lowOffsetDecoder.copy(),
      length: _lengthDecoder.copy(),
      codeLength: Uint8List.fromList(_codeLength),
      offsets: Int32List.fromList(_offsets),
      matchLength: _length,
      lastBlock: _lastBlock,
      filters: [for (final filter in _filters) filter.copy()],
      overflowLength: _overflowLength,
      overflowOffset: _overflowOffset,
    );
  }

  /// Replaces the decoder's dictionary state with a deep copy of
  /// [state]; the captured object itself is never mutated by decoding.
  void restoreState(final Rar5SolidState state) {
    _window = Uint8List.fromList(state._window);
    _readIndex = state._readIndex;
    _writeIndex = state._writeIndex;
    _mainDecoder.restore(state._main);
    _offsetDecoder.restore(state._offset);
    _lowOffsetDecoder.restore(state._lowOffset);
    _lengthDecoder.restore(state._length);
    _codeLength.setAll(0, state._codeLength);
    _offsets.setAll(0, state._offsets);
    _length = state._matchLength;
    _lastBlock = state._lastBlock;
    _filters
      ..clear()
      ..addAll([for (final filter in state._filters) filter.copy()]);
    _overflowLength = state._overflowLength;
    _overflowOffset = state._overflowOffset;
  }

  /// The carried dictionary's size in bytes — the memory weight of a
  /// [captureState] snapshot.
  int get windowBytes => _window.length;

  // Decodes the whole stream into [output]. The end of the block stream
  // is a deferred error, exactly like the reference decoder: window
  // contents produced before the end are emitted first, and only an
  // incomplete output turns it into a failure.
  void _run(final Uint8List output) {
    var streamEnded = false;
    var filled = 0;
    while (filled < output.length && !streamEnded) {
      try {
        _decode();
      } on _Rar5OutOfDataException {
        streamEnded = true;
      }
      while (_outPosition < _outBuffer.length && filled < output.length) {
        output[filled++] = _outBuffer[_outPosition++];
      }
    }

    if (filled < output.length) {
      throw const FormatException('RAR5: stream ended before the declared output size.');
    }
  }

  // The port of decodeReader.decode: one window-sized step of output,
  // filters applied as the read index passes them.
  void _decode() {
    if (_writeIndex == _readIndex) {
      _fillWindow();
    }
    var available = _writeIndex - _readIndex;

    if (_filters.isEmpty) {
      _outBuffer = Uint8List.sublistView(_window, _readIndex, _writeIndex);
      _readIndex = _writeIndex;
      _total += available;
      _outPosition = 0;

      return;
    }

    final first = _filters[0];
    if (first.offset < 0) {
      throw const FormatException('RAR5: invalid filter offset.');
    }
    if (first.offset > 0) {
      available = first.offset < available ? first.offset : available;
      _outBuffer = Uint8List.sublistView(_window, _readIndex, _readIndex + available);
      _readIndex += available;
      first.offset -= available;
      _total += available;
      _outPosition = 0;

      return;
    }

    _processFilters();
    _outPosition = 0;
    _total += _outBuffer.length;
  }

  // The port of decodeReader.processFilters: chained filters at the
  // same offset run over the same buffer.
  void _processFilters() {
    var block = _filters[0];
    final blockLength = block.length;

    var buffer = _bufferBytes(blockLength);
    while (true) {
      _filters.removeAt(0);
      buffer = _applyFilter(block, buffer);
      if (_filters.isEmpty) {
        _outBuffer = buffer;

        return;
      }
      final next = _filters[0];
      if (next.offset != 0) {
        next.offset -= blockLength;
        _outBuffer = buffer;

        return;
      }
      if (next.length != buffer.length) {
        throw const FormatException('RAR5: invalid filter chain.');
      }
      block = next;
    }
  }

  // The port of decodeReader.bufBytes: collects [count] bytes from the
  // window, filling it as needed.
  Uint8List _bufferBytes(final int count) {
    final buffer = Uint8List(count);
    var filled = 0;
    while (filled < count) {
      final available = _writeIndex - _readIndex;
      final take = count - filled < available ? count - filled : available;
      buffer.setRange(filled, filled + take, _window, _readIndex);
      _readIndex += take;
      filled += take;
      if (filled < count) _fillWindow();
    }

    return buffer;
  }

  // The port of decodeReader.fill. The end of the block stream is
  // stored, not thrown: the window content decoded so far is emitted
  // first, and the error surfaces when the window runs dry.
  void _fillWindow() {
    if (_decoderEnded) {
      throw const _Rar5OutOfDataException();
    }
    if (_writeIndex == _window.length) {
      _readIndex = 0;
      _writeIndex = 0;
      if (_overflowLength > 0) {
        _copyBytes(_overflowLength, _overflowOffset);
      }
    }
    try {
      _fillFromDecoder();
    } on _Rar5OutOfDataException {
      _decoderEnded = true;
    }
    if (_writeIndex == _readIndex) {
      if (_decoderEnded) {
        throw const _Rar5OutOfDataException();
      }
      throw const FormatException('RAR5: decoder made no progress.');
    }
  }

  // The port of decoder50.fill: symbols until the window is full,
  // crossing block boundaries as they end.
  void _fillFromDecoder() {
    while (_writeIndex < _window.length) {
      int symbol;
      try {
        symbol = _mainDecoder.readSymbol(_bitReader!);
      } on _Rar5BlockEndException {
        if (_lastBlock) {
          throw const _Rar5OutOfDataException();
        }
        _readBlockHeader();
        continue;
      }

      if (symbol < 256) {
        _writeByte(symbol);
      } else if (symbol >= 262) {
        _decodeOffset(symbol - 262);
      } else if (symbol >= 258) {
        _decodeLength(symbol - 258);
      } else if (symbol == 257) {
        _copyBytes(_length, _offsets[0]);
      } else {
        // symbol == 256: filter marker.
        _readFilter();
      }
    }
  }

  // The port of decoder50.readBlockHeader.
  void _readBlockHeader() {
    final flags = _bitReader!.readByte();

    final byteCount = ((flags >> 3) & 3) + 1;
    if (byteCount == 4) {
      throw const FormatException('RAR5: corrupt block header.');
    }

    final checksum = _bitReader!.readByte();

    final extraBits = (flags & 0x07) + 1;
    var blockBytes = 0;
    var sum = 0x5A ^ flags;
    for (var i = 0; i < byteCount; i++) {
      final byte = _bitReader!.readByte();
      sum ^= byte;
      blockBytes |= byte << (i * 8);
    }
    if (sum != checksum) {
      throw const FormatException('RAR5: corrupt block header.');
    }
    final blockBits = extraBits + (blockBytes - 1) * 8;

    _bitReader!.setLimit(blockBits);
    _lastBlock = flags & 0x40 > 0;

    if (flags & 0x80 > 0) {
      try {
        _readCodeLengthTable(_bitReader!, _codeLength);
      } on _Rar5BlockEndException {
        // A table read that hits the block limit mirrors the reference
        // decoder: the stream ends cleanly when this block is the last
        // one; anywhere else it is corruption.
        if (_lastBlock) throw const _Rar5OutOfDataException();
        throw const FormatException('RAR5: corrupt block header.');
      }
      var cursor = 0;
      _mainDecoder.init(_codeLength.sublist(cursor, _mainSize5));
      cursor += _mainSize5;
      _offsetDecoder.init(_codeLength.sublist(cursor, cursor + _offsetSize5));
      cursor += _offsetSize5;
      _lowOffsetDecoder.init(_codeLength.sublist(cursor, cursor + _lowoffsetSize5));
      cursor += _lowoffsetSize5;
      _lengthDecoder.init(_codeLength.sublist(cursor));
    }
  }

  // The port of decoder50.decodeLength: reuse a recent offset.
  void _decodeLength(final int slot) {
    final offset = _offsets[slot];
    for (var i = slot; i > 0; i--) {
      _offsets[i] = _offsets[i - 1];
    }
    _offsets[0] = offset;

    final lengthSlot = _lengthDecoder.readSymbol(_bitReader!);
    _length = _slotToLength(_bitReader!, lengthSlot);
    _copyBytes(_length, _offsets[0]);
  }

  // The port of decoder50.decodeOffset: read a distance, then a length.
  //
  // Wide reads are split exactly like the reference decoder's 32-bit
  // path so VM and web arithmetic stay identical, and the large slot
  // shift becomes a multiplication because Dart-on-JS shifts are
  // 32-bit.
  void _decodeOffset(final int slot) {
    var length = _slotToLength(_bitReader!, slot);

    var offset = 1;
    final offsetSlot = _offsetDecoder.readSymbol(_bitReader!);
    if (offsetSlot < 4) {
      offset += offsetSlot;
    } else {
      var bitCount = offsetSlot ~/ 2 - 1;
      final base = 2 | (offsetSlot & 1);
      offset += base * (1 << bitCount);

      if (bitCount >= 4) {
        bitCount -= 4;
        if (bitCount > 24) {
          offset += _bitReader!.readBits(24) * (1 << (4 + bitCount - 24));
          bitCount -= 24;
        }
        if (bitCount > 0) {
          offset += _bitReader!.readBits(bitCount) << 4;
        }
        offset += _lowOffsetDecoder.readSymbol(_bitReader!);
      } else if (bitCount > 0) {
        offset += _bitReader!.readBits(bitCount);
      }
    }
    if (offset > 0x100) {
      length++;
      if (offset > 0x2000) {
        length++;
        if (offset > 0x40000) {
          length++;
        }
      }
    }
    for (var i = 3; i > 0; i--) {
      _offsets[i] = _offsets[i - 1];
    }
    _offsets[0] = offset;
    _length = length;
    _copyBytes(_length, _offsets[0]);
  }

  // The port of decoder50.readFilter.
  void _readFilter() {
    final offset = _readFilterData(_bitReader!);
    final length = _readFilterData(_bitReader!);
    final filterType = _bitReader!.readBits(3);

    final _Rar5FilterKind kind;
    var param = 0;
    switch (filterType) {
      case 0:
        kind = _Rar5FilterKind.delta;
        param = _bitReader!.readBits(5) + 1;
      case 1:
        kind = _Rar5FilterKind.e8;
      case 2:
        kind = _Rar5FilterKind.e8e9;
      case 3:
        kind = _Rar5FilterKind.arm;
      default:
        throw FormatException('RAR5: unknown filter type $filterType.');
    }

    _queueFilter(_Rar5FilterBlock(offset, length, kind, param));
  }

  // The port of decodeReader.queueFilter: offsets become relative to
  // the previous queue entry, masked into the window.
  void _queueFilter(final _Rar5FilterBlock filter) {
    if (_filters.length >= _maxQueuedFilters) {
      throw const FormatException('RAR5: too many queued filters.');
    }
    filter.offset += _writeIndex - _readIndex;
    for (final queued in _filters) {
      if (filter.offset < queued.offset) {
        throw const FormatException('RAR5: invalid filter offset.');
      }
      filter.offset -= queued.offset;
    }
    filter.offset %= _window.length;
    if (filter.offset < 0) filter.offset += _window.length;
    var length = filter.length % _window.length;
    if (length < 0) length += _window.length;
    // filterBlock.length is final in the Go original; carry the masked
    // length through the queue entry itself.
    _filters.add(_Rar5FilterBlock(filter.offset, length, filter.kind, filter.param));
  }

  // Applies one filter to a window copy — the V5 filters of
  // filters.go. The buffer is a private copy, so in-place mutation is
  // safe; delta writes into a second buffer because it reads ahead of
  // its writes.
  Uint8List _applyFilter(final _Rar5FilterBlock block, final Uint8List buffer) {
    switch (block.kind) {
      case _Rar5FilterKind.delta:
        return _filterDelta(block.param, buffer);
      case _Rar5FilterKind.e8:
        return _filterE8(0xE8, buffer, _total);
      case _Rar5FilterKind.e8e9:
        return _filterE8(0xE9, buffer, _total);
      case _Rar5FilterKind.arm:
        return _filterArm(buffer, _total);
    }
  }

  // The port of decodeReader.writeByte.
  void _writeByte(final int byte) {
    _window[_writeIndex++] = byte;
  }

  // The port of decodeReader.copyBytes, overflow included.
  void _copyBytes(int length, final int offset) {
    length = (_window.length + length) % _window.length;
    final writeEnd = _writeIndex + length < _window.length ? _writeIndex + length : _window.length;
    var source = (_writeIndex - offset) % _window.length;
    if (source < 0) {
      // A corrupt offset can wrap past the window start.
      source += _window.length;
    }
    if (source == _writeIndex) {
      length -= writeEnd - _writeIndex;
      _writeIndex = writeEnd;
      source = 0;
    } else if (source > _writeIndex) {
      final copied = writeEnd - _writeIndex < _window.length - source
          ? writeEnd - _writeIndex
          : _window.length - source;
      _window.setRange(_writeIndex, _writeIndex + copied, _window, source);
      _writeIndex += copied;
      length -= copied;
      source = 0;
    }
    while (_writeIndex < writeEnd) {
      final copied = writeEnd - _writeIndex < _writeIndex - source
          ? writeEnd - _writeIndex
          : _writeIndex - source;
      _window.setRange(_writeIndex, _writeIndex + copied, _window, source);
      _writeIndex += copied;
      length -= copied;
      source += copied;
    }
    _overflowLength = length;
    _overflowOffset = offset;
  }
}

// The delta filter (filters.go filterDelta): per-channel running
// difference.
Uint8List _filterDelta(final int channels, final Uint8List buffer) {
  final result = Uint8List(buffer.length);
  var input = 0;
  for (var channel = 0; channel < channels; channel++) {
    var sum = 0;
    for (var i = channel; i < result.length; i += channels) {
      sum = (sum - buffer[input++]) & 0xFF;
      result[i] = sum;
    }
  }

  return result;
}

// The E8/E9 restoration filter (filters.go filterE8): v5 converts
// addresses against the file-size constant, with 32-bit signed
// arithmetic exactly like the Go original (truncated modulo, wrap on
// overflow).
Uint8List _filterE8(final int secondTrigger, final Uint8List buffer, final int fileOffset) {
  var offset = _toInt32(fileOffset);
  final triggerEnd = buffer.length - 5;

  for (var i = 0; i <= triggerEnd;) {
    final byte = buffer[i];
    offset = _toInt32(offset + 1);
    if (byte == 0xE8 || byte == secondTrigger) {
      final converted = offset.remainder(_filterFileSize);
      var address =
          buffer[i + 1] | (buffer[i + 2] << 8) | (buffer[i + 3] << 16) | (buffer[i + 4] << 24);
      if (address >= 0x80000000) address -= 0x100000000;
      if (address < 0) {
        if (_toInt32(address + converted) >= 0) {
          _putUint32(buffer, i + 1, (address + _filterFileSize) & 0xFFFFFFFF);
        }
      } else if (address < _filterFileSize) {
        _putUint32(buffer, i + 1, (address - converted) & 0xFFFFFFFF);
      }
      offset = _toInt32(offset + 4);
      i += 5;
    } else {
      i++;
    }
  }

  return buffer;
}

/// Wraps [value] to a signed 32-bit integer, matching Go's `int32`.
int _toInt32(final int value) {
  var result = value & 0xFFFFFFFF;
  if (result >= 0x80000000) result -= 0x100000000;

  return result;
}

void _putUint32(final Uint8List buffer, final int offset, final int value) {
  buffer[offset] = value & 0xFF;
  buffer[offset + 1] = (value >> 8) & 0xFF;
  buffer[offset + 2] = (value >> 16) & 0xFF;
  buffer[offset + 3] = (value >> 24) & 0xFF;
}

// The ARM call-address restoration filter (filters.go filterARM).
Uint8List _filterArm(final Uint8List buffer, final int fileOffset) {
  for (var i = 0; buffer.length - i > 3; i += 4) {
    if (buffer[i + 3] == 0xEB) {
      var value = buffer[i] + buffer[i + 1] * 0x100 + buffer[i + 2] * 0x10000;
      value = (value - ((fileOffset + i) >> 2)) & 0xFFFFFF;
      buffer[i] = value & 0xFF;
      buffer[i + 1] = (value >> 8) & 0xFF;
      buffer[i + 2] = (value >> 16) & 0xFF;
    }
  }

  return buffer;
}

/// Decodes one standalone RAR 5 compression stream into exactly
/// [uncompressedSize] bytes — a fresh dictionary, no solid
/// continuation.
///
/// [packed] is the entry's data area, [windowSize] the declared
/// dictionary size (0x20000 << dictExp). Every allocation is bounded by
/// those two values; corruption throws [FormatException]. Solid chains
/// go through [Rar5SolidDecoder] instead so the dictionary continues.
Uint8List decodeRar5Stream({
  required final Uint8List packed,
  required final int uncompressedSize,
  required final int windowSize,
}) {
  return Rar5SolidDecoder().decodeEntry(
    packed: packed,
    uncompressedSize: uncompressedSize,
    windowSize: windowSize,
    solid: false,
  );
}

/// A captured [Rar5SolidDecoder] dictionary state: the circular window,
/// Huffman tables, recent offsets, filter queue, and copy overflow —
/// everything a solid continuation decodes against. Immutable by
/// convention: [Rar5SolidDecoder.restoreState] deep-copies on restore,
/// so one capture can serve repeated backward seeks.
final class Rar5SolidState {
  Rar5SolidState._({
    required Uint8List window,
    required int readIndex,
    required int writeIndex,
    required _Rar5Huffman main,
    required _Rar5Huffman offset,
    required _Rar5Huffman lowOffset,
    required _Rar5Huffman length,
    required Uint8List codeLength,
    required Int32List offsets,
    required int matchLength,
    required bool lastBlock,
    required List<_Rar5FilterBlock> filters,
    required int overflowLength,
    required int overflowOffset,
  }) : _window = window,
       _readIndex = readIndex,
       _writeIndex = writeIndex,
       _main = main,
       _offset = offset,
       _lowOffset = lowOffset,
       _length = length,
       _codeLength = codeLength,
       _offsets = offsets,
       _matchLength = matchLength,
       _lastBlock = lastBlock,
       _filters = filters,
       _overflowLength = overflowLength,
       _overflowOffset = overflowOffset;

  final Uint8List _window;
  final int _readIndex;
  final int _writeIndex;
  final _Rar5Huffman _main;
  final _Rar5Huffman _offset;
  final _Rar5Huffman _lowOffset;
  final _Rar5Huffman _length;
  final Uint8List _codeLength;
  final Int32List _offsets;
  final int _matchLength;
  final bool _lastBlock;
  final List<_Rar5FilterBlock> _filters;
  final int _overflowLength;
  final int _overflowOffset;

  /// Memory weight of the snapshot: the window dominates; the tables
  /// and queues are bounded constants per dictionary.
  int get weightBytes => _window.length;
}
