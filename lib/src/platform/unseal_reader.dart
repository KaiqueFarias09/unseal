import 'dart:typed_data';

import '../features/epub/metadata/epub_metadata.dart';
import '../features/epub/package/parse_epub_package.dart';
import '../features/reading/book_dispatch.dart';
import '../foundation/entities/entities.dart';
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
  /// Reads a book from [bytes], opening encrypted PDFs with [password].
  static Future<Book> read(final Uint8List bytes, {final String password = ''}) {
    return Future<Book>.sync(
      () => BookDispatch.openFromBytes(bytes, execute: parseBookInBackground, password: password),
    );
  }

  /// Reads a book from the file at [path], opening encrypted PDFs with [password].
  static Future<Book> readFile(final String path, {final String password = ''}) {
    return withBookPath(path, (final bytes, final _) => read(bytes, password: password));
  }

  /// Synchronously parses [bytes] with the matching format adapter.
  static Book parse(final Uint8List bytes, {final String password = ''}) {
    return BookDispatch.parseBook(bytes, password: password);
  }

  /// Reads only metadata from [bytes], opening encrypted PDFs with [password].
  static Future<BookMetadata> readMetadata(final Uint8List bytes, {final String password = ''}) {
    return Future<BookMetadata>.sync(
      () => BookDispatch.readMetadataFromBytes(
        bytes,
        execute: readMetadataInBackground,
        password: password,
      ),
    );
  }

  /// Reads only metadata from the file at [path], including a neighboring OPF sidecar.
  static Future<BookMetadata> readMetadataFile(final String path, {final String password = ''}) {
    return withBookPath(path, (final bytes, final sourcePath) async {
      final metadata = await readMetadata(bytes, password: password);
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
