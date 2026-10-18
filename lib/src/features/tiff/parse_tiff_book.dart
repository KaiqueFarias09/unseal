import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import '../../foundation/images/image_dimensions.dart';
import '../../foundation/images/image_type_sniffer.dart';
import 'tiff_book.dart';
import 'tiff_container.dart';
import 'tiff_exception.dart';
import 'tiff_limits.dart';
import 'tiff_page_decoder.dart';

/// Decodes every page of a TIFF or BigTIFF document into displayable
/// BMP/JPEG page images.
///
/// Supported codecs are explicit — baseline none, PackBits, LZW and
/// Deflate (with horizontal differencing), CCITT modified Huffman,
/// Group 3, and Group 4 in strips or tiles, plus single self-contained
/// JPEG strips — and everything else fails with
/// [TiffUnsupportedCodecException]. Malformed or excessive input fails
/// with [TiffException] before any allocation its declared sizes would
/// trigger.
TiffBook parseTiffBook(final Uint8List bytes) {
  final container = _openContainer(bytes);
  final budget = TiffDecodeBudget();
  final pages = <TiffPage>[];
  var pageNumber = 0;
  for (final ifd in container.pageDirectories) {
    pageNumber++;
    final image = decodeTiffPage(container, ifd, budget: budget);
    final isJpeg = image.jpeg != null;
    final extension = isJpeg ? 'jpg' : 'bmp';
    pages.add(
      TiffPage(
        width: image.width,
        height: image.height,
        dpi: image.dpi,
        image: BinaryFile(
          content: isJpeg ? image.jpeg! : image.bmp!,
          name: 'page-$pageNumber.$extension',
          type: extension,
          path: 'images/page-$pageNumber.$extension',
        ),
      ),
    );
  }

  final firstImage = pages.first.image.content;
  final size = imageSize(firstImage);
  final imageType = sniffImageType(firstImage);
  if (size == null || imageType == null) {
    throw const TiffException('Decoded TIFF page image has an invalid image header.');
  }
  return TiffBook(
    bytes: bytes,
    pages: pages,
    metadata: _readMetadata(
      container,
      cover: BookCover(bytes: firstImage, type: imageType, width: size.width, height: size.height),
    ),
    isBigTiff: container.isBigTiff,
  );
}

/// Validates the container and reads TIFF metadata without decoding
/// image data.
BookMetadata readTiffMetadata(final Uint8List bytes) {
  final container = _openContainer(bytes);
  return _readMetadata(container);
}

TiffContainer _openContainer(final Uint8List bytes) {
  if (bytes.length > tiffMaxInputBytes) {
    throw const TiffException('TIFF file exceeds the 128 MiB input limit.');
  }
  final container = TiffContainer(bytes);
  if (container.pageDirectories.isEmpty) {
    throw const TiffException('TIFF document has no pages.');
  }
  return container;
}

/// Maps IFD 0 metadata tags onto the common model, best effort:
/// ImageDescription, DateTime, Software, Artist, and Copyright.
BookMetadata _readMetadata(final TiffContainer container, {final BookCover? cover}) {
  final ifd = container.pageDirectories.first;
  final description = _asciiTag(container, ifd, 270);
  final dateTime = _parseTiffDateTime(_asciiTag(container, ifd, 306));
  final software = _asciiTag(container, ifd, 305);
  final artist = _asciiTag(container, ifd, 315);
  final rights = _asciiTag(container, ifd, 33432);

  return BookMetadata(
    format: BookFormat.tiff,
    description: description,
    publishedAt: dateTime,
    bookProducer: software,
    authors: artist == null ? const <String>[] : <String>[artist],
    rights: rights,
    cover: cover,
  );
}

String? _asciiTag(final TiffContainer container, final TiffIfd ifd, final int tag) {
  final entry = ifd[tag];
  if (entry == null) return null;
  final value = container.readAscii(entry);
  return value.isEmpty ? null : value;
}

/// Parses the TIFF `YYYY:MM:DD HH:MM:SS` date-time convention;
/// anything unparsable is ignored (best-effort metadata).
DateTime? _parseTiffDateTime(final String? value) {
  if (value == null || value.length != 19) return null;
  int? field(final int start, final int end) => int.tryParse(value.substring(start, end));
  final year = field(0, 4);
  final month = field(5, 7);
  final day = field(8, 10);
  final hour = field(11, 13);
  final minute = field(14, 16);
  final second = field(17, 19);
  if (year == null ||
      month == null ||
      day == null ||
      hour == null ||
      minute == null ||
      second == null) {
    return null;
  }
  if (value[4] != ':' ||
      value[7] != ':' ||
      value[10] != ' ' ||
      value[13] != ':' ||
      value[16] != ':') {
    return null;
  }
  try {
    return DateTime(year, month, day, hour, minute, second);
  } on ArgumentError {
    return null;
  }
}
