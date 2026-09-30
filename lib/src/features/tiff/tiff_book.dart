import 'dart:typed_data';

import '../../foundation/entities/entities.dart';

/// One TIFF page with its decoded displayable image.
class TiffPage {
  /// Creates a decoded page description.
  const TiffPage({
    required this.width,
    required this.height,
    required this.dpi,
    required this.image,
  });

  /// Original page width, in pixels.
  final int width;

  /// Original page height, in pixels.
  final int height;

  /// Source resolution in dots per inch (0 when the file declares no
  /// usable resolution).
  final int dpi;

  /// Displayable page image: a BMP raster or a passed-through JPEG.
  final BinaryFile image;
}

/// A TIFF or BigTIFF book with decoded page images in IFD order.
///
/// Every page also has a BMP or JPEG image in `files.images` plus an
/// HTML wrapper in `files.html`, so reading order, search, and
/// progression work through the common model without a TIFF renderer.
/// TIFF carries no text layer. The original bytes are retained for
/// consumers that have a dedicated TIFF renderer.
class TiffBook extends Book {
  /// Creates a parsed TIFF book.
  TiffBook({
    required this.bytes,
    required this.pages,
    required this.metadata,
    this.isBigTiff = false,
  }) : files = Files(
         images: <BinaryFile>[for (final page in pages) page.image],
         html: <TextFile>[
           for (var index = 0; index < pages.length; index++)
             TextFile(
               content:
                   '<html><body><img src="../${pages[index].image.path}" '
                   'width="${pages[index].width}" height="${pages[index].height}" '
                   'alt="TIFF page ${index + 1}">'
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
       navigation = Navigation(title: metadata.title ?? '', navPoints: const <NavPoint>[]),
       super(format: BookFormat.tiff);

  /// Complete source bytes, for external TIFF renderers.
  final Uint8List bytes;

  /// Pages in IFD-chain order (page 1 first).
  final List<TiffPage> pages;

  /// Format-agnostic metadata.
  @override
  final BookMetadata metadata;

  /// The extracted BMP/JPEG images and one wrapper HTML page each.
  @override
  final Files files;

  /// TIFF navigation. The format carries no table of contents.
  @override
  final Navigation navigation;

  /// Whether the source used 64-bit BigTIFF offsets.
  final bool isBigTiff;

  /// Number of displayable pages.
  int get pageCount => pages.length;

  /// First page image, used as the cover.
  BinaryFile get cover => pages.first.image;

  /// Whether any page provides text. TIFF scans carry none.
  bool get hasTextLayer => false;

  /// HTML pages with a displayable image.
  @override
  List<ReadingOrderItem> get readingOrder => <ReadingOrderItem>[
    for (final file in files.html) ReadingOrderItem(name: file.path),
  ];
}
