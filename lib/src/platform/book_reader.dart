import 'dart:typed_data';

import '../features/epub/metadata/epub_metadata.dart';
import '../features/epub/package/parse_epub_package.dart';
import '../features/reading/book_dispatch.dart';
import '../foundation/entities/entities.dart';
import '../foundation/metadata/book_metadata_operations.dart';
import 'web/background_parse.dart' if (dart.library.io) 'io/background_parse.dart';
import 'web/book_path_reader.dart' if (dart.library.io) 'io/book_path_reader.dart';

/// Reads supported ebook formats through the current runtime's execution adapter.
// This public facade intentionally preserves the static reader interface.
// ignore: avoid_classes_with_only_static_members
abstract final class BookReader {
  /// Parses the book from [bytes], opening encrypted PDFs with [password].
  static Future<Book> openFromBytes(final Uint8List bytes, {final String password = ''}) =>
      BookDispatch.openFromBytes(bytes, execute: parseBookInBackground, password: password);

  /// Parses the book at [path], opening encrypted PDFs with [password].
  static Future<Book> openFromPath(final String path, {final String password = ''}) =>
      withBookPath(path, (final bytes, final _) => openFromBytes(bytes, password: password));

  /// Synchronously parses [bytes] with the matching format adapter.
  static Book parseBook(final Uint8List bytes, {final String password = ''}) =>
      BookDispatch.parseBook(bytes, password: password);

  /// Reads only metadata from [bytes], opening encrypted PDFs with [password].
  static Future<BookMetadata> readMetadataFromBytes(
    final Uint8List bytes, {
    final String password = '',
  }) => BookDispatch.readMetadataFromBytes(
    bytes,
    execute: readMetadataInBackground,
    password: password,
  );

  /// Reads only metadata from the book at [path], including a neighboring OPF sidecar.
  static Future<BookMetadata> readMetadataFromPath(
    final String path, {
    final String password = '',
  }) => withBookPath(path, (final bytes, final sourcePath) async {
    final metadata = await readMetadataFromBytes(bytes, password: password);
    final sidecar = await readBookSidecar(
      sourcePath,
      (final content) => epubBookMetadata(parsePackage(content)),
    );

    return applyFilenameFallback(
      sidecar == null ? metadata : mergeBookMetadata(metadata, sidecar),
      sourcePath,
    );
  });

  /// Synchronously reads metadata from [bytes].
  static BookMetadata readMetadataSync(final Uint8List bytes, {final String password = ''}) =>
      BookDispatch.readMetadataSync(bytes, password: password);
}
