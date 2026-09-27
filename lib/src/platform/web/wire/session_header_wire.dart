import 'dart:typed_data';

import '../../../features/comic/entities/comic_book.dart';
import '../../../features/comic/entities/comic_page_info.dart';
import '../../../features/epub/entities/book/book.dart';
import '../../../foundation/entities/entities.dart';
import 'book_components_wire.dart';
import 'epub_package_wire.dart';
import 'metadata_wire.dart';

/// Encodes a session header [book] — an [EpubBook] or [ComicBook]
/// carrying complete structure and an empty file set — into a
/// structured-clone-friendly wire payload.
///
/// This is the shape the `sessionOpen` op replies with. It reuses the
/// component encoders of the full book wire for everything the header
/// actually holds (navigation, cover, container inventory, package,
/// comic metadata and page declarations) and encodes the absent
/// content as structure only: EPUB files never cross, comic pages
/// travel as path/name/type placeholders without a blob each. The
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

  throw ArgumentError('Session headers are EPUB or comic books, got ${book.runtimeType}');
}

/// Decodes a session header [Book] wire payload produced by
/// [encodeSessionHeaderWire]: a real [EpubBook] or [ComicBook] whose
/// structure is complete and whose content stays empty — content loads
/// through the session ops, never through this payload.
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

  throw ArgumentError('Session header wire payload holds no EPUB or comic section');
}
