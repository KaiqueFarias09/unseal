import 'dart:typed_data';

/// Decompresses a PalmDoc (LZ77) compressed record.
///
/// Semantics of the compressed stream:
///
/// * `0x01..0x08` — copy the next *n* bytes literally.
/// * `0x00`, `0x09..0x7F` — single literal byte.
/// * `0xC0..0xFF` — a space followed by the byte XORed with `0x80`.
/// * `0x80..0xBF` — back reference pair: 11-bit distance and 3..10
///   byte copy from the already produced output.
Uint8List decompressPalmdoc(final Uint8List data) {
  final output = BytesBuilder(copy: false);
  var i = 0;
  while (i < data.length) {
    var c = data[i++];
    if (c >= 1 && c <= 8) {
      final end = i + c;
      while (i < end && i < data.length) {
        output.addByte(data[i++]);
      }
    } else if (c <= 0x7F) {
      output.addByte(c);
    } else if (c >= 0xC0) {
      output.addByte(0x20);
      output.addByte(c ^ 0x80);
    } else if (i < data.length) {
      c = (c << 8) | data[i++];
      final distance = (c & 0x3FFF) >> 3;
      final length = (c & 7) + 3;
      if (distance <= output.length) {
        output.add(_copyFromSelf(output, distance, length));
      }
    }
  }
  return output.takeBytes();
}

Uint8List _copyFromSelf(
  final BytesBuilder builder,
  final int distance,
  final int length,
) {
  // The source window must be snapshotted because back references may
  // overlap the bytes being produced.
  final source = builder.toBytes();
  final chunk = Uint8List(length);
  for (var i = 0; i < length; i++) {
    chunk[i] = source[source.length - distance + i];
  }
  return chunk;
}
