import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

Uint8List _bytes() => Uint8List.fromList([1, 2, 3]);

void main() {
  group('mergeBookMetadata', () {
    test('overlay values win over base values', () {
      const base = BookMetadata(
        format: BookFormat.mobi,
        title: 'Base',
        authors: ['A'],
        series: 'Base Series',
      );
      const overlay = BookMetadata(
        format: BookFormat.mobi,
        title: 'Overlay',
        authors: ['B'],
        seriesIndex: 2,
      );
      final merged = mergeBookMetadata(base, overlay);
      expect(merged.title, 'Overlay');
      expect(merged.authors, ['B']);
      expect(merged.series, 'Base Series'); // overlay had none
      expect(merged.seriesIndex, 2);
    });

    test('empty overlay values do not clobber the base', () {
      const base = BookMetadata(
        format: BookFormat.epub,
        title: 'Kept',
        authors: ['Kept Author'],
        subjects: ['keep'],
      );
      final merged = mergeBookMetadata(
        base,
        const BookMetadata(format: BookFormat.epub, title: ''),
      );
      expect(merged.title, 'Kept');
      expect(merged.authors, ['Kept Author']);
      expect(merged.subjects, ['keep']);
    });

    test('identifiers merge per key', () {
      final merged = mergeBookMetadata(
        const BookMetadata(format: BookFormat.epub, identifiers: {'uuid': 'u1', 'asin': 'a1'}),
        const BookMetadata(format: BookFormat.epub, identifiers: {'uuid': 'u2'}),
      );
      expect(merged.identifiers['uuid'], 'u2');
      expect(merged.identifiers['asin'], 'a1');
    });

    test('base cover survives without an overlay cover', () {
      final baseCover = BookCover(bytes: _bytes(), type: ImageType.jpeg);
      final merged = mergeBookMetadata(
        BookMetadata(format: BookFormat.epub, cover: baseCover),
        const BookMetadata(format: BookFormat.epub),
      );
      expect(merged.cover, same(baseCover));
    });

    test('sort keys and producer merge like scalar fields', () {
      final merged = mergeBookMetadata(
        const BookMetadata(format: BookFormat.epub, authorSort: 'Kept, Author'),
        const BookMetadata(
          format: BookFormat.epub,
          titleSort: 'New Sort',
          bookProducer: 'calibre (9.4.0)',
        ),
      );
      expect(merged.titleSort, 'New Sort');
      expect(merged.authorSort, 'Kept, Author');
      expect(merged.bookProducer, 'calibre (9.4.0)');
    });
  });

  group('BookMetadata.copyWith', () {
    const metadata = BookMetadata(format: BookFormat.epub, title: 'T');

    test('overrides the provided fields and keeps the rest', () {
      final copy = metadata.copyWith(
        title: 'T2',
        titleSort: 'S',
        authorSort: 'A, B',
        bookProducer: 'calibre',
      );
      expect(copy.title, 'T2');
      expect(copy.titleSort, 'S');
      expect(copy.authorSort, 'A, B');
      expect(copy.bookProducer, 'calibre');
      expect(copy.format, BookFormat.epub);
    });

    test('sort keys survive a copy that does not touch them', () {
      final copy = metadata.copyWith(titleSort: 'S', authorSort: 'A, B').copyWith();
      expect(copy.titleSort, 'S');
      expect(copy.authorSort, 'A, B');
      expect(copy.bookProducer, isNull);
    });
  });

  group('applyFilenameFallback', () {
    test('fills missing title and author', () {
      final metadata = applyFilenameFallback(
        const BookMetadata(format: BookFormat.epub),
        '/books/Some Great Title - Jane Doe.epub',
      );
      expect(metadata.title, 'Some Great Title');
      expect(metadata.authors, ['Jane Doe']);
    });

    test('title may contain dashes', () {
      final metadata = applyFilenameFallback(
        const BookMetadata(format: BookFormat.mobi),
        '/books/The Sub-Title Book - John Smith.mobi',
      );
      expect(metadata.title, 'The Sub-Title Book');
      expect(metadata.authors, ['John Smith']);
    });

    test('existing metadata is preserved', () {
      final metadata = applyFilenameFallback(
        const BookMetadata(format: BookFormat.epub, title: 'Real', authors: ['A']),
        '/books/Fake - Name.epub',
      );
      expect(metadata.title, 'Real');
      expect(metadata.authors, ['A']);
    });

    test('files without the pattern are unchanged', () {
      final metadata = applyFilenameFallback(
        const BookMetadata(format: BookFormat.epub),
        '/books/justabookname.epub',
      );
      expect(metadata.title, isNull);
      expect(metadata.authors, isEmpty);
    });
  });

  group('parseSeriesIndex', () {
    test('parses plain and comma decimals', () {
      expect(parseSeriesIndex('2'), 2.0);
      expect(parseSeriesIndex('2,5'), 2.5);
      expect(parseSeriesIndex(' 0.5 '), 0.5);
      expect(parseSeriesIndex('abc'), isNull);
      expect(parseSeriesIndex(null), isNull);
    });
  });
}
