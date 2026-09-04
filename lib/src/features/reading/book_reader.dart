import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:e_livre/src/features/comic/utils/parse_comic_book.dart';
import 'package:e_livre/src/features/detection/format_detector.dart';
import 'package:e_livre/src/features/epub/exceptions/exceptions.dart';
import 'package:e_livre/src/features/epub/utils/epub_metadata_mapper.dart';
import 'package:e_livre/src/features/epub/utils/parse_epub_book.dart';
import 'package:e_livre/src/features/epub/utils/parse_epub_package.dart';
import 'package:e_livre/src/features/fb2/utils/parse_fb2_book.dart';
import 'package:e_livre/src/features/mobi/utils/parse_mobi_book.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';
import 'package:e_livre/src/foundation/utils/metadata_utils.dart';

// Platform selection: the web default keeps WASM runtimes (where
// neither dart:html nor dart:io exist) compiling against the stubs,
// dart:html pins DDC/dart2js browsers away from the native variant,
// and dart:io claims every native runtime.
import '../../platform/io/book_path_reader.dart'
    if (dart.library.html) '../../platform/web/book_path_reader.dart'
    if (dart.library.io) '../../platform/io/book_path_reader.dart';
import '../../platform/web/background_parse.dart'
    if (dart.library.html) '../../platform/web/background_parse.dart'
    if (dart.library.io) '../../platform/io/background_parse.dart';
import 'book.dart';

/// Reads supported ebook formats and selects their format adapter.
abstract final class BookReader {
  /// Parses the book from [bytes].
  static Future<Book> openFromBytes(final Uint8List bytes) {
    if (bytes.isEmpty) throw EmptyBytesException();

    return parseBookInBackground(() => parseBook(bytes), bytes);
  }

  /// Parses the book at [path].
  static Future<Book> openFromPath(final String path) {
    return withBookPath(path, (final bytes, final _) => openFromBytes(bytes));
  }

  /// Synchronously parses [bytes] with the matching format adapter.
  static Book parseBook(final Uint8List bytes) {
    switch (BookFormatDetector.detect(bytes)) {
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

  /// Reads only metadata from [bytes].
  static Future<BookMetadata> readMetadataFromBytes(final Uint8List bytes) {
    if (bytes.isEmpty) throw EmptyBytesException();

    return readMetadataInBackground(() => readMetadataSync(bytes), bytes);
  }

  /// Reads only metadata from the book at [path].
  static Future<BookMetadata> readMetadataFromPath(final String path) {
    return withBookPath(path, (final bytes, final sourcePath) async {
      final metadata = await readMetadataFromBytes(bytes);

      final sidecar = await readBookSidecar(
        sourcePath,
        (final content) => epubBookMetadata(parsePackage(content)),
      );

      return applyFilenameFallback(
        sidecar == null ? metadata : mergeBookMetadata(metadata, sidecar),
        sourcePath,
      );
    });
  }

  /// Synchronously reads metadata from [bytes].
  static BookMetadata readMetadataSync(final Uint8List bytes) {
    switch (BookFormatDetector.detect(bytes)) {
      case DetectedFormat.epub:
        final archive = ZipDecoder().decodeBytes(bytes);
        if (_isEpubArchive(archive)) return readEpubMetadata(archive);
        if (_hasFb2Entry(archive)) return readFb2Metadata(bytes);

        return readComicMetadata(bytes);
      case DetectedFormat.mobiFamily:
        return readMobiMetadata(bytes);
      case DetectedFormat.fb2:
        return readFb2Metadata(bytes);
      case DetectedFormat.comic:
        return readComicMetadata(bytes);
    }
  }

  static ArchiveFile? _fb2Entry(final Archive archive) => archive.files.firstWhereOrNull(
    (final file) => file.isFile && file.name.toLowerCase().endsWith('.fb2'),
  );

  static bool _hasFb2Entry(final Archive archive) => _fb2Entry(archive) != null;

  static bool _isEpubArchive(final Archive archive) =>
      archive.files.any((final file) => file.isFile && file.name == 'META-INF/container.xml');

  static bool _isImageName(final String name) {
    final lower = name.toLowerCase();

    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  static bool _looksLikeComic(final Archive archive) =>
      archive.files.any((final file) => file.isFile && _isImageName(file.name));

  static Book _parseZipBook(final Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    if (_isEpubArchive(archive)) return parseEpubArchive(archive);

    final fb2Entry = _fb2Entry(archive);
    if (fb2Entry != null) return parseFb2Archive(fb2Entry);
    if (_looksLikeComic(archive)) return parseComicBook(bytes);

    throw const FormatNotSupportedException(
      'Zip container holds neither an EPUB package, an FB2 document '
      'nor comic pages.',
    );
  }
}
