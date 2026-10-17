/// RAR 5 archive and stream encoder used by the fixture tooling and the
/// browser tests: fixed-length canonical Huffman tables, a greedy LZ
/// matcher, and the delta / E8 / E8-E9 / ARM filters.
///
/// The streams it produces are validated externally against two
/// independent decoders (see `tool/rar5_compare.dart`); the encoder is
/// dev tooling, not part of the parsing library.
library;

import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// One file entry of a fixture archive: path plus decoded content.
final class FixtureEntry {
  FixtureEntry(this.name, this.content);

  final String name;
  final Uint8List content;
}

final class Fixture {
  Fixture(this.name, this.entries, this.archive, this.method, this.dictExp, this.filters);

  final String name;
  final List<FixtureEntry> entries;
  final Uint8List archive;
  final int method;
  final int dictExp;
  final List<String> filters;
}

/// Builds a complete single-volume RAR 5 archive whose file entries are
/// compressed streams produced by [Rar5StreamEncoder].
Uint8List buildRar5Archive({
  required final List<FixtureEntry> entries,
  required final int method,
  required final int dictExp,
  final bool dataCrc = true,
  final int? filterType,
}) {
  final windowSize = 0x20000 << dictExp;
  final body = BytesBuilder();
  body.add([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]);

  // Adds one block: CRC-32 over (type .. extra area end), the size
  // vint, the body, then the data area.
  void block(final int type, final int flags, final List<int> payload, {final List<int>? data}) {
    final typed = <int>[..._vint(type), ..._vint(flags)];
    if (flags & 0x0001 != 0) typed.addAll(_vint(0)); // no extra area
    if (flags & 0x0002 != 0) typed.addAll(_vint(data?.length ?? 0));
    typed.addAll(payload);
    final sizeFieldBytes = _vint(typed.length);
    // The header CRC covers the size field and the typed body, the
    // coverage real archivers write.
    final crc = getCrc32(Uint8List.fromList([...sizeFieldBytes, ...typed]));
    body.add((ByteData(4)..setUint32(0, crc, Endian.little)).buffer.asUint8List());
    body.add(sizeFieldBytes);
    body.add(typed);
    if (data != null) body.add(data);
  }

  // Main archive header: archive flags 0 (single volume, not solid).
  block(1, 0, _vint(0));

  for (final entry in entries) {
    final nameBytes = convert.utf8.encode(entry.name);
    final Uint8List packed;
    final Uint8List target;
    if (method == 0) {
      // Stored entries keep their payload verbatim.
      packed = entry.content;
      target = entry.content;
    } else {
      final encoder = Rar5StreamEncoder(
        entry.content,
        windowSize: windowSize,
        filterType: filterType,
      );
      packed = encoder.encode();
      target = encoder.target;
    }

    final crc = getCrc32(target);
    final fileFlags = dataCrc ? 0x0004 : 0;
    final payload = <int>[
      ..._vint(fileFlags),
      ..._vint(target.length), // unpacked size
      ..._vint(0x20), // attributes
      if (dataCrc) ...[crc & 0xFF, (crc >> 8) & 0xFF, (crc >> 16) & 0xFF, (crc >> 24) & 0xFF],
      ..._vint((method << 7) | (dictExp << 10)), // version 0, not solid
      0, // host OS
      ..._vint(nameBytes.length),
      ...nameBytes,
    ];

    block(2, 0x0002 | (dataCrc ? 0x0004 : 0), payload, data: packed);
  }

  // End of archive: end flags 0.
  block(5, 0, _vint(0));

  return body.toBytes();
}

List<int> _vint(int value) {
  final bytes = <int>[];
  while (true) {
    var byte = value & 0x7F;
    value >>= 7;
    if (value > 0) byte |= 0x80;
    bytes.add(byte);
    if (value == 0) return bytes;
  }
}

