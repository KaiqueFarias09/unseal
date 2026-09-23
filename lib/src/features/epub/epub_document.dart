import '../../foundation/entities/entities.dart';
import 'entities/book/epub_landmark.dart';
import 'entities/package/epub_package.dart';

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

  /// Page labels and destinations declared by an EPUB 3 nav document.
  Navigation? get pageList;

  /// Structural destinations declared by an EPUB 3 nav document.
  List<EpubLandmark> get landmarks;

  /// The format-specific EPUB package metadata.
  EpubPackage get package;

  /// Archive paths of spine items in reading order.
  List<String>? get spinePaths;
}
