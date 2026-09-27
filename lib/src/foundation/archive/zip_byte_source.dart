import 'dart:typed_data';

/// Bounded byte reads over a book container source.
///
/// The random-access zip reader pulls only the slices it needs — the
/// central directory at open and one compressed entry per request — so
/// implementations decide what stays resident: compressed bytes in
/// memory, or a file handle that seeks.
abstract interface class ZipByteSource {
  /// Total source length in bytes.
  int get length;

  /// Reads exactly [count] bytes at [offset].
  ///
  /// Throws [RangeError] when the range leaves the source; callers gate
  /// offsets against [length] first.
  Uint8List read(final int offset, final int count);

  /// Releases the underlying resource, when there is one.
  void close();
}

/// Source over an in-memory container: reads are views, never copies.
final class MemoryZipByteSource implements ZipByteSource {
  /// Wraps [bytes] without copying.
  MemoryZipByteSource(this.bytes);

  /// The wrapped container bytes.
  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Uint8List read(final int offset, final int count) {
    RangeError.checkValidRange(offset, offset + count, length, 'offset', 'end');
    if (offset == 0 && count == length) return bytes;

    return Uint8List.sublistView(bytes, offset, offset + count);
  }

  @override
  void close() {}
}
