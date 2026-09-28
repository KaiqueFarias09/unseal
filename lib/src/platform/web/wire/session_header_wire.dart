import 'dart:typed_data';

import '../../../features/comic/entities/comic_book.dart';
import '../../../features/comic/entities/comic_page_info.dart';
import '../../../features/epub/entities/book/book.dart';
import '../../../features/pdf/entities/pdf_book.dart';
import '../../../features/pdf/entities/pdf_page.dart';
import '../../../features/pdf/entities/pdf_page_text.dart';
import '../../../foundation/entities/entities.dart';
import 'book_components_wire.dart';
import 'epub_package_wire.dart';
import 'metadata_wire.dart';

/// Encodes a session header [book] — an [EpubBook], [ComicBook] or
/// [PdfBook] carrying complete structure and an empty file set — into
/// a structured-clone-friendly wire payload.
///
/// This is the shape the `sessionOpen` op replies with. It reuses the
/// component encoders of the full book wire for everything the header
/// actually holds (navigation, cover, container inventory, package,
/// comic metadata and page declarations) and encodes the absent
/// content as structure only: EPUB files never cross, comic pages
/// travel as path/name/type placeholders without a blob each, PDF
/// pages as geometry rows whose content pages stay on the worker. The
/// cover is real content and keeps its blob.
(Map<String, Object?>, List<Object>) encodeSessionHeaderWire(final Book book) {
  final blobs = <Object>[];

  if (book is EpubBook) {
    return (
      <String, Object?>{
        'format': BookFormat.epub.name,
        'navigation': encodeNavigationWireValue(book.navigation),
        'cover': encodeBinaryFileWireValue(book.cover, blobs),
        'archiveEntries': <Map<String, Object?>>[
          for (final entry in book.archiveEntries)
            <String, Object?>{'path': entry.path, 'size': entry.size},
        ],
        'epub': <String, Object?>{
          'spinePaths': book.spinePaths == null ? null : List<String>.of(book.spinePaths!),
          'spineIdrefs': book.spineIdrefs == null ? null : List<String>.of(book.spineIdrefs!),
          // Fixed-layout data crosses only for the few documents that
          // declare it; a reflowable book encodes two empty collections.
          'contentViewports': encodeContentViewportsWireValue(book.contentViewports),
          'nonLinearSpinePaths': List<String>.of(book.nonLinearSpinePaths),
          'package': encodeEpubPackageWireValue(book.package),
          'pageList': book.pageList == null ? null : encodeNavigationWireValue(book.pageList!),
          'landmarks': encodeEpubLandmarksWireValue(book.landmarks),
        },
      },
      blobs,
    );
  }

  if (book is ComicBook) {
    return (
      <String, Object?>{
        'format': book.format.name,
        'cover': encodeBinaryFileWireValue(book.cover, blobs),
        'archiveEntries': <Map<String, Object?>>[
          for (final entry in book.archiveEntries)
            <String, Object?>{'path': entry.path, 'size': entry.size},
        ],
        'metadata': encodeMetadataWireValue(book.metadata, blobs),
        'comic': <String, Object?>{
          'readingDirection': book.readingDirection.name,
          'pages': <Object?>[
            for (final page in book.pages)
              <String, Object?>{'path': page.path, 'name': page.name, 'type': page.type},
          ],
          'pageInfo': <Object?>[
            for (final page in book.pageInfo) encodeComicPageInfoWireValue(page),
          ],
        },
      },
      blobs,
    );
  }

  if (book is PdfBook) {
    return (
      <String, Object?>{
        'format': BookFormat.pdf.name,
        'cover': encodeBinaryFileWireValue(book.cover, blobs),
        // PDFs carry no container inventory; the key stays so every
        // header branch decodes through the same shape.
        'archiveEntries': const <Map<String, Object?>>[],
        'metadata': encodeMetadataWireValue(book.metadata, blobs),
        'navigation': encodeNavigationWireValue(book.navigation),
        'pdf': <String, Object?>{
          // Page geometry in reading order; the content pages stay on
          // the worker and load through the session ops.
          'pages': <Object?>[
            for (final page in book.pages)
              <String, Object?>{
                'objectNumber': page.objectNumber,
                'width': page.width,
                'height': page.height,
                'rotate': page.rotate,
              },
          ],
        },
      },
      blobs,
    );
  }

  throw ArgumentError('Session headers are EPUB, comic or PDF books, got ${book.runtimeType}');
}

