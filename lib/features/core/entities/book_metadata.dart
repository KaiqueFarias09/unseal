import 'package:e_livre/features/core/entities/book_cover.dart';
import 'package:e_livre/features/core/entities/book_format.dart';

/// Format-agnostic book metadata extracted from any supported book file.
///
/// Every format module maps its native metadata into this common shape.
/// Fields the source format does not carry stay `null` / empty.
final class BookMetadata {
  /// Creates a [BookMetadata].
  const BookMetadata({
    required this.format,
    this.title,
    this.authors = const <String>[],
    this.languages = const <String>[],
    this.publisher,
    this.description,
    this.isbn,
    this.subjects = const <String>[],
    this.publishedAt,
    this.rights,
    this.identifiers = const <String, String>{},
    this.cover,
  });

  /// The format the metadata was extracted from.
  final BookFormat format;

  /// Book title, when available.
  final String? title;

  /// Author names, in display order.
  final List<String> authors;

  /// ISO language codes (e.g. `en`, `pt-BR`).
  final List<String> languages;

  /// Publisher name, when available.
  final String? publisher;

  /// Description / annotation / summary.
  final String? description;

  /// ISBN, when available.
  final String? isbn;

  /// Subjects / genres / tags.
  final List<String> subjects;

  /// Publication date, when parseable.
  final DateTime? publishedAt;

  /// Copyright / rights statement.
  final String? rights;

  /// Additional identifiers keyed by scheme (e.g. `asin`, `uuid`).
  final Map<String, String> identifiers;

  /// The book cover, when one could be located.
  final BookCover? cover;

  @override
  String toString() {
    return 'BookMetadata(format: ${format.name}, title: $title, '
        'authors: $authors, languages: $languages)';
  }
}
