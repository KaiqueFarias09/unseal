import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:e_livre/features/core/book/book.dart';
import 'package:e_livre/features/core/detection/format_detector.dart';
import 'package:e_livre/features/core/entities/book_metadata.dart';
import 'package:e_livre/features/core/exceptions/elivre_exception.dart';
import 'package:e_livre/features/epub/exceptions/empty_bytes_exception.dart';
import 'package:e_livre/features/epub/exceptions/epub_exception.dart';
import 'package:e_livre/features/epub/utils/parse_epub_book.dart';
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
  static Future<BookMetadata> readMetadataFromPath(final String path) {
    return readMetadataFromFile(_getFileIfValid(path));
  }

  /// Reads only the metadata of the book in [file].
  static Future<BookMetadata> readMetadataFromFile(final File file) {
    if (!file.existsSync()) throw EpubException('No such file or directory');
    return readMetadataFromBytes(file.readAsBytesSync());
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
        // Zip without an EPUB package: try a zipped FB2 document.
        return readFb2Metadata(bytes);
      case DetectedFormat.mobiFamily:
        return readMobiMetadata(bytes);
      case DetectedFormat.fb2:
        return readFb2Metadata(bytes);
    }
  }

  static Book _parseZipBook(final Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    if (_isEpubArchive(archive)) {
      return parseEpubArchive(archive);
    }
    final fb2Entry = archive.files.firstWhereOrNull(
      (final file) => file.isFile && file.name.toLowerCase().endsWith('.fb2'),
    );
    if (fb2Entry != null) {
      return parseFb2Archive(fb2Entry);
    }
    throw const FormatNotSupportedException(
      'Zip container holds neither an EPUB package nor an FB2 document.',
    );
  }

  static bool _isEpubArchive(final Archive archive) {
    return archive.files.any(
      (final file) => file.isFile && file.name == 'META-INF/container.xml',
    );
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
