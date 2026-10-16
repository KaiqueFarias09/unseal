import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import 'entities/entities.dart';
import 'exceptions/pdf_exception.dart';
import 'header/pdf_document.dart';
import 'layout/pdf_page_structure.dart';
import 'reader/pdf_byte_source.dart';
import 'reader/pdf_content_stream.dart';
import 'reader/pdf_metadata.dart';
import 'reader/pdf_outline.dart';
import 'reader/pdf_page_tree.dart';
import 'reflow/pdf_reflow.dart';

/// Re-exported so the public PDF entry point carries the mapping
/// vocabulary next to the structures that produce it.
export 'entities/pdf_position.dart'
    show
        PdfMappedPosition,
        PdfPositionAmbiguous,
        PdfPositionMapped,
        PdfPositionMapping,
        PdfPositionMissing,
        PdfPositionMissingReason,
        PdfPositionUnsupported,
        PdfPositionUnsupportedReason,
        PdfSourceRange;

/// Parses a PDF document from raw [bytes].
///
/// Reads the structure — cross-reference, page tree, metadata and
/// outline — then extracts every page's text and layout (words and
/// ruling lines included, the material the page structures build
/// from). Reflowed page documents attach on top of this in the
/// reading layer. Encrypted documents open with [password]; the wrong
/// (or a missing) password throws [PdfEncryptedException] carrying
/// `requiresNonEmptyPassword` semantics. Permission flags are
/// exposed, not enforced.
PdfBook parsePdfBook(final Uint8List bytes, {final String password = ''}) {
  final document = PdfDocument.parse(MemoryPdfByteSource(bytes), password: password);
  final pages = PdfPageTree.parse(document);
  if (pages.isEmpty) throw const PdfException('PDF document has no pages.');

  final metadata = PdfMetadataReader.read(document);
  final navigation = PdfOutlineReader.read(document, pages);
  final extracted = _extractPageContent(document, pages);
  final (pageFiles, canonicalPageTexts) = PdfReflow.apply([
    for (final layout in extracted.pageLayouts) layout.pageText,
  ], pages);

  return PdfBook(
    bytes: bytes,
    metadata: metadata,
    pages: pages,
    pageTexts: canonicalPageTexts,
    pageLayouts: extracted.pageLayouts,
    extractedImages: extracted.images,
    pageFiles: pageFiles,
    navigation: navigation,
  );
}

/// Reads only the metadata of a PDF document from [bytes], opening
/// encrypted documents with [password].
BookMetadata readPdfMetadata(final Uint8List bytes, {final String password = ''}) {
  return PdfMetadataReader.read(PdfDocument.parse(MemoryPdfByteSource(bytes), password: password));
}

/// Builds the stable structure of one page of an eagerly parsed
/// [book]: words, blocks, columns and tables with geometry, the
/// source-line space and the mapping into the book's canonical text.
///
/// The plan reproduces the full-document scan the reflow ran at parse
/// time (deterministic over the same pages), so the structure's
/// canonical profile matches the book's `documentText` space.
///
/// [pageIndex] is zero-based; out-of-range throws [RangeError].
/// Session books (headers with no layouts) throw [StateError] — load
/// structures through `BookSession.loadPdfPageStructure` there.
PdfPageStructure buildPdfPageStructure({
  required final PdfBook book,
  required final int pageIndex,
}) {
  if (pageIndex < 0 || pageIndex >= book.pageCount) {
    throw RangeError.index(pageIndex, book.pages, 'pageIndex');
  }
  if (book.pageLayouts.length <= pageIndex) {
    throw StateError(
      'This PdfBook carries no page layouts (a session header book); '
      'load page structures through BookSession.loadPdfPageStructure',
    );
  }

  final layout = book.pageLayouts[pageIndex];
  final plan = PdfReflowPlan.scan([
    for (final pageLayout in book.pageLayouts) pageLayout.pageText,
  ], book.pages);

  return PdfPageStructure.build(
    pageIndex: pageIndex,
    pageCount: book.pageCount,
    geometry: PdfPageStructure.geometryOfPage(book.pages[pageIndex]),
    sourceLines: layout.pageText.lines,
    words: layout.words,
    rules: layout.rules,
    canonical: book.pageTexts[pageIndex],
    canonicalScope: 'document',
    planRevision: pdfPlanRevision(plan),
    headerSkip: plan.headerSkip,
    footerSkip: plan.footerSkip,
  );
}

({List<PdfPageLayoutExtraction> pageLayouts, List<BinaryFile> images}) _extractPageContent(
  final PdfDocument document,
  final List<PdfPage> pages,
) {
  const maxExtractedImages = 128;
  final extractor = PdfTextExtractor(document);
  final pageLayouts = <PdfPageLayoutExtraction>[];
  final images = <BinaryFile>[];
  final seenImages = <int>{};
  for (final page in pages) {
    pageLayouts.add(
      extractor.extractLayout(
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

  return (pageLayouts: pageLayouts, images: images);
}