/// Encodes one RAR 5 LZ/Huffman stream (algorithm version 0).
///
/// The input is the PRE-FILTER content; with [filterType] set, the
/// decoder's filter pass transforms the decoded stream into [target],
/// which is what the archive declares and what oracles must output.
final class Rar5StreamEncoder {
  Rar5StreamEncoder(
    this._preImage, {
    required this.windowSize,
    this.filterType,
    this.blockOutputSize = 0x4000,
  });

  /// The stream content before the decoder's filter pass.
  final Uint8List _preImage;
  final int windowSize;

  /// 0=delta, 1=E8, 2=E8/E9, 3=ARM; null disables filtering.
  final int? filterType;

  /// Output bytes per block, keeping block transitions frequent.
  final int blockOutputSize;

  static const int _mainSize = 306;
  static const int _offsetSize = 64;
  static const int _lowOffsetSize = 16;
  static const int _lengthSize = 44;
  static const int _minMatch = 4;
  static const int _maxMatch = 4097;
  static const int _filterRegionSize = 0x4000;

  final _Rar5BitWriter _bits = _Rar5BitWriter();
  final Map<int, List<int>> _chains = {};

  int _blocksStarted = 0;
  bool _blockHasTables = false;
  int _outputSinceBlockStart = 0;
  int _position = 0;
  Uint8List _target = Uint8List(0);

  /// The decoded output this stream reproduces (pre-image with the
  /// filter applied).
  Uint8List get target => _target;

  Uint8List encode() {
    _target = filterType == null
        ? Uint8List.fromList(_preImage)
        : _applyForwardFilter(_preImage, filterType!);

    _startBlock();
    var nextRegionStart = filterType == null ? -1 : 0;
    while (_position < _preImage.length) {
      if (nextRegionStart >= 0 && nextRegionStart == _position) {
        final remaining = _preImage.length - _position;
        final regionLength = remaining < _filterRegionSize ? remaining : _filterRegionSize;
        if (regionLength >= 4) {
          _emitFilterMarker(regionLength);
          nextRegionStart = _position + _filterRegionSize;
        } else {
          nextRegionStart = -1;
        }
      }
      var match = _findMatch();
      if (match != null && nextRegionStart >= 0 && _position + match.$1 > nextRegionStart) {
        // Never encode across a filter-region boundary: the marker must
        // be emitted at the region start.
        final trimmed = nextRegionStart - _position;
        match = trimmed >= 4 ? (trimmed, match.$2) : null;
      }
      if (match == null) {
        _emitLiteral(_preImage[_position]);
        _position++;
        _outputSinceBlockStart++;
      } else {
        _emitMatch(match.$1, match.$2);
        _position += match.$1;
        _outputSinceBlockStart += match.$1;
      }
      if (_outputSinceBlockStart >= blockOutputSize && _position < _preImage.length) {
        _endBlock(last: false);
        _startBlock();
      }
    }
    _endBlock(last: true);

    return _bits.takeBytes();
  }

  void _startBlock() {
    _blockHasTables = _blocksStarted == 0;
    if (_blockHasTables) {
      _writeTables();
    }
    _blocksStarted++;
    _outputSinceBlockStart = 0;
  }

  void _endBlock({required final bool last}) {
    _bits.endBlock(lastBlock: last, hasTables: _blockHasTables);
  }

  // Fixed-length canonical tables: every symbol of a table shares one
  // length, so the canonical code of a symbol is its index.
  void _writeTables() {
    // 20 precode lengths, all 5 (32 >= 20 symbols).
    for (var i = 0; i < 20; i++) {
      _bits.writeBits(5, 4);
    }
    // The 430 code lengths through the precode: 9-bit main symbols
    // (512 >= 306), 6-bit offsets (64) and lengths (64 >= 44), 4-bit
    // low offsets (16).
    for (var i = 0; i < _mainSize; i++) {
      _bits.writeBits(9, 5);
    }
    for (var i = 0; i < _offsetSize; i++) {
      _bits.writeBits(6, 5);
    }
    for (var i = 0; i < _lowOffsetSize; i++) {
      _bits.writeBits(4, 5);
    }
    for (var i = 0; i < _lengthSize; i++) {
      _bits.writeBits(6, 5);
    }
  }

