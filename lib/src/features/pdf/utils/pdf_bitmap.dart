import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../exceptions/pdf_exception.dart';

/// A decoded 1-bit-per-pixel PDF image (CCITT facsimile or JBIG2)
/// as packed rows: most significant bit first, samples in the PDF's
/// default `/Decode [0 1]` convention (0 = black, 1 = white), every
/// row padded to a whole number of bytes — exactly what pdf.js's
/// decoders hand back once `/BlackIs1` and `/Decode` are applied.
/// PNG packing lives here so neither codec grows an encoder.
final class PdfBitmap {
  /// Creates a bitmap. [packed] holds [height] rows of
  /// `ceil([width] / 8)` bytes each.
  const PdfBitmap({required this.width, required this.height, required this.packed});

  /// Validates dimensions and row length, left-padding short
  /// payloads with white rows instead of failing the page.
  factory PdfBitmap.fromPacked({
    required final int width,
    required final int height,
    required final Uint8List packed,
  }) {
    if (width <= 0 || height <= 0) {
      throw PdfException('PDF image has invalid dimensions ${width}x$height.');
    }
    final needed = strideFor(width) * height;
    // Corrupt dictionaries can claim absurd geometries; real fax and
    // scan pages are megabytes, so anything larger degrades instead
    // of allocating.
    if (needed > (256 << 20)) {
      throw PdfException('PDF image is too large to decode: ${width}x$height.');
    }
    if (packed.length == needed) {
      return PdfBitmap(width: width, height: height, packed: packed);
    }
    if (packed.length > needed) {
      return PdfBitmap(
        width: width,
        height: height,
        packed: Uint8List.sublistView(packed, 0, needed),
      );
    }
    final padded = Uint8List(needed)..setRange(0, packed.length, packed);
    return PdfBitmap(width: width, height: height, packed: padded);
  }

  /// Bytes per packed row for [width] pixels at 1 bit per pixel.
  static int strideFor(final int width) => (width + 7) >> 3;

  /// Image width in pixels.
  final int width;

  /// Image height in pixel rows.
  final int height;

  /// The packed rows, `ceil(width / 8)` bytes each.
  final Uint8List packed;

  /// Expands the packed rows to one byte per pixel in PNG grayscale
  /// semantics (0 = black, 255 = white), dropping the row padding.
  Uint8List toGrayBytes() {
    final stride = strideFor(width);
    final out = Uint8List(width * height);
    for (var y = 0; y < height; y++) {
      final rowBase = y * stride;
      final outBase = y * width;
      for (var x = 0; x < width; x++) {
        final bit = (packed[rowBase + (x >> 3)] >> (7 - (x & 7))) & 1;
        out[outBase + x] = bit == 1 ? 255 : 0;
      }
    }
    return out;
  }

  /// Encodes the bitmap as an 8-bit grayscale PNG (filter type 0
  /// per scanline; the zlib payload comes from package:archive).
  Uint8List toPngBytes() {
    final gray = toGrayBytes();
    final raw = BytesBuilder(copy: false);
    for (var y = 0; y < height; y++) {
      raw.addByte(0);
      raw.add(Uint8List.sublistView(gray, y * width, (y + 1) * width));
    }

    final ihdr = Uint8List(13);
    _writeUint32(ihdr, 0, width);
    _writeUint32(ihdr, 4, height);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 0; // color type: grayscale

    final out = BytesBuilder(copy: false);
    out.add(_signature);
    out.add(_chunk('IHDR', ihdr));
    out.add(_chunk('IDAT', Uint8List.fromList(ZLibEncoder().encode(raw.toBytes()))));
    out.add(_chunk('IEND', Uint8List(0)));
    return out.toBytes();
  }
}

const List<int> _signature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

Uint8List _chunk(final String type, final Uint8List data) {
  final typeBytes = type.codeUnits;
  final out = BytesBuilder(copy: false);
  final header = Uint8List(8);
  _writeUint32(header, 0, data.length);
  header.setRange(4, 8, typeBytes);
  out.add(header);
  out.add(data);
  final trailer = Uint8List(4);
  _writeUint32(trailer, 0, _crc32(typeBytes, data));
  out.add(trailer);
  return out.toBytes();
}

void _writeUint32(final Uint8List target, final int offset, final int value) {
  target[offset] = (value >> 24) & 0xFF;
  target[offset + 1] = (value >> 16) & 0xFF;
  target[offset + 2] = (value >> 8) & 0xFF;
  target[offset + 3] = value & 0xFF;
}

List<int>? _crcTable;

int _crc32(final List<int> typeBytes, final Uint8List data) {
  _crcTable ??= List<int>.generate(256, (final n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });
  var crc = 0xFFFFFFFF;
  for (final byte in typeBytes) {
    crc = _crcTable![(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  for (final byte in data) {
    crc = _crcTable![(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
