import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/foundation/entities/book/files.dart';
import 'package:e_livre/src/foundation/entities/file/binary_file.dart';
import 'package:e_livre/src/foundation/entities/file/text_file.dart';
import 'package:e_livre/src/foundation/entities/navigation/navigation.dart';

/// Domain contract for a parsed EPUB document.
abstract interface class EpubDocument implements Book {
  /// The extracted EPUB cover image.
  BinaryFile get cover;

  /// The format-specific EPUB package metadata.
  Object get package;

  /// Archive paths of spine items in reading order.
  List<String>? get spinePaths;

  /// The HTML files in the EPUB document.
  List<TextFile> get content;

  /// The binary images in the EPUB document.
  List<BinaryFile> get images;

  /// Explicitly exposes the inherited EPUB content contracts.
  @override
  Navigation get navigation;

  /// Explicitly exposes the inherited EPUB file contracts.
  @override
  Files get files;
}
