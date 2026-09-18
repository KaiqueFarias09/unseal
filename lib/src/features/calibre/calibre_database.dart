import 'dart:convert' as convert;
import 'dart:typed_data';

part 'sqlite_database.dart';

/// One book record joined from the `metadata.db` schema consumed by this importer.
final class CalibreBook {
  CalibreBook._({
    required this.id,
    required this.title,
    required this.titleSort,
    required this.timestamp,
    required this.authorSort,
    required this.path,
    required this.authors,
    required this.series,
    required this.seriesIndex,
    required this.tags,
    required this.identifiers,
    required this.formats,
  });

  /// The book id (primary key of `books`).
  final int id;

  /// The book title (`books.title`).
  final String? title;

  /// The stored title sort key (`books.sort`), when present.
  final String? titleSort;

  /// The import timestamp (`books.timestamp`).
  final DateTime? timestamp;

  /// The stored author sort key (`books.author_sort`), when present.
  final String? authorSort;

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

typedef _DatabaseRow = (int, List<Object?>);

/// A read-only view over the `metadata.db` schema consumed by this importer.
final class CalibreDatabase {
  CalibreDatabase._(this.books);

  /// Parses a `metadata.db` file and joins the tables needed for library import: books, authors,
  /// series, tags, identifiers and data formats.
  factory CalibreDatabase.parse(final Uint8List bytes) {
    final schema = _CalibreSchema.read(bytes);

    // `id INTEGER PRIMARY KEY` columns are rowid aliases: SQLite stores them as NULL in the record,
    // so the rowid IS the id.
    final authorsById = _namesById(schema.readTable('authors'));
    final seriesById = _namesById(schema.readTable('series'));
    final tagsById = _namesById(schema.readTable('tags'));
    final authorsByBook = _linkedNamesByBook(schema.readTable('books_authors_link'), authorsById);
    final seriesByBook = _linkedNamesByBook(schema.readTable('books_series_link'), seriesById);
    final tagsByBook = _linkedNamesByBook(schema.readTable('books_tags_link'), tagsById);
    final identifiersByBook = _identifiersByBook(schema.readTable('identifiers'));
    final formatsByBook = _textValuesByBook(schema.readTable('data'));
    final books = <CalibreBook>[];
    for (final (id, values) in schema.readTable('books')) {
      final index = schema.valueOf(values, 'books', 'series_index');
      final identifiers = <String, String>{...?identifiersByBook[id]};
      final isbn = _asText(schema.valueOf(values, 'books', 'isbn'));
      if (isbn != null && isbn.isNotEmpty && !identifiers.containsKey('isbn')) {
        identifiers['isbn'] = isbn;
      }

      books.add(
        CalibreBook._(
          id: id,
          title: _asText(schema.valueOf(values, 'books', 'title')),
          titleSort: _asText(schema.valueOf(values, 'books', 'sort')),
          timestamp: _parseTimestamp(schema.valueOf(values, 'books', 'timestamp')),
          authorSort: _asText(schema.valueOf(values, 'books', 'author_sort')),
          path: _asText(schema.valueOf(values, 'books', 'path')),
          authors: List<String>.unmodifiable(authorsByBook[id] ?? const <String>[]),
          series: seriesByBook[id]?.last,
          seriesIndex: index is num ? index.toDouble() : null,
          tags: List<String>.unmodifiable(tagsByBook[id] ?? const <String>[]),
          identifiers: Map<String, String>.unmodifiable(identifiers),
          formats: List<String>.unmodifiable(formatsByBook[id] ?? const <String>[]),
        ),
      );
    }

    return CalibreDatabase._(List<CalibreBook>.unmodifiable(books));
  }

  /// All books recorded in the library.
  final List<CalibreBook> books;
}

final class _CalibreSchema {
  const _CalibreSchema(this._database, this._rootPages, this._columnsByTable);

  factory _CalibreSchema.read(final Uint8List bytes) {
    final database = _SqliteDatabaseReader(bytes);
    final rootPages = <String, int>{};
    final columnsByTable = <String, List<String>>{};

    // Column layouts vary between database versions, so positions come from each table's CREATE
    // statement instead of hardcoded offsets.
    for (final (_, values) in database.readTable(1)) {
      if (values.length < 5 || values[0] != 'table') continue;

      final name = values[1];
      final rootPage = values[3];
      if (name is! String || rootPage is! int) continue;

      rootPages[name] = rootPage;
      columnsByTable[name] = _parseColumnNames(_asText(values[4]) ?? '');
    }

    return _CalibreSchema(database, rootPages, columnsByTable);
  }