/// Decodes a session header [Book] wire payload produced by
/// [encodeSessionHeaderWire]: a real [EpubBook], [ComicBook] or
/// [PdfBook] whose structure is complete and whose content stays
/// empty — content loads through the session ops, never through this
/// payload.
Book decodeSessionHeaderWire(final Map<String, Object?> json, final List<Object> blobs) {
  final format = BookFormat.values.byName(json['format'] as String);
  final cover = decodeBinaryFileWireValue(json['cover'] as Map<String, Object?>?, blobs);
  final archiveEntries = decodeArchiveEntriesWireValue(json['archiveEntries'] as List<Object?>);

  final epub = json['epub'] as Map<String, Object?>?;
  if (epub != null) {
    return EpubBook(
      navigation: decodeNavigationWireValue(json['navigation'] as Map<String, Object?>),
      files: Files.empty(),
      cover: cover,
      package: decodeEpubPackageWireValue(epub['package'] as Map<String, Object?>),
      pageList: epub['pageList'] == null
          ? null
          : decodeNavigationWireValue(epub['pageList'] as Map<String, Object?>),
      landmarks: decodeEpubLandmarksWireValue(epub['landmarks'] as List<Object?>?),
      spinePaths: (epub['spinePaths'] as List<Object?>?)?.cast<String>(),
      spineIdrefs: (epub['spineIdrefs'] as List<Object?>?)?.cast<String>(),
      contentViewports: decodeContentViewportsWireValue(epub['contentViewports']),
      nonLinearSpinePaths:
          (epub['nonLinearSpinePaths'] as List<Object?>?)?.cast<String>().toSet() ??
          const <String>{},
      archiveEntries: archiveEntries,
    );
  }

  final comic = json['comic'] as Map<String, Object?>?;
  if (comic != null) {
    return ComicBook(
      cover: cover,
      metadata: decodeMetadataWireValue(json['metadata'] as Map<String, Object?>, blobs),
      pages: <BinaryFile>[
        for (final page in comic['pages'] as List<Object?>)
          BinaryFile(
            content: Uint8List(0),
            name: (page as Map<String, Object?>)['name'] as String,
            type: page['type'] as String,
            path: page['path'] as String,
          ),
      ],
      format: format,
      readingDirection: ComicReadingDirection.values.byName(comic['readingDirection'] as String),
      pageInfo: <ComicPageInfo>[
        for (final page in comic['pageInfo'] as List<Object?>)
          decodeComicPageInfoWireValue(page as Map<String, Object?>),
      ],
    );
  }

  final pdf = json['pdf'] as Map<String, Object?>?;
  if (pdf != null) {
    final pages = <PdfPage>[
      for (final page in pdf['pages'] as List<Object?>)
        (page as Map<String, Object?>).decodedPdfPage(),
    ];
    // One empty placeholder per page, exactly the header the worker
    // built: the reading order's page slots travel as structure.
    return PdfBook(
      bytes: Uint8List(0),
      metadata: decodeMetadataWireValue(json['metadata'] as Map<String, Object?>, blobs),
      pages: pages,
      pageFiles: <TextFile>[
        for (var i = 1; i <= pages.length; i++)
          TextFile(content: '', name: 'page_$i.html', type: 'html', path: 'page_$i.html'),
      ],
      navigation: decodeNavigationWireValue(json['navigation'] as Map<String, Object?>),
    );
  }

  throw ArgumentError('Session header wire payload holds no EPUB, comic or PDF section');
}

extension _PdfPageWire on Map<String, Object?> {
  PdfPage decodedPdfPage() {
    final width = this['width'] as num;
    final height = this['height'] as num;

    return PdfPage(
      objectNumber: this['objectNumber'] as int,
      mediaBox: <double>[0, 0, width.toDouble(), height.toDouble()],
      rotate: this['rotate'] as int,
    );
  }
}

/// Encodes one PDF page's extracted text — canonical lines with their
/// geometry, image placements and the owning page's visible size —
/// for the `sessionPdfLines` reply. JSON null is the caller's signal
/// for "no such page"; out-of-range indexes arrive as typed errors
/// instead.
Map<String, Object?> encodePdfPageLinesWire(
  final PdfPageText page, {
  required final double pageWidth,
  required final double pageHeight,
}) {
  return <String, Object?>{
    'lines': <Object?>[
      for (final line in page.lines)
        <String, Object?>{
          'text': line.text,
          'x': line.x,
          'y': line.y,
          'width': line.width,
          'height': line.height,
          'fontSize': line.fontSize,
          'rotated': line.rotated,
        },
    ],
    'images': <Object?>[
      for (final image in page.images)
        <String, Object?>{
          'name': image.name,
          'x': image.x,
          'y': image.y,
          'width': image.width,
          'height': image.height,
          'path': image.path,
        },
    ],
    'contentStreamCount': page.contentStreamCount,
    'skippedContentStreams': page.skippedContentStreams,
    'columnOrderApplied': page.columnOrderApplied,
    'pageWidth': pageWidth,
    'pageHeight': pageHeight,
  };
}

/// Decodes a [PdfPageText] from [encodePdfPageLinesWire]. The wire
/// carries JSON numbers, so geometry comes back through [num].
PdfPageText decodePdfPageLinesWire(final Map<String, Object?> json) {
  return PdfPageText(
    lines: <PdfTextLine>[
      for (final line in json['lines'] as List<Object?>)
        (line as Map<String, Object?>).decodedPdfTextLine(),
    ],
    images: <PdfImageBox>[
      for (final image in json['images'] as List<Object?>)
        (image as Map<String, Object?>).decodedPdfImageBox(),
    ],
    contentStreamCount: json['contentStreamCount'] as int,
    skippedContentStreams: json['skippedContentStreams'] as int,
    columnOrderApplied: json['columnOrderApplied'] as bool,
  );
}

extension _PdfLineWire on Map<String, Object?> {
  PdfTextLine decodedPdfTextLine() => PdfTextLine(
    text: this['text'] as String,
    x: (this['x'] as num).toDouble(),
    y: (this['y'] as num).toDouble(),
    width: (this['width'] as num).toDouble(),
    height: (this['height'] as num).toDouble(),
    fontSize: (this['fontSize'] as num).toDouble(),
    rotated: this['rotated'] as bool,
  );
}

extension _PdfImageWire on Map<String, Object?> {
  PdfImageBox decodedPdfImageBox() => PdfImageBox(
    name: this['name'] as String,
    x: (this['x'] as num).toDouble(),
    y: (this['y'] as num).toDouble(),
    width: (this['width'] as num).toDouble(),
    height: (this['height'] as num).toDouble(),
    path: this['path'] as String,
  );
}
