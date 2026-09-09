import 'dart:typed_data';

import 'package:e_livre/src/features/pdf/entities/pdf_book.dart';
import 'package:e_livre/src/features/pdf/parse_pdf_book.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';

import 'container/azw4_pdf_extractor.dart';

/// Parses an AZW4 PalmDB/MOBI wrapper by extracting and delegating its PDF
/// payload to the existing PDF reader.
///
/// The returned [PdfBook] keeps [BookFormat.azw4] in both the book and its
/// metadata, while [PdfBook.bytes] contains the extracted PDF rather than the
/// outer PalmDB wrapper so a viewer can render it directly.
PdfBook parseAzw4Book(final Uint8List bytes, {final String password = ''}) {
  final payload = extractAzw4PdfPayload(bytes);
  final pdfBook = parsePdfBook(payload.bytes, password: password);
  final metadata = pdfBook.metadata.copyWith(
    format: BookFormat.azw4,
    title: pdfBook.metadata.title ?? payload.title,
  );

  return PdfBook(
    bytes: payload.bytes,
    metadata: metadata,
    pages: pdfBook.pages,
    navigation: pdfBook.navigation,
    format: BookFormat.azw4,
    pageFiles: pdfBook.files.html,
    pageTexts: pdfBook.pageTexts,
    extractedImages: pdfBook.files.images,
  );
}

/// Reads AZW4 metadata through the same extracted PDF path used by
/// [parseAzw4Book].
BookMetadata readAzw4Metadata(final Uint8List bytes, {final String password = ''}) {
  final payload = extractAzw4PdfPayload(bytes);
  final metadata = readPdfMetadata(payload.bytes, password: password);

  return metadata.copyWith(format: BookFormat.azw4, title: metadata.title ?? payload.title);
}
