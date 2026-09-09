import '../file/binary_file.dart';
import '../file/text_file.dart';

/// The files contained in a parsed book.
///
/// Provides access to the images, CSS files, HTML files, font files and other files extracted from
/// the book, regardless of the source format.
class Files {
  /// Creates a new [Files] with the given lists of files.
  Files({
    required this.images,
    required this.css,
    required this.html,
    required this.fonts,
    required this.others,
  });

  /// The list of image files in the book.
  final List<BinaryFile> images;

  /// The list of CSS files in the book.
  final List<TextFile> css;

  /// The list of HTML content files in the book.
  final List<TextFile> html;

  /// The list of font files in the book.
  final List<BinaryFile> fonts;

  /// The list of remaining binary files in the book.
  final List<BinaryFile> others;

  @override
  String toString() {
    return 'Files(images: ${images.length}, cssFiles: ${css.length}, '
        'htmlFiles: ${html.length}, fontFiles: ${fonts.length}, '
        'otherFiles: ${others.length})';
  }
}
