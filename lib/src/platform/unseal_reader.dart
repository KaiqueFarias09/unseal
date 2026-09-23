import 'dart:typed_data';

import '../features/detection/detect_format.dart';
import '../features/detection/entities/detected_format.dart';
import '../features/epub/metadata/epub_metadata.dart';
import '../features/epub/package/parse_epub_package.dart';
import '../features/markdown/parse_markdown_book.dart';
import '../features/reading/book_dispatch.dart';
import '../features/reading/book_inspection.dart';
import '../foundation/entities/entities.dart';
import '../foundation/exceptions/unseal_exception.dart';
import '../foundation/metadata/book_metadata_operations.dart';
import 'web/background_parse.dart' if (dart.library.io) 'io/background_parse.dart';
import 'web/book_path_reader.dart' if (dart.library.io) 'io/book_path_reader.dart';

/// Reads supported book formats through the current runtime's execution adapter.
///
/// The asynchronous methods are the default entry points for applications: on
/// native runtimes they use a background isolate when available, and on the web
/// they can use the configured `UnsealWorker`. Use [parse] and
/// [readMetadataSync] when the caller explicitly needs synchronous work.
// This public facade intentionally keeps the package-level namespace static.
// ignore: avoid_classes_with_only_static_members
abstract final class Unseal {
  /// Opens [bytes] and reports whether the full parse succeeded.
  ///
  /// This has the same cost as [read]. On success, the result retains the
  /// parsed book so it can be used without a second read. A detected format
  /// family is only a signature-level hint and can be absent on failure.
  static Future<BookInspection> inspect(final Uint8List bytes, {final String password = ''}) async {
    try {
      final book = await read(bytes, password: password);
      return BookInspection.opened(book, detectFormat(bytes));
    } on UnsealException catch (error) {
      DetectedFormat? detectedFormat;
      try {
        detectedFormat = detectFormat(bytes);
      } on FormatNotSupportedException {
        // A known unsupported or unrecognized signature has no DetectedFormat.
      }

      return BookInspection.failed(error, detectedFormat);
    }
  }

  /// Reads a book from [bytes], opening encrypted PDFs with [password].
  static Future<Book> read(final Uint8List bytes, {final String password = ''}) {
    return Future<Book>.sync(
      () => BookDispatch.openFromBytes(bytes, execute: parseBookInBackground, password: password),
    );
  }

  /// Reads a book from the file at [path], opening encrypted PDFs with [password].
  static Future<Book> readFile(final String path, {final String password = ''}) {
    return withBookPath(path, (final bytes, final sourcePath) {
      if (_isMarkdownPath(sourcePath)) {
        return parseBookInBackground(() => parseMarkdownBook(bytes, sourceName: sourcePath), bytes);
      }
      return read(bytes, password: password);
    });
  }

  /// Synchronously parses [bytes] with the matching format adapter.
  static Book parse(final Uint8List bytes, {final String password = ''}) {
    return BookDispatch.parseBook(bytes, password: password);
  }

  /// Reads only metadata from [bytes], opening encrypted PDFs with [password].
  static Future<BookMetadata> readMetadata(final Uint8List bytes, {final String password = ''}) {
    return Future<BookMetadata>.sync(() {
      return BookDispatch.readMetadataFromBytes(
        bytes,
        execute: readMetadataInBackground,
        password: password,
      );
    });
  }

  /// Reads only metadata from the file at [path], including a neighboring OPF sidecar.
  static Future<BookMetadata> readMetadataFile(final String path, {final String password = ''}) {
    return withBookPath(path, (final bytes, final sourcePath) async {
      final metadata = _isMarkdownPath(sourcePath)
          ? await readMetadataInBackground(
              () => readMarkdownMetadata(bytes, sourceName: sourcePath),
              bytes,
            )
          : await readMetadata(bytes, password: password);
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
  static BookMetadata readMetadataSync(final Uint8List bytes, {final String password = ''}) {
    return BookDispatch.readMetadataSync(bytes, password: password);
  }
}

bool _isMarkdownPath(final String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.md') || lower.endsWith('.markdown') || lower.endsWith('.mdown');
}
