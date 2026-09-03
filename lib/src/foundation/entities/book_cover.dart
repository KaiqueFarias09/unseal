import 'dart:typed_data';

import 'package:e_livre/src/foundation/utils/image_sniffer.dart';

/// A book cover: raw bytes plus the detected image type.
final class BookCover {
  /// Creates a [BookCover].
  const BookCover({required this.bytes, required this.type, this.width, this.height});

  /// The raw image bytes.
  final Uint8List bytes;

  /// The detected image format.
  final ImageType type;

  /// Image width in pixels, when the header was readable.
  final int? width;

  /// Image height in pixels, when the header was readable.
  final int? height;

  /// The usual file extension for this image (e.g. `jpg`).
  String get fileExtension => type.fileExtension;

  /// The image MIME type (e.g. `image/jpeg`).
  String get mimeType => type.mimeType;

  @override
  String toString() =>
      'BookCover(type: ${type.name}, bytes: ${bytes.length}, '
      'size: ${width ?? '?'}x${height ?? '?'})';
}
