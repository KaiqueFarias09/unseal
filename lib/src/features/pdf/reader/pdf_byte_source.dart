import 'dart:typed_data';

/// Bounded byte reads over a PDF document source.
///
/// The object parser pulls only the windows it needs — the
/// cross-reference tail at open, one bounded window per parse step,
/// one stream body per stream — so implementations decide what stays
/// resident: the whole document in memory, or a file handle that
/// seeks. Offsets are absolute file offsets; every xref and object
/// offset the parser resolves stays meaningful against [length].
abstract interface class PdfByteSource {
  /// Total source length in bytes.
  int get length;

  /// Reads exactly [count] bytes at [offset].
  ///
  /// Throws [RangeError] when the range leaves the source; callers
  /// gate offsets against [length] first.
  Uint8List read(final int offset, final int count);

  /// Releases the underlying resource, when there is one.
  void close();
}

/// Source over an in-memory document: reads are views, never copies.
final class MemoryPdfByteSource implements PdfByteSource {
  /// Wraps [bytes] without copying.
  MemoryPdfByteSource(this.bytes);

  /// The wrapped document bytes.
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