  final _SqliteDatabaseReader _database;
  final Map<String, int> _rootPages;
  final Map<String, List<String>> _columnsByTable;

  List<_DatabaseRow> readTable(final String tableName) {
    final rootPage = _rootPages[tableName];
    if (rootPage == null) throw FormatException('Missing required metadata table `$tableName`.');

    return _database.readTable(rootPage);
  }

  Object? valueOf(final List<Object?> values, final String tableName, final String column) {
    final columns = _columnsByTable[tableName];
    final index = columns?.indexOf(column) ?? -1;
    if (index < 0 || index >= values.length) return null;

    return values[index];
  }

  static List<String> _parseColumnNames(final String sql) {
    final open = sql.indexOf('(');
    if (open == -1) return const <String>[];

    final parts = <String>[];
    final current = StringBuffer();
    var depth = 0;
    for (var index = open + 1; index < sql.length; index++) {
      final character = sql[index];
      if (character == '(') depth++;
      if (character == ')') {
        if (depth == 0) break;
        depth--;
      }
      if (character == ',' && depth == 0) {
        parts.add(current.toString());
        current.clear();
        continue;
      }

      current.write(character);
    }
    parts.add(current.toString());

    const constraintStarters = <String>{'primary', 'unique', 'check', 'foreign', 'constraint'};
    final names = <String>[];
    final identifierPattern = RegExp(r'^["`\[]?([A-Za-z_][A-Za-z0-9_]*)');
    for (final part in parts) {
      final token = identifierPattern.firstMatch(part.trim())?.group(1)?.toLowerCase();
      if (token == null || constraintStarters.contains(token)) continue;

      names.add(token);
    }

    return names;
  }
}

Map<int, String> _namesById(final List<_DatabaseRow> rows) {
  final names = <int, String>{};
  for (final (id, values) in rows) {
    names[id] = _asText(_valueAt(values, 1)) ?? '';
  }

  return names;
}

Map<int, List<String>> _linkedNamesByBook(
  final List<_DatabaseRow> rows,
  final Map<int, String> namesById,
) {
  final namesByBook = <int, List<String>>{};
  for (final (_, values) in rows) {
    final bookId = _valueAt(values, 1);
    final nameId = _valueAt(values, 2);
    if (bookId is! int || nameId is! int) continue;

    final name = namesById[nameId];
    if (name == null) continue;

    (namesByBook[bookId] ??= <String>[]).add(name);
  }

  return namesByBook;
}

Map<int, Map<String, String>> _identifiersByBook(final List<_DatabaseRow> rows) {
  final identifiersByBook = <int, Map<String, String>>{};
  for (final (_, values) in rows) {
    final bookId = _valueAt(values, 1);
    final scheme = _asText(_valueAt(values, 2));
    final value = _asText(_valueAt(values, 3));
    if (bookId is! int || scheme == null || value == null) continue;

    (identifiersByBook[bookId] ??= <String, String>{})[scheme] = value;
  }

  return identifiersByBook;
}

Map<int, List<String>> _textValuesByBook(final List<_DatabaseRow> rows) {
  final valuesByBook = <int, List<String>>{};
  for (final (_, values) in rows) {
    final bookId = _valueAt(values, 1);
    final value = _asText(_valueAt(values, 2));
    if (bookId is! int || value == null) continue;

    (valuesByBook[bookId] ??= <String>[]).add(value);
  }

  return valuesByBook;
}

Object? _valueAt(final List<Object?> values, final int index) {
  return index < values.length ? values[index] : null;
}

String? _asText(final Object? value) {
  return value == null ? null : '$value';
}

DateTime? _parseTimestamp(final Object? raw) {
  if (raw is! String || raw.isEmpty) return null;

  // Library timestamps use `YYYY-MM-DD HH:MM:SS.ffffff+00:00`.
  return DateTime.tryParse(raw.replaceFirst(' ', 'T'));
}
