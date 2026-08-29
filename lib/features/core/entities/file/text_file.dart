import 'package:e_livre/features/core/entities/file/book_file.dart';

/// Represents a text book file.
///
/// This class extends [BookFile] and adds a [content] field
/// of type [String] to hold the text content of the file.
class TextFile extends BookFile {
  /// Creates a new [TextFile].
  ///
  /// Requires [content], [name], [path], and [type] to be non-null.
  TextFile({
    required this.content,
    required super.name,
    required super.type,
    required super.path,
  });

  /// The text content of the file.
  final String content;
}
