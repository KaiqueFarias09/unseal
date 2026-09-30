import 'dart:typed_data';

import '../../foundation/entities/entities.dart';

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
