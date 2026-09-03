import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

void main() {
  final database = CalibreDatabase.parse(
    File('test/resources/calibre/metadata.db').readAsBytesSync(),
  );

  group('CalibreDatabase.parse', () {
    test('reads every book of the library', () {
      expect(database.books, hasLength(3));
    });

    test('joins authors, series, tags, identifiers and formats', () {
      final lotr = database.books.firstWhere((final b) => b.id == 1);
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
  });
}
