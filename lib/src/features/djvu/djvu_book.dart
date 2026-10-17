import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import 'djvu_page_structure.dart';
import 'djvu_text.dart';

/// One DjVu page with a directly stored JPEG or decoded BMP image.
class DjvuPage {
  /// Creates a decoded page description.
  const DjvuPage({
    required this.width,
    required this.height,
    required this.dpi,
    required this.rotation,
    required this.image,
    required this.text,
    this.textChunk,
    this.encodedTextChunk,
    this.encodedTextChunkCompressed = true,
  });

  /// Original page width, in pixels.
  final int width;

  /// Original page height, in pixels.
  final int height;

  /// Source resolution in dots per inch.
  final int dpi;

  /// Clockwise rotation in degrees from the INFO flags.
  final int rotation;

  /// Displayable JPEG, black-on-white JB2 BMP, or composed IW44 BMP image.
  final BinaryFile image;

  /// Uncompressed TXTa OCR text, when present.
  final String text;

  /// The page's decoded hidden-text chunk — the text plus its zone tree —
  /// when the page stores one. Zones keep the DjVu coordinate system and
  /// both the stored UTF-8 and the canonical UTF-16 ranges of their text.
  final DjvuTextChunk? textChunk;

  /// The page's encoded hidden-text chunk bytes (TXTz BZZ-compressed or
  /// TXTa raw grammar), retained so a wire decode can rebuild
  /// [textChunk]. A view into the source bytes, not a copy.
  final Uint8List? encodedTextChunk;

  /// Whether [encodedTextChunk] is BZZ-compressed (TXTz) or raw (TXTa).
  final bool encodedTextChunkCompressed;
}

/// A DjVu book with directly stored JPEG or decoded page images in reading order.
///
/// The original bytes are retained for consumers that have a dedicated DjVu
/// renderer. Each page also has a JPEG or BMP image in `files.images`, so a reader can
/// display this supported subset without decoding DjVu itself.
class DjvuBook extends Book {
  /// Creates a parsed DjVu book.
  ///
  /// [navigation] carries decoded NAVM bookmarks; it defaults to empty
  /// navigation for documents without an outline chunk.
  DjvuBook({
    required this.bytes,
    required this.pages,
    required this.metadata,
    Navigation? navigation,
  }) : files = Files(
         images: <BinaryFile>[for (final page in pages) page.image],
         html: <TextFile>[
           for (var index = 0; index < pages.length; index++)
             TextFile(
               content:
                   '<html><body><img src="../${pages[index].image.path}" '
                   'width="${pages[index].width}" height="${pages[index].height}" '
                   'alt="DjVu page ${index + 1}">'
                   '${pages[index].text.isEmpty ? '' : '<span hidden>${_escape(pages[index].text)}</span>'}'
                   '</body></html>',
               name: 'page-${index + 1}.html',
               type: 'html',
               path: 'text/page-${index + 1}.html',
             ),
         ],
         css: const <TextFile>[],
         fonts: const <BinaryFile>[],
         others: const <BinaryFile>[],
       ),
       navigation = navigation ?? Navigation(title: '', navPoints: const <NavPoint>[]),
       super(format: BookFormat.djvu);

  /// Complete source bytes, for external DjVu renderers.
  final Uint8List bytes;

  /// Pages in the document's declared reading order.
  final List<DjvuPage> pages;

  /// Format-agnostic metadata.
  @override
  final BookMetadata metadata;

  /// The extracted JPEG/BMP images and optional OCR text files.
  @override
  final Files files;

  /// Navigation decoded from the compressed NAVM outline chunk, when the
  /// document declares one. Bookmark URLs stay verbatim on each point.
  @override
  final Navigation navigation;

  /// Number of displayable pages.
  int get pageCount => pages.length;

  /// The spatial text structure of [pageIndex]'s hidden text, or null when
  /// the page stores no text chunk. The structure binds the page's zones
  /// and coordinates to a canonical text snapshot under the hidden-text
  /// extraction profile.
  DjvuPageStructure? pageStructureAt(final int pageIndex) {
    if (pageIndex < 0 || pageIndex >= pages.length) {
      throw RangeError.index(pageIndex, pages, 'pageIndex');
    }
    final chunk = pages[pageIndex].textChunk;
    if (chunk == null) return null;

    return DjvuPageStructure(
      pageIndex: pageIndex,
      pageCount: pages.length,
      width: pages[pageIndex].width,
      height: pages[pageIndex].height,
      dpi: pages[pageIndex].dpi,
      rotation: pages[pageIndex].rotation,
      chunk: chunk,
      readingOrderPaths: readingOrderPaths,
    );
  }

  /// Every page's spatial structure that has hidden text, in reading
  /// order.
  List<DjvuPageStructure> get pageStructures => <DjvuPageStructure>[
    for (var i = 0; i < pages.length; i++)
      if (pages[i].textChunk != null)
        pageStructureAt(i)!,
  ];

  /// The reading-order paths of this book's HTML page files, paired with
  /// their HTML flag — the occurrence revision's input.
  List<(String, bool)> get readingOrderPaths => <(String, bool)>[
    for (final file in files.html) (file.path, true),
  ];

  /// First page image, used as the cover.
  BinaryFile get cover => pages.first.image;

  /// Whether any page provides uncompressed OCR text.
  bool get hasTextLayer => pages.any((final page) => page.text.trim().isNotEmpty);

  /// HTML pages with a displayable image and optional searchable OCR text.
  @override
  List<ReadingOrderItem> get readingOrder => <ReadingOrderItem>[
    for (final file in files.html) ReadingOrderItem(name: file.path),
  ];
}

String _escape(final String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
