import '../../../foundation/entities/entities.dart';

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

  /// The book authors.
  List<String> get creators => metadata.authors;

  /// The book language code.
  String get language => metadata.languages.isEmpty ? '' : metadata.languages.first;

  /// The book publisher.
  String? get publisher => metadata.publisher;

  /// The book title.
  String get title => metadata.title ?? '';
}
