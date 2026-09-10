import 'dart:typed_data';

/// Adds MIME-type and filename helpers to [ImageType] values.
extension ImageTypeX on ImageType {
  /// The IANA MIME type for this image format.
  String get mimeType {
    return switch (this) {
      ImageType.jpeg => 'image/jpeg',
      ImageType.png => 'image/png',
      ImageType.gif => 'image/gif',
      ImageType.webp => 'image/webp',
      ImageType.bmp => 'image/bmp',
    };
  }

  /// The usual file extension (without leading dot) for this format.
  String get fileExtension {
    return switch (this) {
      ImageType.jpeg => 'jpg',
      ImageType.png => 'png',
      ImageType.gif => 'gif',
      ImageType.webp => 'webp',
      ImageType.bmp => 'bmp',
    };
  }
}

/// Image formats detectable from magic bytes.
enum ImageType {
  /// JPEG / JFIF.
  jpeg,

  /// Portable Network Graphics.
  png,

  /// Graphics Interchange Format.
  gif,

  /// WebP (RIFF container).
  webp,

  /// Windows Bitmap.
  bmp,
}

/// Detects the image format of [bytes] from its magic bytes.
///
/// Returns `null` when the data does not start with a known image signature. Only the first bytes
/// of the buffer are inspected.
ImageType? sniffImageType(final Uint8List bytes) {
  final length = bytes.length;
  if (length < 3) return null;

  // JPEG: FF D8 FF
  if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return ImageType.jpeg;

  // PNG: 89 50 4E 47 0D 0A 1A 0A
  if (length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0D &&
      bytes[5] == 0x0A &&
      bytes[6] == 0x1A &&
      bytes[7] == 0x0A) {
    return ImageType.png;
  }

  // GIF: GIF87a / GIF89a
  if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
    return ImageType.gif;
  }

  // BMP: 'BM'
  if (bytes[0] == 0x42 && bytes[1] == 0x4D) return ImageType.bmp;

  // WEBP: 'RIFF' .... 'WEBP'
  if (length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return ImageType.webp;
  }

  return null;
}
