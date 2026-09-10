import 'dart:typed_data';

import 'book_file.dart';

/// Represents a binary book file.
///
/// This class extends [BookFile] and adds a [content] field of type [Uint8List] to hold the binary
/// content of the file.
class BinaryFile extends BookFile {
  /// Creates a new [BinaryFile].
  ///
  /// Requires [content], [name], [path], and [type] to be non-null.
  BinaryFile({
    required this.content,
    required super.name,
    required super.type,
    required super.path,
  });

  /// Creates an empty [BinaryFile].
  factory BinaryFile.empty() {
    return BinaryFile(content: Uint8List(0), name: '', type: '', path: '');
  }

  /// The binary content of the file.
  final Uint8List content;

  /// Returns `true` if the binary file is empty, `false` otherwise.
  bool get isEmpty => content.isEmpty;
}
