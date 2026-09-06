import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../entities/entities.dart';
import '../exceptions/pdf_exception.dart';
import '../header/pdf_document.dart';
import '../reader/pdf_content_stream.dart';
import '../reader/pdf_metadata.dart';
import '../reader/pdf_outline.dart';
import '../reader/pdf_page_tree.dart';

/// Parses a PDF document from raw [bytes].
///
/// Reads the structure — cross-reference, page tree, metadata and
/// outline — then extracts every page's text. Reflowed page
/// documents attach on top of this in the reading layer.
PdfBook parsePdfBook(final Uint8List bytes) {
  final document = PdfDocument.parse(bytes);
  final pages = PdfPageTree.parse(document);
  if (pages.isEmpty) throw const PdfException('PDF document has no pages.');

  final extractor = PdfTextExtractor(document);
  final pageTexts = <PdfPageText>[];
  final images = <BinaryFile>[];
  final seenImages = <int>{};
  for (final page in pages) {
    pageTexts.add(
      extractor.extract(
        page,
        onImage: (final objectNumber, final jpegBytes) {
          if (seenImages.contains(objectNumber) || seenImages.length >= 128) return;
          seenImages.add(objectNumber);
          images.add(
            BinaryFile(
              content: jpegBytes,
              name: 'pdf-image-$objectNumber.jpg',
              type: 'jpg',
              path: 'images/pdf-image-$objectNumber.jpg',
            ),
          );
        },
      ),
    );
  }

  final metadata = PdfMetadataReader.read(document);
  final book = PdfBook(
    bytes: bytes,
    metadata: metadata,
    pages: pages,
    pageTexts: pageTexts,
    extractedImages: images,
    navigation: PdfOutlineReader.read(document, pages),
  );

  return book;
}

/// Reads only the metadata of a PDF document from [bytes].
BookMetadata readPdfMetadata(final Uint8List bytes) {
  return PdfMetadataReader.read(PdfDocument.parse(bytes));
}
