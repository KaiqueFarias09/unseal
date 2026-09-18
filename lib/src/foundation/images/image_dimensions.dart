import 'dart:typed_data';

/// The pixel dimensions of an image, read from its header bytes without decoding the pixel data.
final class ImageSize {
  /// Creates image dimensions in pixels.
  const ImageSize(this.width, this.height);

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  bool operator ==(final Object other) {
    return other is ImageSize && other.width == width && other.height == height;
  }

  @override
  String toString() => 'ImageSize(${width}x$height)';
}

/// Reads the dimensions of an image from [bytes].
///
/// Supports JPEG, PNG, GIF, BMP and WebP (VP8X/VP8/VP8L headers). Returns `null` when the format is
/// missing or the header is truncated.
ImageSize? imageSize(final Uint8List bytes) {
  if (bytes.length < 8) return null;

  // PNG: IHDR
  if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
    if (bytes.length < 24) return null;

    final view = ByteData.sublistView(bytes);

    return ImageSize(view.getUint32(16), view.getUint32(20));
  }

  // GIF: logical screen descriptor
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46) {
    final view = ByteData.sublistView(bytes);

    return ImageSize(view.getUint16(6, Endian.little), view.getUint16(8, Endian.little));
  }

  // BMP: DIB header
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
    if (bytes.length < 26) return null;

    final view = ByteData.sublistView(bytes);
    final width = view.getInt32(18, Endian.little).abs();
    final height = view.getInt32(22, Endian.little).abs();

    return ImageSize(width, height);
  }

  // JPEG: scan SOF markers
  if (bytes[0] == 0xFF && bytes[1] == 0xD8) return _jpegSize(bytes);

  // WebP: RIFF container
  if (bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return _webpSize(bytes);
  }

  return null;
}

ImageSize? _jpegSize(final Uint8List bytes) {
  const sofMarkers = <int>{
    0xC0,
    0xC1,
    0xC2,
    0xC3,
    0xC5,
    0xC6,
    0xC7,
    0xC9,
    0xCA,
    0xCB,
    0xCD,
    0xCE,
    0xCF,
  };

  final view = ByteData.sublistView(bytes);
  var i = 2;
  while (i + 4 <= bytes.length) {
    if (bytes[i] != 0xFF) {
      i++;

      continue;
    }

    final marker = bytes[i + 1];
    if (sofMarkers.contains(marker)) {
      return i + 9 > bytes.length ? null : ImageSize(view.getUint16(i + 7), view.getUint16(i + 5));
    }

    if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    if (i + 4 > bytes.length) return null;

    final segmentLength = view.getUint16(i + 2);
    i += 2 + segmentLength;
  }

  return null;
}

ImageSize? _webpSize(final Uint8List bytes) {
  if (bytes.length < 30) return null;

  final chunk = String.fromCharCodes(bytes.sublist(12, 16));
  switch (chunk) {
    case 'VP8X':
      // Canvas size minus one, 3 bytes little-endian each.
      final width = bytes[24] | (bytes[25] << 8) | (bytes[26] << 16);
      final height = bytes[27] | (bytes[28] << 8) | (bytes[29] << 16);

      return ImageSize(width + 1, height + 1);
    case 'VP8 ':
      // Lossy keyframe: 3-byte frame tag, 3-byte start code, then 14-bit width/height.
      if (bytes.length < 30 || bytes[23] != 0x9D || bytes[24] != 0x01 || bytes[25] != 0x2A) {
        return null;
      }

      final view = ByteData.sublistView(bytes);

      return ImageSize(
        view.getUint16(26, Endian.little) & 0x3FFF,
        view.getUint16(28, Endian.little) & 0x3FFF,
      );
    case 'VP8L':
      // Lossless: signature byte then packed 14-bit width/height.
      if (bytes[20] != 0x2F) return null;

      final b0 = bytes[21];
      final b1 = bytes[22];
      final b2 = bytes[23];
      final b3 = bytes[24];
      final width = (b0 | ((b1 & 0x3F) << 8)) + 1;
      final height = (((b1 >> 6) & 0x03) | (b2 << 2) | ((b3 & 0x0F) << 10)) + 1;

      return ImageSize(width, height);
    default:
      return null;
  }
}
