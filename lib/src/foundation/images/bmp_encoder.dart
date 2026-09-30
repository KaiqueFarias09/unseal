import 'dart:typed_data';

/// The fixed size of the BITMAPINFOHEADER BMP payload written here:
/// 14-byte file header + 40-byte info header.
const int bmpHeaderBytes = 54;

/// The 4-byte-aligned stride of one bottom-up 24-bit BMP row.
int bmpRowStride(final int width) {
  final unpaddedBytes = width * 3;
  return (unpaddedBytes + 3) & ~3;
}

/// Writes a 24-bit uncompressed BITMAPINFOHEADER BMP header into
/// [output], which must be at least [bmpHeaderBytes] bytes long.
void writeBmpHeader(
  final Uint8List output,
  final int width,
  final int height,
  final int pixelBytes,
) {
  final view = ByteData.sublistView(output);
  output[0] = 0x42;
  output[1] = 0x4D;
  view.setUint32(2, output.length, Endian.little);
  view.setUint32(10, bmpHeaderBytes, Endian.little);
  view.setUint32(14, 40, Endian.little);
  view.setInt32(18, width, Endian.little);
  view.setInt32(22, height, Endian.little);
  view.setUint16(26, 1, Endian.little);
  view.setUint16(28, 24, Endian.little);
  view.setUint32(34, pixelBytes, Endian.little);
}

/// Encodes a top-down, row-major RGB888 raster as a bottom-up 24-bit
/// BMP — the displayable image format used by the format decoders.
///
/// [rgb] must hold exactly `width * height * 3` interleaved bytes.
/// Callers own the allocation policy; this only validates geometry so
/// a mismatched length cannot read out of bounds.
Uint8List encodeRgb24Bmp({
  required final int width,
  required final int height,
  required final Uint8List rgb,
}) {
  if (width < 1 || height < 1) {
    throw ArgumentError('BMP dimensions must be positive.');
  }
  final stride = bmpRowStride(width);
  final pixelBytes = stride * height;
  if (rgb.length != width * height * 3) {
    throw ArgumentError('BMP RGB length does not match its dimensions.');
  }

  final output = Uint8List(bmpHeaderBytes + pixelBytes);
  writeBmpHeader(output, width, height, pixelBytes);
  for (var y = 0; y < height; y++) {
    final sourceRow = y * width * 3;
    final targetRow = bmpHeaderBytes + (height - 1 - y) * stride;
    for (var x = 0; x < width; x++) {
      final source = sourceRow + x * 3;
      final target = targetRow + x * 3;
      output[target] = rgb[source + 2];
      output[target + 1] = rgb[source + 1];
      output[target + 2] = rgb[source];
    }
  }
  return output;
}
