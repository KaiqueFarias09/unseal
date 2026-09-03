import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';

/// Domain contract for a parsed EPUB document.
abstract interface class EpubDocument implements Book {
  /// The HTML files in the EPUB document.
  List<TextFile> get content;

  /// The extracted EPUB cover image.
  BinaryFile get cover;

  /// Explicitly exposes the inherited EPUB file contracts.
  @override
  Files get files;

  /// The binary images in the EPUB document.
  List<BinaryFile> get images;

  /// Explicitly exposes the inherited EPUB content contracts.
  @override
  Navigation get navigation;

  /// The format-specific EPUB package metadata.
  Object get package;

  /// Archive paths of spine items in reading order.
  List<String>? get spinePaths;
}
