/// Abstract representation of a file inside a book container.
abstract class BookFile {
  /// Creates a [BookFile].
  BookFile({required this.name, required this.type, required this.path});

  /// The file name (basename).
  final String name;

  /// The file type (usually the extension without the leading dot).
  final String type;

  /// The path of the file inside the book container.
  final String path;
}