  void _emitLiteral(final int byte) {
    _bits.writeBits(byte, 9);
    _indexPosition(_position);
  }

  void _emitMatch(final int length, final int distance) {
    // The decoder grows the slot length for large offsets; pre-adjust
    // so the produced match has exactly [length] bytes.
    final slotValue = length - _offsetLengthAdjust(distance) - 2;
    final lengthSlot = _lengthSlot(slotValue);
    _bits.writeBits(262 + lengthSlot, 9);
    _writeLengthExtra(_bits, lengthSlot, slotValue);
    final distanceField = distance - 1;
    final offsetSlot = _offsetSlot(distanceField);
    _bits.writeBits(offsetSlot, 6);
    _writeOffsetExtra(_bits, offsetSlot, distanceField);
    for (var i = _position; i < _position + length; i++) {
      _indexPosition(i);
    }
  }

  // Filter marker: symbol 256, then region start (0: the region begins
  // at the current write position), the region length, and the type.
  void _emitFilterMarker(final int regionLength) {
    _bits.writeBits(256, 9);
    _writeFilterData(0);
    _writeFilterData(regionLength);
    _bits.writeBits(filterType!, 3);
    if (filterType == 0) {
      _bits.writeBits(2, 5); // delta channel count - 1
    }
  }

  void _writeFilterData(final int data) {
    final bytes = [data & 0xFF, (data >> 8) & 0xFF, (data >> 16) & 0xFF, (data >> 24) & 0xFF];
    var count = 4;
    while (count > 1 && bytes[count - 1] == 0) {
      count--;
    }
    _bits.writeBits(count - 1, 2);
    for (var i = 0; i < count; i++) {
      _bits.writeBits(bytes[i], 8);
    }
  }

  (int, int)? _findMatch() {
    if (_position + 3 >= _preImage.length) return null;
    final chain = _chains[_hash(_position)];
    if (chain == null) return null;

    final limit = _maxMatch < _preImage.length - _position
        ? _maxMatch
        : _preImage.length - _position;
    var bestLength = 0;
    var bestDistance = 0;
    var examined = 0;
    for (var i = chain.length - 1; i >= 0 && examined < 24; i--, examined++) {
      final distance = _position - chain[i];
      if (distance < 1 || distance > windowSize) continue;
      var length = 0;
      while (length < limit) {
        // Overlapping matches repeat like the decoder's copy does.
        final expected = length < distance
            ? _preImage[chain[i] + length]
            : _preImage[_position + length - distance];
        if (expected != _preImage[_position + length]) break;
        length++;
      }
      if (length > bestLength) {
        bestLength = length;
        bestDistance = distance;
        if (length >= limit) break;
      }
    }
    if (bestLength < _minMatch) return null;

    return (bestLength, bestDistance);
  }

  void _indexPosition(final int position) {
    if (position + 3 >= _preImage.length) return;
    _chains.putIfAbsent(_hash(position), () => <int>[]).add(position);
  }

  int _hash(final int position) =>
      (_preImage[position] << 16) | (_preImage[position + 1] << 8) | _preImage[position + 2];

  // Applies the forward filter per region, exactly as the decoder
  // fires its queued regions — including the absolute file offset each
  // region starts at.
  Uint8List _applyForwardFilter(final Uint8List input, final int type) {
    final output = Uint8List.fromList(input);
    var start = 0;
    while (start + 4 <= output.length) {
      final remaining = output.length - start;
      final regionLength = remaining < _filterRegionSize ? remaining : _filterRegionSize;
      final region = Uint8List.sublistView(output, start, start + regionLength);
      switch (type) {
        case 0:
          _forwardDelta(region);
        case 1:
          _forwardE8(region, 0xE8, start);
        case 2:
          _forwardE8(region, 0xE9, start);
        case 3:
          _forwardArm(region, start);
        default:
          throw ArgumentError('unsupported filter type $type');
      }
      start += regionLength;
    }

    return output;
  }
}

