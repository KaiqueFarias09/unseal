import 'dart:typed_data';

import 'jpx_exception.dart';

/// Bit reader for JPEG 2000 packet headers (OpenJPEG `bio`): a 16-bit
/// shift register fed one byte at a time, where a queued 0xFF keeps
/// only 7 bits because the marker's high bits are not data.
final class JpxBitReader {
  /// Bounds `data` to the `length` bytes at `offset` before any read.
  JpxBitReader(this._data, this._offset, this._length) : _cursor = 0, _buffer = 0, _count = 0 {
    if (_offset < 0 || _length < 0 || _offset + _length > _data.length) {
      throw const JpxException('Packet header escapes the tile-part.');
    }
  }

  final Uint8List _data;
  final int _offset;
  final int _length;
  int _cursor;
  int _buffer;
  int _count;

  /// Bytes consumed so far (the value `opj_bio_numbytes` returns).
  int get consumed => _cursor;

  bool _byteIn() {
    _buffer = (_buffer << 8) & 0xFFFF;
    _count = _buffer == 0xFF00 ? 7 : 8;
    if (_cursor >= _length) {
      return false;
    }
    _buffer |= _data[_offset + _cursor++];
    return true;
  }

  int _bit() {
    if (_count == 0) {
      _byteIn();
    }
    _count--;
    return (_buffer >> _count) & 1;
  }

  /// Reads [bits] bits, most significant first. Reading past the
  /// available bytes yields zero bits (OpenJPEG behavior), but the
  /// packet is still rejected downstream when the header lies about
  /// lengths.
  int read(final int bits) {
    var value = 0;
    for (var i = bits - 1; i >= 0; i--) {
      value |= _bit() << i;
    }
    return value;
  }

  /// Skips to the next byte boundary, consuming a queued 0xFF.
  void align() {
    if ((_buffer & 0xFF) == 0xFF) {
      _byteIn();
    }
    _count = 0;
  }
}
