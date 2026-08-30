import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:e_livre/features/comic/utils/parse_comic_book.dart';
import 'package:e_livre/features/core/book/book.dart';
import 'package:e_livre/features/core/detection/format_detector.dart';
import 'package:e_livre/features/core/entities/book_metadata.dart';
import 'package:e_livre/features/core/exceptions/elivre_exception.dart';
import 'package:e_livre/features/core/utils/metadata_utils.dart';
import 'package:e_livre/features/epub/exceptions/empty_bytes_exception.dart';
import 'package:e_livre/features/epub/exceptions/epub_exception.dart';
import 'package:e_livre/features/epub/utils/epub_metadata_mapper.dart';
import 'package:e_livre/features/epub/utils/parse_epub_book.dart';
import 'package:e_livre/features/epub/utils/parse_epub_package.dart';
import 'package:e_livre/features/fb2/utils/parse_fb2_book.dart';
import 'package:e_livre/features/mobi/utils/parse_mobi_book.dart';
import 'package:path/path.dart' as path;

/// Format-agnostic entry point for parsing books.
///
/// [openFromBytes] (and its file/path variants) returns a [Book]
/// fully parsed by the module responsible for the detected format,
/// while [readMetadataFromBytes] performs a fast metadata-only read
/// (title, authors, cover, ...) without extracting book content.
///
/// The path-based metadata reads additionally apply Calibre-style
/// enrichment: a sibling `<basename>.opf` / `metadata.opf` sidecar
/// merges its metadata over the book's own (handy for libraries
/// managed by Calibre), and books without any internal metadata fall
/// back to a `Title - Author` filename pattern.
///
/// All parsing runs inside a background [Isolate] when available,
/// falling back to the current isolate on platforms without isolates.
abstract final class EBook {
  /// Parses the book at [path].
  static Future<Book> openFromPath(final String path) {
    return openFromFile(_getFileIfValid(path));
  }

  /// Parses the book in [file].
  static Future<Book> openFromFile(final File file) {
    if (!file.existsSync()) throw EpubException('No such file or directory');
    return openFromBytes(file.readAsBytesSync());
  }

  /// Parses the book from [bytes].
  static Future<Book> openFromBytes(final Uint8List bytes) {
    if (bytes.isEmpty) throw EmptyBytesException();
    return _runIsolated(() => parseBook(bytes));
  }

  /// Reads only the metadata of the book at [path].
  ///
  /// Applies sidecar OPF merging and the filename fallback on top of
  /// the book's own metadata.
  static Future<BookMetadata> readMetadataFromPath(final String path) {
    final file = _getFileIfValid(path);
    if (!file.existsSync()) throw EpubException('No such file or directory');
    final bytes = file.readAsBytesSync();
    if (bytes.isEmpty) throw EmptyBytesException();
    return readMetadataFromBytes(bytes).then((final metadata) {
      return applyFilenameFallback(_mergeOpfSidecar(metadata, path), path);
    });
  }

  /// Reads only the metadata of the book in [file].
  ///
  /// Applies sidecar OPF merging and the filename fallback on top of
  /// the book's own metadata.
  static Future<BookMetadata> readMetadataFromFile(final File file) {
    return readMetadataFromPath(file.path);
  }

  /// Reads only the metadata of the book in [bytes].
  static Future<BookMetadata> readMetadataFromBytes(final Uint8List bytes) {
    if (bytes.isEmpty) throw EmptyBytesException();
    return _runIsolated(() => readMetadataSync(bytes));
  }

  /// Synchronously parses [bytes] into a [Book].
  static Book parseBook(final Uint8List bytes) {
    switch (detectFormat(bytes)) {
      case DetectedFormat.epub:
        return _parseZipBook(bytes);
      case DetectedFormat.mobiFamily:
        return parseMobiBook(bytes);
      case DetectedFormat.fb2:
        return parseFb2Book(bytes);
      case DetectedFormat.comic:
        return parseComicBook(bytes);
    }
  }

  /// Synchronously reads only the metadata of [bytes].
  static BookMetadata readMetadataSync(final Uint8List bytes) {
    switch (detectFormat(bytes)) {
      case DetectedFormat.epub:
        final archive = ZipDecoder().decodeBytes(bytes);
        if (_isEpubArchive(archive)) {
          return readEpubMetadata(archive);
        }
        if (_hasFb2Entry(archive)) {
          return readFb2Metadata(bytes);
        }
        return readComicMetadata(bytes);
      case DetectedFormat.mobiFamily:
        return readMobiMetadata(bytes);
      case DetectedFormat.fb2:
        return readFb2Metadata(bytes);
      case DetectedFormat.comic:
        return readComicMetadata(bytes);
    }
  }

  static Book _parseZipBook(final Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    if (_isEpubArchive(archive)) {
      return parseEpubArchive(archive);
    }
    final fb2Entry = _fb2Entry(archive);
    if (fb2Entry != null) {
      return parseFb2Archive(fb2Entry);
    }
    if (_looksLikeComic(archive)) {
      return parseComicBook(bytes);
    }
    throw const FormatNotSupportedException(
      'Zip container holds neither an EPUB package, an FB2 document '
      'nor comic pages.',
    );
  }

  static bool _isEpubArchive(final Archive archive) {
    return archive.files.any(
      (final file) => file.isFile && file.name == 'META-INF/container.xml',
    );
  }

  static ArchiveFile? _fb2Entry(final Archive archive) {
    return archive.files.firstWhereOrNull(
      (final file) => file.isFile && file.name.toLowerCase().endsWith('.fb2'),
    );
  }

  static bool _hasFb2Entry(final Archive archive) => _fb2Entry(archive) != null;

  static bool _looksLikeComic(final Archive archive) {
    return archive.files.any((final file) => file.isFile && _isImageName(file.name));
  }

  static bool _isImageName(final String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  /// Merges a sibling Calibre sidecar OPF over [metadata].
  ///
  /// Calibre libraries store `<basename>.opf` / `metadata.opf` next to
  /// each book with user-edited metadata; when present it wins over
  /// the book's embedded metadata.
  static BookMetadata _mergeOpfSidecar(
    final BookMetadata metadata,
    final String bookPath,
  ) {
    final directory = path.dirname(bookPath);
    final basename = path.basenameWithoutExtension(bookPath);
    for (final candidate in ['$basename.opf', 'metadata.opf']) {
      final file = File(path.join(directory, candidate));
      if (!file.existsSync()) {
        continue;
      }
      try {
        final sidecar = epubBookMetadata(parsePackage(file.readAsStringSync()));
        return mergeBookMetadata(metadata, sidecar);
      } on Exception {
        // Malformed sidecar: keep the book's own metadata.
      }
    }
    return metadata;
  }

  static File _getFileIfValid(final String filePath) {
    if (filePath.isEmpty) throw EpubException('Path cannot be empty');
    final sanitized = path.normalize(filePath);
    return File(sanitized);
  }

  static Future<T> _runIsolated<T>(final T Function() action) async {
    try {
      return await Isolate.run(action);
    } on UnsupportedError {
      // Platforms without isolates (web): run in the current isolate.
      return action();
    }
  }
}
