import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:e_livre/src/features/calibre/entities/calibre_book.dart';

part 'entities/sqlite_database.dart';

/// A read-only view over a Calibre `metadata.db` file.
final class CalibreDatabase {
  CalibreDatabase._(this.books);

  /// Parses a `metadata.db` file and joins the tables needed for
  /// library import: books, authors, series, tags, identifiers and
  /// data formats.
  factory CalibreDatabase.parse(final Uint8List bytes) {
    final db = _SqliteDatabase(bytes);

    // Column layouts vary between calibre versions (isbn/lccn were
    // dropped from books in newer releases), so positions come from
    // each table's CREATE statement instead of hardcoded offsets.
    final master = db.readTable(1);
    final roots = <String, int>{};
    final columns = <String, List<String>>{};
    for (final row in master) {
      final values = row.$2;
      if (values.length >= 4 && values[0] == 'table') {
        final name = values[1] as String;
        roots[name] = values[3] as int;
        columns[name] = _parseColumnNames(values[4] as String? ?? '');
      }
    }

    int? columnIndexOf(final String tableName, final String column) {
      final names = columns[tableName];
      if (names == null) return null;
      final index = names.indexOf(column);
      return index == -1 ? null : index;
    }

    Object? valueOf(
      final List<Object?> values,
      final String tableName,
      final String column, {
      final int fallback = -1,
    }) {
      final index = columnIndexOf(tableName, column) ?? fallback;
      if (index < 0 || index >= values.length) return null;
      return values[index];
    }

    List<MapEntry<int, List<Object?>>> all(final String tableName) =>
        db.readTable(roots[tableName]!).map((final row) => MapEntry(row.$1, row.$2)).toList();

    // `id INTEGER PRIMARY KEY` columns are rowid aliases: SQLite
    // stores them as NULL in the record, so the rowid IS the id.
    final booksTable = all('books');
    final authorsTable = all('authors');
    final seriesTable = all('series');
    final tagsTable = all('tags');
    final bookAuthorLinks = all('books_authors_link');
    final bookSeriesLinks = all('books_series_link');
    final bookTagLinks = all('books_tags_link');
    final identifiersTable = all('identifiers');
    final dataFormats = all('data');

    String nameOf(final List<MapEntry<int, List<Object?>>> table, final int id) {
      for (final row in table) {
        if (row.key == id) return _asText(row.value[1]) ?? '';
      }
      return '';
    }

    final authorsByBook = <int, List<String>>{};
    for (final row in bookAuthorLinks) {
      final book = row.value[1] as int?;
      final author = row.value[2] as int?;
      if (book == null || author == null) continue;
      (authorsByBook[book] ??= <String>[]).add(nameOf(authorsTable, author));
    }

    final seriesByBook = <int, String>{};
    for (final row in bookSeriesLinks) {
      final book = row.value[1] as int?;
      final series = row.value[2] as int?;
      if (book == null || series == null) continue;
      seriesByBook[book] = nameOf(seriesTable, series);
    }

    final tagsByBook = <int, List<String>>{};
    for (final row in bookTagLinks) {
      final book = row.value[1] as int?;
      final tag = row.value[2] as int?;
      if (book == null || tag == null) continue;
      (tagsByBook[book] ??= <String>[]).add(nameOf(tagsTable, tag));
    }

    final identifiersByBook = <int, Map<String, String>>{};
    for (final row in identifiersTable) {
      final book = row.value[1] as int?;
      final type = _asText(row.value[2]);
      final value = _asText(row.value[3]);
      if (book == null || type == null || value == null) continue;
      (identifiersByBook[book] ??= <String, String>{})[type] = value;
    }

    final formatsByBook = <int, List<String>>{};
    for (final row in dataFormats) {
      final book = row.value[1] as int?;
      final format = _asText(row.value[2]);
      if (book == null || format == null) continue;
      (formatsByBook[book] ??= <String>[]).add(format);
    }

    final books = <CalibreBook>[];
    for (final row in booksTable) {
      final id = row.key;
      final values = row.value;
      final index = valueOf(values, 'books', 'series_index');
      books.add(
        CalibreBook(
          id: id,
          title: _asText(valueOf(values, 'books', 'title')),
          titleSort: _asText(valueOf(values, 'books', 'sort')),
          timestamp: _parseTimestamp(valueOf(values, 'books', 'timestamp')),
          authorSort: _asText(valueOf(values, 'books', 'author_sort')),
          isbn: _asText(valueOf(values, 'books', 'isbn')),
          path: _asText(valueOf(values, 'books', 'path')),
          authors: authorsByBook[id] ?? const <String>[],
          series: seriesByBook[id],
          seriesIndex: index is num ? index.toDouble() : null,
          tags: tagsByBook[id] ?? const <String>[],
          identifiers: identifiersByBook[id] ?? const <String, String>{},
          formats: formatsByBook[id] ?? const <String>[],
        ),
      );
    }

    return CalibreDatabase._(books);
  }

  /// Extracts the column names of a `CREATE TABLE` statement.
  static List<String> _parseColumnNames(final String sql) {
    final open = sql.indexOf('(');
    if (open == -1) return const <String>[];
    final names = <String>[];
    final constraintStarters = <String>{'primary', 'unique', 'check', 'foreign', 'constraint'};
    var depth = 0;
    final current = StringBuffer();
    final parts = <String>[];
    for (var i = open + 1; i < sql.length; i++) {
      final char = sql[i];
      if (char == '(') depth++;
      if (char == ')') {
        if (depth == 0) break;
        depth--;
      }
      if (char == ',' && depth == 0) {
        parts.add(current.toString());
        current.clear();
        continue;
      }
      current.write(char);
    }
    parts.add(current.toString());

    for (final part in parts) {
      final trimmed = part.trim();
      if (trimmed.isEmpty) continue;
      final token = RegExp(r'^["`\[]?([A-Za-z_][A-Za-z0-9_]*)').firstMatch(trimmed)?.group(1);
      if (token == null) continue;
      if (constraintStarters.contains(token.toLowerCase())) continue;
      names.add(token.toLowerCase());
    }
    return names;
  }

  static String? _asText(final Object? value) => value == null ? null : '$value';

  static DateTime? _parseTimestamp(final Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    // Calibre stores `YYYY-MM-DD HH:MM:SS.ffffff+00:00`.
    return DateTime.tryParse(raw.replaceFirst(' ', 'T'));
  }

  /// All books recorded in the library.
  final List<CalibreBook> books;
}
