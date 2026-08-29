import 'dart:typed_data';

import 'package:e_livre/features/core/utils/image_sniffer.dart';

/// A book cover: raw bytes plus the detected image type.
final class BookCover {
  /// Creates a [BookCover].
  const BookCover({required this.bytes, required this.type});

  /// The raw image bytes.
  final Uint8List bytes;

  /// The detected image format.
  final ImageType type;

  /// The image MIME type (e.g. `image/jpeg`).
  String get mimeType => type.mimeType;

  /// The usual file extension for this image (e.g. `jpg`).
  String get fileExtension => type.fileExtension;

  @override
  String toString() => 'BookCover(type: ${type.name}, bytes: ${bytes.length})';
}
