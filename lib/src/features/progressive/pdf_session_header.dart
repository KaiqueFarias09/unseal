import 'dart:math' as math;
import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import '../../foundation/text/text_profile.dart';
import '../pdf/entities/pdf_book.dart';
import '../pdf/entities/pdf_page_text.dart';
import '../pdf/exceptions/pdf_exception.dart';
import '../pdf/header/pdf_document.dart';
import '../pdf/layout/pdf_page_structure.dart';
import '../pdf/reader/pdf_byte_source.dart';
import '../pdf/reader/pdf_content_stream.dart';
import '../pdf/reader/pdf_metadata.dart';
import '../pdf/reader/pdf_outline.dart';
import '../pdf/reader/pdf_page_tree.dart';
import '../pdf/reflow/pdf_reflow.dart';
import 'pdf_range_loader.dart';
import 'session_policy.dart';

/// Pages sampled for the reflow plan at open — the same bound the
/// eager `_HeaderFooterScanner` applies.
const _reflowSamplePages = 20;

/// The open result of a PDF progressive session: the header [book]
/// (complete structure, placeholder pages), the pieces the engine
/// needs to materialize content on demand, the sampled reflow plan
/// and the already-extracted sample page texts.
final class PdfSessionHeader {
  PdfSessionHeader._(
    this.book,
    this.source,
    this.document,
    this.extractor,
    this.plan,
    this.sampledPageTexts,
  );

  /// The header book: complete structure, empty content. Pages carry
  /// geometry; `files.html` holds one empty placeholder per page so
  /// the reading order has every page's `page_<i>.html` slot.
  final PdfBook book;

  /// The byte source the document parsed from — the engine keeps it
  /// alive for `loadBytesRange`.
  final PdfByteSource source;

  /// The parsed document structure (xref, security, object store).
  final PdfDocument document;

  /// The extractor bound to [document]; one instance for the whole
  /// session keeps the font caches warm like the eager parse.
  final PdfTextExtractor extractor;

  /// The reflow plan computed over the sampled pages: header/footer
  /// skips identical to the eager parse (the eager scanner samples
  /// the same first pages), dominant font and document statistics
  /// from the sample — a documented delta for documents with more
  /// pages than the sample bound.
  final PdfReflowPlan plan;

  /// Extracted text of the first `min(_reflowSamplePages, pageCount)`
  /// pages, aligned with [PdfBook.pages] from the start. The engine
  /// seeds its cache with these so the first pages materialize
  /// without re-extracting.
  final List<PdfPageText> sampledPageTexts;
}

/// Builds the session header of a PDF document: a [PdfBook] whose
/// structure is complete (page tree, metadata, outline) while every
/// page's content materializes on demand through the session.
///
/// Opening parses the structure and extracts the text of the first
/// [_reflowSamplePages] pages to compute the reflow plan — the
/// bounded cost at open. No image bytes are collected: placements
/// are recorded per page, image files decode on demand.
///
/// Encrypted documents open with [password]; the wrong (or a missing)
/// password throws [PdfEncryptedException] like the eager parse.
PdfSessionHeader buildPdfSessionHeader(
  final PdfByteSource source, {
  final String password = '',
  final SessionPolicy policy = const SessionPolicy(),
}) {
  final document = PdfDocument.parse(source, password: password);
  final pages = PdfPageTree.parse(document);
  if (pages.isEmpty) throw const PdfException('PDF document has no pages.');

  final metadata = PdfMetadataReader.read(document);
  final navigation = PdfOutlineReader.read(document, pages);

  final extractor = PdfTextExtractor(document);
  final sampleCount = math.min(_reflowSamplePages, pages.length);
  final sampledPageTexts = <PdfPageText>[
    for (var i = 0; i < sampleCount; i++) extractor.extract(pages[i], onImage: _discardImage),
  ];
  final plan = PdfReflowPlan.scan(sampledPageTexts, pages.sublist(0, sampleCount));

  final pageFiles = <TextFile>[
    for (var i = 1; i <= pages.length; i++)
      TextFile(content: '', name: 'page_$i.html', type: 'html', path: 'page_$i.html'),
  ];
  final book = PdfBook(
    bytes: Uint8List(0),
    metadata: metadata,
    pages: pages,
    pageFiles: pageFiles,
    navigation: navigation,
    canonicalTextProfile: TextProfile.of(
      algorithm: 'pdf.reflow',
      options: const {'scope': 'session-sample'},
      planRevision: pdfPlanRevision(plan),
    ),
  );

  return PdfSessionHeader._(book, source, document, extractor, plan, sampledPageTexts);
}

/// Builds the same session header over a [PdfRangeLoader]: the parser
/// runs unchanged against the loader's resident byte source, and every
/// step — document structure, page tree, metadata, outline, each
/// sampled page's extraction — replays through the resume loop, so a
/// miss fetches the demanded range through the host's byte source
/// instead of touching a resident file. See
/// `doc/proposals/C01-pdf-byte-source.md` for the boundary contract.
Future<PdfSessionHeader> buildPdfSessionHeaderAsync(
  final PdfRangeLoader loader, {
  final String password = '',
  final SessionPolicy policy = const SessionPolicy(),
}) async {
  final source = PdfResidentByteSource(loader);
  final document = await loader.drive(() => PdfDocument.parse(source, password: password));
  final pages = await loader.drive(() => PdfPageTree.parse(document));
  if (pages.isEmpty) throw const PdfException('PDF document has no pages.');

  final metadata = await loader.drive(() => PdfMetadataReader.read(document));
  final navigation = await loader.drive(() => PdfOutlineReader.read(document, pages));

  final extractor = PdfTextExtractor(document);
  final sampleCount = math.min(_reflowSamplePages, pages.length);
  final sampledPageTexts = <PdfPageText>[
    for (var i = 0; i < sampleCount; i++)
      await loader.drive(() => extractor.extract(pages[i], onImage: _discardImage)),
  ];
  final plan = await loader.drive(
    () => PdfReflowPlan.scan(sampledPageTexts, pages.sublist(0, sampleCount)),
  );

  final pageFiles = <TextFile>[
    for (var i = 1; i <= pages.length; i++)
      TextFile(content: '', name: 'page_$i.html', type: 'html', path: 'page_$i.html'),
  ];
  final book = PdfBook(
    bytes: Uint8List(0),
    metadata: metadata,
    pages: pages,
    pageFiles: pageFiles,
    navigation: navigation,
    canonicalTextProfile: TextProfile.of(
      algorithm: 'pdf.reflow',
      options: const {'scope': 'session-sample'},
      planRevision: pdfPlanRevision(plan),
    ),
  );

  return PdfSessionHeader._(book, source, document, extractor, plan, sampledPageTexts);
}

void _discardImage(final int objectNumber, final Uint8List bytes, final String extension) {
  // Open never collects image bytes: `images/pdf-image-<n>.<ext>`
  // paths decode on demand through the session's resource op.
}
