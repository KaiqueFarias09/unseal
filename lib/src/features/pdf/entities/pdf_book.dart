import 'dart:typed_data';

import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';

import 'pdf_page.dart';
import 'pdf_page_text.dart';

/// A parsed PDF document.
///
/// The original [bytes] stay attached: the viewer's facsimile mode
/// re-serves them to the system webview for pixel-faithful page
/// rendering, the same bytes the text layer and reflow were extracted
/// from. `files.html` carries one reflowed page per document page, so
/// `documentText`, search, progression and `TextLocator` offsets all
/// address page `i` through section `i` — one canonical text space
/// shared by both reading modes.
class PdfBook extends Book {
  /// Creates a [PdfBook] from already parsed parts.
  PdfBook({
    required this.bytes,
    required this.metadata,
    required this.pages,
    required this.navigation,
    final BookFormat format = BookFormat.pdf,
    final List<TextFile> pageFiles = const <TextFile>[],
    this.pageTexts = const <PdfPageText>[],
    final List<BinaryFile> extractedImages = const <BinaryFile>[],
  }) : files = Files(
         images: extractedImages,
         css: const [],
         html: pageFiles,
         fonts: const [],
         others: const [],
       ),
       super(format: format);

  /// The full original document bytes (kept for facsimile rendering).
  final Uint8List bytes;

  /// The format-agnostic metadata of this book.
  @override
  final BookMetadata metadata;

  /// The document pages in reading order.
  final List<PdfPage> pages;

  /// The extracted canonical text of each page, aligned with [pages].
  final List<PdfPageText> pageTexts;

  /// The bookmarks outline as navigation.
  @override
  final Navigation navigation;

  /// The reflowed page documents (one per page) and the extracted
  /// JPEG images.
  @override
  final Files files;

  /// Number of document pages.
  int get pageCount => pages.length;

  /// The cover: PDFs carry no raster cover a pure parser can extract,
  /// so the cover stays empty (hosts may raster page 1 themselves).
  final BinaryFile cover = BinaryFile.empty();

  /// Whether text extraction found a usable text layer — scanned
  /// documents without one read in facsimile mode only.
  bool get hasTextLayer => pageTexts.any((final page) => page.text.trim().isNotEmpty);

  /// One reading-order item per page: section `i` is page `i`.
  @override
  List<ReadingOrderItem> get readingOrder => <ReadingOrderItem>[
    for (final file in files.html) ReadingOrderItem(name: file.path),
  ];
}
