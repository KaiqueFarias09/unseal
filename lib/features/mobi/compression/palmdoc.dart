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
///
/// The output is written into a growable buffer so back references
/// read directly from the bytes already produced — the copy may
/// overlap its own output, which repeats the referenced pattern.
Uint8List decompressPalmdoc(final Uint8List data) {
  var output = Uint8List(data.length + 64);
  var written = 0;

  void ensure(final int extra) {
    final needed = written + extra;
    if (needed <= output.length) {
      return;
    }
    var capacity = output.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    final grown = Uint8List(capacity)..setRange(0, written, output);
    output = grown;
  }

  var i = 0;
  while (i < data.length) {
    var c = data[i++];
    if (c >= 1 && c <= 8) {
      final end = i + c;
      ensure(c);
      while (i < end && i < data.length) {
        output[written++] = data[i++];
      }
    } else if (c <= 0x7F) {
      ensure(1);
      output[written++] = c;
    } else if (c >= 0xC0) {
      ensure(2);
      output[written++] = 0x20;
      output[written++] = c ^ 0x80;
    } else if (i < data.length) {
      c = (c << 8) | data[i++];
      final distance = (c & 0x3FFF) >> 3;
      final length = (c & 7) + 3;
      if (distance <= written) {
        ensure(length);
        var from = written - distance;
        for (var j = 0; j < length; j++) {
          output[written++] = output[from++];
        }
      }
    }
  }
  return Uint8List.sublistView(output, 0, written);
}
