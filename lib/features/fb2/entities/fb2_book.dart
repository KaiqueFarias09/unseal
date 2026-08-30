import 'package:e_livre/features/core/book/book.dart';
import 'package:e_livre/features/core/entities/book/files.dart';
import 'package:e_livre/features/core/entities/book_format.dart';
import 'package:e_livre/features/core/entities/book_metadata.dart';
import 'package:e_livre/features/core/entities/file/binary_file.dart';
import 'package:e_livre/features/core/entities/navigation/navigation.dart';

/// A parsed FictionBook 2.0 book.
class Fb2Book extends Book {
  /// Creates an [Fb2Book] from already parsed parts.
  Fb2Book({
    required this.navigation,
    required this.files,
    required this.cover,
    required this.metadata,
  }) : super(format: BookFormat.fb2);

  /// The navigation (table of contents) of the book.
  @override
  final Navigation navigation;

  /// The files extracted from the book.
  @override
  final Files files;

  /// The cover image, or an empty file when none was found.
  final BinaryFile cover;

  /// The format-agnostic metadata of this book.
  @override
  final BookMetadata metadata;

  /// The book title.
  String get title => metadata.title ?? '';

  /// The book authors.
  List<String> get creators => metadata.authors;

  /// The book language code.
  String get language =>
      metadata.languages.isEmpty ? '' : metadata.languages.first;

  /// The book publisher.
  String? get publisher => metadata.publisher;
}
