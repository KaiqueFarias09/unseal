import 'dart:convert' as convert;
import 'dart:typed_data';

/// A read-only, dependency-free reader for the SQLite file format,
/// scoped to what Calibre's `metadata.db` needs: whole-table scans of
/// rowid tables (interior + leaf b-tree pages, overflow chains).
///
/// See https://www.sqlite.org/fileformat2.html.
class _SqliteDatabase {
  _SqliteDatabase(final Uint8List bytes) : _bytes = bytes {
    final magic = convert.ascii.decode(_bytes.sublist(0, 15));
    if (!magic.startsWith('SQLite format 3')) {
      throw const FormatException('Not an SQLite database file.');
    }
    final view = ByteData.sublistView(_bytes);
    var pageSize = view.getUint16(16);
    if (pageSize == 1) pageSize = 65536;
    _pageSize = pageSize;
    _reserved = _bytes[20];
  }

  final Uint8List _bytes;
  late final int _pageSize;
  late final int _reserved;

  int get _usableSize => _pageSize - _reserved;

  int _u16(final int offset) => ByteData.sublistView(_bytes).getUint16(offset);
  int _u32(final int offset) => ByteData.sublistView(_bytes).getUint32(offset);

  /// Reads every row of the table rooted at [rootPage] as
  /// `(rowid, decoded column values)`.
  List<(int, List<Object?>)> readTable(final int rootPage) {
    final rows = <(int, List<Object?>)>[];
    _walk(rootPage, rows);
    return rows;
  }

  void _walk(final int pageNumber, final List<(int, List<Object?>)> rows) {
    final base = (pageNumber - 1) * _pageSize;
    // Page 1 carries the 100-byte database header before its b-tree
    // page header.
    final treeBase = base + (pageNumber == 1 ? 100 : 0);
    final type = _bytes[treeBase];
    final headerSize = type == 0x05 || type == 0x02 ? 12 : 8;
    final cellCount = _u16(treeBase + 3);
    final pointersStart = treeBase + headerSize;

    if (type == 0x05) {
      // Interior table page: cells point at child pages.
      for (var i = 0; i < cellCount; i++) {
        _walk(_u32(base + _u16(pointersStart + i * 2)), rows);
      }
      _walk(_u32(treeBase + 8), rows); // right-most child
      return;
    }
    if (type == 0x0D) {
      // Leaf table page: cells carry the records.
      for (var i = 0; i < cellCount; i++) {
        final cellOffset = _u16(pointersStart + i * 2);
        final (rowid, payload, overflowPage, payloadSize) = _readLeafCell(base, cellOffset);
        rows.add((rowid, _decodeRecord(_assemblePayload(payload, overflowPage, payloadSize))));
      }
      return;
    }
    throw FormatException('Unexpected SQLite page type 0x${type.toRadixString(16)}.');
  }

  (int, Uint8List, int, int) _readLeafCell(final int base, final int offset) {
    var pos = base + offset;
    final (payloadSize, afterSize) = _readVarint(pos);
    final (rowid, afterRowid) = _readVarint(afterSize);
    pos = afterRowid;

    final usable = _usableSize;
    final maxLocal = usable - 35;
    int localSize;
    if (payloadSize <= maxLocal) {
      localSize = payloadSize;
    } else {
      final minLocal = ((usable - 12) * 32 ~/ 255) - 23;
      final k = minLocal + ((payloadSize - minLocal) % (usable - 4));
      localSize = k <= maxLocal ? k : minLocal;
    }

    final payload = Uint8List.sublistView(_bytes, pos, pos + localSize);
    final overflowPage = localSize < payloadSize ? _u32(pos + localSize) : 0;
    return (rowid, Uint8List.fromList(payload), overflowPage, payloadSize);
  }

  Uint8List _assemblePayload(
    final Uint8List local,
    final int firstOverflowPage,
    final int payloadSize,
  ) {
    if (firstOverflowPage == 0) return local;

    final chunks = BytesBuilder(copy: false)..add(local);
    var page = firstOverflowPage;
    while (page != 0 && chunks.length < payloadSize) {
      final base = (page - 1) * _pageSize;
      final take = (payloadSize - chunks.length).clamp(0, _usableSize - 4);
      chunks.add(Uint8List.sublistView(_bytes, base + 4, base + 4 + take));
      page = _u32(base);
    }
    return chunks.toBytes();
  }

  (int, int) _readVarint(final int position) {
    var result = 0;
    var pos = position;
    for (var i = 0; i < 8; i++) {
      final byte = _bytes[pos];
      result = (result << 7) | (byte & 0x7F);
      pos++;
      if (byte & 0x80 == 0) return (result, pos);
    }
    result = (result << 8) | _bytes[pos];
    pos++;
    return (result, pos);
  }

  List<Object?> _decodeRecord(final Uint8List payload) {
    int readLocalVarint(final int position) {
      var result = 0;
      var pos = position;
      for (var i = 0; i < 8; i++) {
        final byte = payload[pos];
        result = (result << 7) | (byte & 0x7F);
        pos++;
        if (byte & 0x80 == 0) return result;
      }
      return (result << 8) | payload[pos];
    }

    final headerSize = readLocalVarint(0);
    var pos = 1;
    final serialTypes = <int>[];
    while (pos < headerSize) {
      final type = readLocalVarint(pos);
      serialTypes.add(type);
      // Multi-byte varints carry 7 bits per byte.
      while (payload[pos] & 0x80 != 0) {
        pos++;
      }
      pos++;
    }

    var body = headerSize;
    final values = <Object?>[];
    for (final type in serialTypes) {
      final (value, size) = _decodeValue(payload, body, type);
      values.add(value);
      body += size;
    }
    return values;
  }

  (Object?, int) _decodeValue(final Uint8List payload, final int offset, final int type) {
    int readInt(final int size) {
      var value = payload[offset] >= 0x80 ? -1 : 0;
      for (var i = 0; i < size; i++) {
        value = (value << 8) | payload[offset + i];
      }
      return value;
    }

    switch (type) {
      case 0:
        return (null, 0);
      case 1:
        return (readInt(1), 1);
      case 2:
        return (readInt(2), 2);
      case 3:
        return (readInt(3), 3);
      case 4:
        return (readInt(4), 4);
      case 5:
        return (readInt(6), 6);
      case 6:
        return (readInt(8), 8);
      case 7:
        return (ByteData.sublistView(payload).getFloat64(offset), 8);
      case 8:
        return (0, 0);
      case 9:
        return (1, 0);
      default:
        if (type >= 12 && type.isEven) {
          final size = (type - 12) ~/ 2;
          return (Uint8List.sublistView(payload, offset, offset + size), size);
        }
        if (type >= 13) {
          final size = (type - 13) ~/ 2;
          final bytes = Uint8List.sublistView(payload, offset, offset + size);
          return (convert.utf8.decode(bytes, allowMalformed: true), size);
        }
        throw FormatException('Unsupported SQLite serial type $type.');
    }
  }
}

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