/// Per-region filter bodies. They mutate the region view in place.

void _forwardDelta(final Uint8List region) {
  const channels = 3;
  final copy = Uint8List.fromList(region);
  // The source walks sequentially while the destination steps by
  // channel — the region is N planar segments, not interleaved.
  var source = 0;
  for (var channel = 0; channel < channels; channel++) {
    var sum = 0;
    for (var dest = channel; dest < region.length; dest += channels) {
      sum = (sum - copy[source++]) & 0xFF;
      region[dest] = sum;
    }
  }
}

Uint8List _forwardE8(final Uint8List region, final int secondTrigger, final int fileOffset) {
  var offset = fileOffset;
  for (var i = 0; i + 5 <= region.length;) {
    final byte = region[i];
    offset = _toInt32(offset + 1);
    if (byte == 0xE8 || byte == secondTrigger) {
      final converted = offset.remainder(0x1000000);
      var address =
          region[i + 1] | (region[i + 2] << 8) | (region[i + 3] << 16) | (region[i + 4] << 24);
      if (address >= 0x80000000) address -= 0x100000000;
      if (address < 0) {
        if (_toInt32(address + converted) >= 0) {
          _putUint32(region, i + 1, (address + 0x1000000) & 0xFFFFFFFF);
        }
      } else if (address < 0x1000000) {
        _putUint32(region, i + 1, (address - converted) & 0xFFFFFFFF);
      }
      offset = _toInt32(offset + 4);
      i += 5;
    } else {
      i++;
    }
  }

  return region;
}

void _forwardArm(final Uint8List region, final int fileOffset) {
  for (var i = 0; region.length - i > 3; i += 4) {
    if (region[i + 3] == 0xEB) {
      var value = region[i] + region[i + 1] * 0x100 + region[i + 2] * 0x10000;
      value = (value - ((fileOffset + i) >> 2)) & 0xFFFFFF;
      region[i] = value & 0xFF;
      region[i + 1] = (value >> 8) & 0xFF;
      region[i + 2] = (value >> 16) & 0xFF;
    }
  }
}

/// MSB-first bit writer that also frames decoder blocks (flags byte,
/// header checksum, bit limit) the way the format requires.
final class _Rar5BitWriter {
  final BytesBuilder _bytes = BytesBuilder();
  int _current = 0;
  int _pendingBits = 0;
  int _blockStartByte = 0;
  int _totalBits = 0;
  int _blockStartBits = 0;

  void writeBits(final int value, final int count) {
    _totalBits += count;
    for (var i = count - 1; i >= 0; i--) {
      _current = (_current << 1) | ((value >> i) & 1);
      if (++_pendingBits == 8) {
        _bytes.addByte(_current);
        _current = 0;
        _pendingBits = 0;
      }
    }
  }

