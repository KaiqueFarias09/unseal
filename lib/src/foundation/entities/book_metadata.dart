import 'package:e_livre/src/foundation/entities/book_cover.dart';
import 'package:e_livre/src/foundation/entities/book_format.dart';

/// Format-agnostic book metadata extracted from any supported book file.
///
/// Every format module maps its native metadata into this common shape.
/// Fields the source format does not carry stay `null` / empty.
final class BookMetadata {
  /// Creates a [BookMetadata].
  const BookMetadata({
    required this.format,
    this.authorSort,
    this.authors = const <String>[],
    this.bookProducer,
    this.cover,
    this.description,
    this.identifiers = const <String, String>{},
    this.isbn,
    this.languages = const <String>[],
    this.publishedAt,
    this.publisher,
    this.rights,
    this.series,
    this.seriesIndex,
    this.subjects = const <String>[],
    this.title,
    this.titleSort,
  });

  /// Author names, in display order.
  final List<String> authors;

  /// Author string used for sorting (e.g. `Last, First`), when the
  /// source format carries one explicitly.
  final String? authorSort;

  /// The format the metadata was extracted from.
  final BookFormat format;

  /// Tool or person that produced the file (e.g. `calibre (9.4.0)`).
  final String? bookProducer;

  /// Additional identifiers keyed by scheme (e.g. `asin`, `uuid`).
  final Map<String, String> identifiers;

  /// ISO language codes (e.g. `en`, `pt-BR`).
  final List<String> languages;

  /// Subjects / genres / tags.
  final List<String> subjects;

  /// The book cover, when one could be located.
  final BookCover? cover;

  /// Description / annotation / summary.
  final String? description;

  /// ISBN, when available.
  final String? isbn;

  /// Publication date, when parseable.
  final DateTime? publishedAt;

  /// Publisher name, when available.
  final String? publisher;

  /// Copyright / rights statement.
  final String? rights;

  /// Series / collection name the book belongs to.
  final String? series;

  /// Position of the book inside its series (1-based, may be a
  /// fraction such as `2.5` for short stories between volumes).
  final double? seriesIndex;

  /// Book title, when available.
  final String? title;

  /// Title string used for sorting (title without leading articles),
  /// when the source format carries one explicitly.
  final String? titleSort;

  /// Returns a copy with the provided fields replaced.
  BookMetadata copyWith({
    final BookFormat? format,
    final String? title,
    final String? titleSort,
    final String? authorSort,
    final String? bookProducer,
    final List<String>? authors,
    final List<String>? languages,
    final String? publisher,
    final String? description,
    final String? isbn,
    final List<String>? subjects,
    final DateTime? publishedAt,
    final String? rights,
    final String? series,
    final double? seriesIndex,
    final Map<String, String>? identifiers,
    final BookCover? cover,
  }) {
    return BookMetadata(
      format: format ?? this.format,
      title: title ?? this.title,
      titleSort: titleSort ?? this.titleSort,
      authorSort: authorSort ?? this.authorSort,
      bookProducer: bookProducer ?? this.bookProducer,
      authors: authors ?? this.authors,
      languages: languages ?? this.languages,
      publisher: publisher ?? this.publisher,
      description: description ?? this.description,
      isbn: isbn ?? this.isbn,
      subjects: subjects ?? this.subjects,
      publishedAt: publishedAt ?? this.publishedAt,
      rights: rights ?? this.rights,
      series: series ?? this.series,
      seriesIndex: seriesIndex ?? this.seriesIndex,
      identifiers: identifiers ?? this.identifiers,
      cover: cover ?? this.cover,
    );
  }

  @override
  String toString() {
    return 'BookMetadata(format: ${format.name}, title: $title, '
        'authors: $authors, languages: $languages)';
  }
}
