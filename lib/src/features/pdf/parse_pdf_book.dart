import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import 'entities/entities.dart';
import 'exceptions/pdf_exception.dart';
import 'header/pdf_document.dart';
import 'reader/pdf_content_stream.dart';
import 'reader/pdf_metadata.dart';
import 'reader/pdf_outline.dart';
import 'reader/pdf_page_tree.dart';
import 'reflow/pdf_reflow.dart';

/// Parses a PDF document from raw [bytes].
///
/// Reads the structure — cross-reference, page tree, metadata and
/// outline — then extracts every page's text. Reflowed page
/// documents attach on top of this in the reading layer. Encrypted
/// documents open with [password]; the wrong (or a missing) password
/// throws [PdfEncryptedException] carrying `requiresNonEmptyPassword`
/// semantics. Permission flags are exposed, not enforced.
PdfBook parsePdfBook(final Uint8List bytes, {final String password = ''}) {
  final document = PdfDocument.parse(bytes, password: password);
  final pages = PdfPageTree.parse(document);
  if (pages.isEmpty) throw const PdfException('PDF document has no pages.');

  final metadata = PdfMetadataReader.read(document);
  final navigation = PdfOutlineReader.read(document, pages);
  final extracted = _extractPageContent(document, pages);
  final (pageFiles, canonicalPageTexts) = PdfReflow.apply(extracted.pageTexts, pages);

  return PdfBook(
    bytes: bytes,
    metadata: metadata,
    pages: pages,
    pageTexts: canonicalPageTexts,
    extractedImages: extracted.images,
    pageFiles: pageFiles,
    navigation: navigation,
  );
}

/// Reads only the metadata of a PDF document from [bytes], opening
/// encrypted documents with [password].
BookMetadata readPdfMetadata(final Uint8List bytes, {final String password = ''}) {
  return PdfMetadataReader.read(PdfDocument.parse(bytes, password: password));
}

({List<PdfPageText> pageTexts, List<BinaryFile> images}) _extractPageContent(
  final PdfDocument document,
  final List<PdfPage> pages,
) {
  const maxExtractedImages = 128;
  final extractor = PdfTextExtractor(document);
  final pageTexts = <PdfPageText>[];
  final images = <BinaryFile>[];
  final seenImages = <int>{};
  for (final page in pages) {
    pageTexts.add(
      extractor.extract(
        page,
        onImage: (final objectNumber, final imageBytes, final extension) {
          if (images.length >= maxExtractedImages || !seenImages.add(objectNumber)) return;

          final name = 'pdf-image-$objectNumber.$extension';
          images.add(
            BinaryFile(content: imageBytes, name: name, type: extension, path: 'images/$name'),
          );
        },
      ),
    );
  }

  return (pageTexts: pageTexts, images: images);
}