  /// Closes the current block: the bytes written since the last call
  /// become one framed block whose bit limit ends exactly at the last
  /// written bit. [hasTables] sets the flag that makes the decoder
  /// read fresh code-length tables.
  void endBlock({required final bool lastBlock, required final bool hasTables}) {
    if (_pendingBits > 0) {
      _bytes.addByte(_current << (8 - _pendingBits));
      _current = 0;
      _pendingBits = 0;
    }
    final all = _bytes.takeBytes();
    final previous = Uint8List.sublistView(all, 0, _blockStartByte);
    final payload = Uint8List.sublistView(all, _blockStartByte);
    _blockStartByte = 0;

    final blockBytes = payload.length;
    // The bit limit must end exactly at the last written symbol: any
    // slack lets the decoder manufacture a phantom symbol from the
    // padding, which pushes the output past the declared size. The
    // low flag bits carry the limit's extra bits (1-8) beyond whole
    // bytes.
    final blockBits = _totalBits - _blockStartBits;
    _blockStartBits = _totalBits;
    final extraBits = blockBits - 8 * (blockBytes - 1);
    assert(extraBits >= 1 && extraBits <= 8);
    var flags = extraBits - 1;
    if (hasTables) flags |= 0x80;
    if (lastBlock) flags |= 0x40;

    // Size field: 1-3 little-endian bytes as the flags announce.
    var byteCount = 1;
    if (blockBytes > 0xFFFF) {
      byteCount = 3;
    } else if (blockBytes > 0xFF) {
      byteCount = 2;
    }
    flags |= (byteCount - 1) << 3;

    var checksum = 0x5A ^ flags;
    final sizeBytes = <int>[
      blockBytes & 0xFF,
      (blockBytes >> 8) & 0xFF,
      (blockBytes >> 16) & 0xFF,
    ].sublist(0, byteCount);
    for (final byte in sizeBytes) {
      checksum ^= byte;
    }

    _bytes
      ..add(previous)
      ..addByte(flags)
      ..addByte(checksum)
      ..add(sizeBytes)
      ..add(payload);
    // The next block's payload starts at the current end of the buffer.
    _blockStartByte = _bytes.length;
  }

  Uint8List takeBytes() => _bytes.takeBytes();
}

/// The length bonus the decoder adds for large offsets.
int _offsetLengthAdjust(final int offset) {
  if (offset > 0x40000) return 3;
  if (offset > 0x2000) return 2;
  if (offset > 0x100) return 1;

  return 0;
}

/// Length-table slot covering [value] (the decoded length minus 2) —
/// the inverse of the decoder's `slotToLength`.
int _lengthSlot(final int value) {
  if (value < 8) return value;
  final extraBits = _bitLength(value) - 3;
  final high = value >> extraBits;

  return ((extraBits + 1) << 2) | (high & 3);
}

void _writeLengthExtra(final _Rar5BitWriter writer, final int slot, final int value) {
  if (slot < 8) return;
  final extraBits = slot ~/ 4 - 1;
  if (extraBits > 0) {
    writer.writeBits(value & ((1 << extraBits) - 1), extraBits);
  }
}

/// Offset-table slot covering [value] (the distance minus 1) — the
/// first slot whose range contains it.
int _offsetSlot(final int value) {
  if (value < 4) return value;
  for (var slot = 4; slot < 64; slot++) {
    final bitCount = slot ~/ 2 - 1;
    final base = (2 | (slot & 1)) << bitCount;
    if (value >= base && value < base + (1 << bitCount)) return slot;
  }
  throw ArgumentError('distance out of range: $value');
}

void _writeOffsetExtra(final _Rar5BitWriter writer, final int slot, final int value) {
  if (slot < 4) return;
  var bitCount = slot ~/ 2 - 1;
  final base = (2 | (slot & 1)) << bitCount;
  final extra = value - base;
  if (bitCount >= 4) {
    bitCount -= 4;
    assert(bitCount <= 24, 'fixture distances stay within one split read');
    if (bitCount > 0) {
      writer.writeBits(extra >> 4, bitCount);
    }
    writer.writeBits(extra & 0xF, 4); // low-offset symbol
  } else {
    assert(bitCount == 0 || extra < (1 << bitCount));
    if (bitCount > 0) {
      writer.writeBits(extra, bitCount);
    }
  }
}

int _bitLength(final int value) {
  var length = 0;
  var v = value;
  while (v > 0) {
    length++;
    v >>= 1;
  }

  return length;
}

// Forward filters: exactly the transforms the decoder applies to its
// window copies, so encoder(pre-image) + decoder filter == target.

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
