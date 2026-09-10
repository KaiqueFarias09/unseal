import '../entities/entities.dart';
import 'image_dimensions.dart';
import 'image_type_sniffer.dart';

/// Extracts a cover-like image from a list of image files.
BinaryFile? firstImageCover(final List<BinaryFile> images) {
  for (final image in images) {
    if (sniffImageType(image.content) != null) return image;
  }

  return null;
}

/// Converts an image file into the format-agnostic cover value.
BookCover? coverFromBinary(final BinaryFile? image) {
  if (image == null) return null;

  final type = sniffImageType(image.content);
  if (type == null) return null;

  final size = imageSize(image.content);

  return BookCover(bytes: image.content, type: type, width: size?.width, height: size?.height);
}
