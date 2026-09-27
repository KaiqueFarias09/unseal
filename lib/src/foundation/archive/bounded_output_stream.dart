import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../exceptions/unseal_exception.dart';

/// OutputStream that aborts, with a typed error, the moment a write would
/// push the entry past [maxBytes] — bounding zip-bomb expansion DURING
/// inflation instead of after it.
final class BoundedOutputStream extends OutputStream {
  /// Creates a stream that accepts at most [maxBytes] bytes.
  BoundedOutputStream(this.maxBytes)
    : _buffer = Uint8List(math.min(maxBytes, 0x8000)),
      super(byteOrder: ByteOrder.littleEndian);

  Uint8List _buffer;

  /// The inflation output cap.
  final int maxBytes;

  @override
  int length = 0;

  void _ensureCapacity(final int additionalBytes) {
    if (additionalBytes < 0 || length + additionalBytes > maxBytes) {
      throw InvalidBookException('Zip entry exceeds the bounded expansion limit.');
    }
  }

  void _grow(final int required) {
    if (required <= _buffer.length) return;
    var capacity = _buffer.length;
    while (capacity < required) {
      capacity = math.min(maxBytes, capacity * 2);
    }
    final grown = Uint8List(capacity);
    grown.setRange(0, length, _buffer);
    _buffer = grown;
  }

  @override
  void writeByte(final int value) {
    _ensureCapacity(1);
    _grow(length + 1);
    _buffer[length++] = value;
  }

  @override
  void writeBytes(final List<int> bytes, {final int? length}) {
    final count = length ?? bytes.length;
    _ensureCapacity(count);
    _grow(this.length + count);
    _buffer.setRange(this.length, this.length + count, bytes);
    this.length += count;
  }

  @override
  void writeStream(final InputStream stream) {
    _ensureCapacity(stream.length);
    _grow(length + stream.length);
    _buffer.setRange(length, length + stream.length, stream.toUint8List());
    length += stream.length;
  }

  @override
  void writeBackReference(final int distance, final int count) {
    _ensureCapacity(count);
    _grow(length + count);
    final source = length - distance;
    if (distance >= count) {
      _buffer.setRange(length, length + count, _buffer, source);
    } else {
      var from = source;
      var to = length;
      final end = length + count;
      while (to < end) {
        _buffer[to++] = _buffer[from++];
      }
    }
    length += count;
  }

  @override
  void clear() => length = 0;

  @override
  void flush() {}

  @override
  Uint8List subset(int start, [int? end]) {
    if (start < 0) start = length + start;

    end ??= length;
    if (end < 0) end = length + end;

    return Uint8List.view(_buffer.buffer, _buffer.offsetInBytes + start, end - start);
  }
}
