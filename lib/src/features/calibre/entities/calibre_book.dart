/// One book of a Calibre library, joined from `metadata.db`.
final class CalibreBook {
  /// Creates a [CalibreBook].
  const CalibreBook({
    required this.id,
    required this.title,
    required this.titleSort,
    required this.timestamp,
    required this.authorSort,
    required this.isbn,
    required this.path,
    required this.authors,
    required this.series,
    required this.seriesIndex,
    required this.tags,
    required this.identifiers,
    required this.formats,
  });

  /// The calibre book id (primary key of `books`).
  final int id;

  /// The book title (`books.title`).
  final String? title;

  /// The stored title sort key (`books.sort`), when present.
  final String? titleSort;

  /// The import timestamp (`books.timestamp`).
  final DateTime? timestamp;

  /// The stored author sort key (`books.author_sort`), when present.
  final String? authorSort;

  /// The legacy ISBN column (`books.isbn`); modern libraries keep
  /// ISBNs in `identifiers`.
  final String? isbn;

  /// The library-relative folder holding the book files.
  final String? path;

  /// Author names from `authors` through `books_authors_link`.
  final List<String> authors;

  /// Series name from `series` through `books_series_link`.
  final String? series;

  /// Position inside the series (`books.series_index`).
  final double? seriesIndex;

  /// Tags from `tags` through `books_tags_link`.
  final List<String> tags;

  /// All `identifiers` rows keyed by scheme (`isbn`, `goodreads`...).
  final Map<String, String> identifiers;

  /// The formats stored for this book (`EPUB`, `MOBI`, ...).
  final List<String> formats;

  @override
  String toString() => 'CalibreBook(#$id, $title, authors: $authors)';
}
