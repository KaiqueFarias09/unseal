import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../entities/entities.dart';
import '../exceptions/pdf_exception.dart';
import '../header/pdf_document.dart';
import '../reader/pdf_metadata.dart';
import '../reader/pdf_outline.dart';
import '../reader/pdf_page_tree.dart';

/// Parses a PDF document from raw [bytes].
///
/// Reads the structure — cross-reference, page tree, metadata and
/// outline — and returns the [PdfBook]; reflowed page documents are
/// attached by the extraction layer on top of this foundation.
PdfBook parsePdfBook(final Uint8List bytes) {
  final document = PdfDocument.parse(bytes);
  final pages = PdfPageTree.parse(document);
  if (pages.isEmpty) throw const PdfException('PDF document has no pages.');

  return PdfBook(
    bytes: bytes,
    metadata: PdfMetadataReader.read(document),
    pages: pages,
    navigation: PdfOutlineReader.read(document, pages),
  );
}

/// Reads only the metadata of a PDF document from [bytes].
BookMetadata readPdfMetadata(final Uint8List bytes) {
  return PdfMetadataReader.read(PdfDocument.parse(bytes));
}
