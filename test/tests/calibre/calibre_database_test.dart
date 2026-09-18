import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

void main() {
  final databaseBytes = File('test/resources/calibre/metadata.db').readAsBytesSync();
  final database = CalibreDatabase.parse(databaseBytes);

  group('CalibreDatabase.parse', () {
    test('reads every book of the library', () {
      expect(database.books, hasLength(3));
    });

    test('joins authors, series, tags, identifiers and formats', () {
      final CalibreBook lotr = database.books.firstWhere((final b) => b.id == 1);
      expect(lotr.title, 'The Lord of the Rings');
      expect(lotr.titleSort, 'Lord of the Rings, The');
      expect(lotr.authors, ['J.R.R. Tolkien']);
      expect(lotr.series, 'Middle Earth');
      expect(lotr.seriesIndex, 2.0);
      expect(lotr.tags, ['fantasy']);
      expect(lotr.identifiers['isbn'], '9780452284234');
      expect(lotr.identifiers['goodreads'], '123');
      expect(lotr.formats, ['EPUB', 'MOBI']);
      expect(lotr.timestamp, DateTime.parse('2024-01-15T10:30:00.000000Z'));
      expect(lotr.path, 'J.R.R. Tolkien/The Lord of the Rings (42)');
    });

    test('uses books.isbn when no ISBN identifier exists', () {
      final withoutIsbnIdentifier = _replaceAsciiOccurrence(
        databaseBytes,
        original: 'isbn',
        replacement: 'asin',
        occurrenceIndex: 1,
      );

      final book = CalibreDatabase.parse(
        withoutIsbnIdentifier,
      ).books.firstWhere((final book) => book.id == 1);

      expect(book.identifiers['isbn'], '9780452284234');
      expect(book.identifiers['asin'], '9780452284234');
    });

    test('prefers the identifiers row over books.isbn', () {
      final identifierValueDiffers = _replaceAsciiOccurrence(
        databaseBytes,
        original: '9780452284234',
        replacement: '1111111111111',
        occurrenceIndex: 1,
      );

      final book = CalibreDatabase.parse(
        identifierValueDiffers,
      ).books.firstWhere((final book) => book.id == 1);

      expect(book.identifiers['isbn'], '1111111111111');
    });

    test('exposes an immutable imported snapshot', () {
      final lotr = database.books.first;

      expect(database.books.clear, throwsUnsupportedError);
      expect(lotr.authors.clear, throwsUnsupportedError);
      expect(lotr.tags.clear, throwsUnsupportedError);
      expect(lotr.identifiers.clear, throwsUnsupportedError);
      expect(lotr.formats.clear, throwsUnsupportedError);
    });

    test('handles books without series, tags or authors', () {
      final comments = database.books.firstWhere((final b) => b.id == 3);
      expect(comments.authors, isEmpty);
      expect(comments.series, isNull);
      expect(comments.seriesIndex, 1.0);
      expect(comments.tags, isEmpty);
      expect(comments.identifiers, isEmpty);
    });

    test('keeps non-ascii titles and author sorts', () {
      final cortico = database.books.firstWhere((final b) => b.id == 2);
      expect(cortico.title, 'O Cortiço');
      expect(cortico.authorSort, 'Azevedo, Aluísio');
      expect(cortico.identifiers['amazon'], 'B00XYZ');
    });

    test('rejects files that are not SQLite databases', () {
      final bytes = Uint8List.fromList('not a database at all'.codeUnits);
      expect(() => CalibreDatabase.parse(bytes), throwsFormatException);
    });

    test('rejects files shorter than the SQLite header', () {
      final bytes = Uint8List.fromList('SQLite format 3\u0000'.codeUnits);
      expect(() => CalibreDatabase.parse(bytes), throwsFormatException);
    });

    test('rejects a complete header without its declared page', () {
      final bytes = Uint8List(100);
      bytes.setRange(0, 16, 'SQLite format 3\u0000'.codeUnits);
      ByteData.sublistView(bytes).setUint16(16, 4096);

      expect(() => CalibreDatabase.parse(bytes), throwsFormatException);
    });

    test('rejects cycles in a table b-tree', () {
      final bytes = Uint8List.fromList(databaseBytes);
      final view = ByteData.sublistView(bytes);
      final pageSize = view.getUint16(16);
      const booksRootPage = 4;
      final booksPage = (booksRootPage - 1) * pageSize;
      bytes[booksPage] = 0x05;
      view.setUint16(booksPage + 3, 0);
      view.setUint32(booksPage + 8, booksRootPage);

      expect(() => CalibreDatabase.parse(bytes), throwsFormatException);
    });
  });
}

Uint8List _replaceAsciiOccurrence(
  final Uint8List source, {
  required final String original,
  required final String replacement,
  required final int occurrenceIndex,
}) {
  if (original.length != replacement.length) {
    throw ArgumentError('Replacement must preserve the SQLite record length.');
  }

  final bytes = Uint8List.fromList(source);
  final originalBytes = original.codeUnits;
  final replacementBytes = replacement.codeUnits;
  var matchOffset = -1;
  var searchOffset = 0;
  for (var index = 0; index <= occurrenceIndex; index++) {
    matchOffset = _indexOfBytes(bytes, originalBytes, searchOffset);
    if (matchOffset == -1) {
      throw StateError('Fixture does not contain occurrence $occurrenceIndex of `$original`.');
    }
    searchOffset = matchOffset + originalBytes.length;
  }

  bytes.setRange(matchOffset, matchOffset + replacementBytes.length, replacementBytes);
  return bytes;
}

int _indexOfBytes(final Uint8List source, final List<int> pattern, final int start) {
  for (var offset = start; offset <= source.length - pattern.length; offset++) {
    var matches = true;
    for (var index = 0; index < pattern.length; index++) {
      if (source[offset + index] != pattern[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return offset;
  }

  return -1;
}
