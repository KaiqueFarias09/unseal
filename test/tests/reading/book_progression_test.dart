import 'dart:io';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import 'synthetic_books.dart';

void main() {
  group('BookProgression over a synthetic book', () {
    // Section document texts: 'abcdef' (6), 'hello' (5), an image
    // page (0), 'xy' (2) — starts at 0, 6, 11, 11; total 13.
    final book = SyntheticBook(
      files: htmlFiles([
        '<html><body><p>abcdef</p></body></html>',
        '<html><body><p>hello</p></body></html>',
        '<html><body><p>xy</p></body></html>',
      ]),
      navigation: navigationOf(const <NavPoint>[]),
      order: const <ReadingOrderItem>[
        ReadingOrderItem(name: 'section0.html'),
        ReadingOrderItem(name: 'section1.html'),
        ReadingOrderItem(name: 'page-1.png', isHtml: false),
        ReadingOrderItem(name: 'section2.html'),
      ],
    );
    final progression = BookProgression.of(book);

    test('measures every HTML section and skips image pages', () {
      expect(progression.sectionCount, 4);
      expect(progression.totalCharacters, 13);
    });

    test('sectionFraction spans 0..1 and clamps', () {
      expect(progression.sectionFraction(sectionIndex: 0, charOffset: 0), 0);
      expect(progression.sectionFraction(sectionIndex: 0, charOffset: 3), closeTo(0.5, 1e-9));
      expect(progression.sectionFraction(sectionIndex: 0, charOffset: 6), 1);
      expect(progression.sectionFraction(sectionIndex: 0, charOffset: 99), 1);
      expect(progression.sectionFraction(sectionIndex: 0, charOffset: -5), 0);
      expect(progression.sectionFraction(sectionIndex: 2, charOffset: 0), 0);
    });

    test('fractionOf accumulates preceding sections', () {
      expect(progression.fractionOf(sectionIndex: 0), 0);
      expect(progression.fractionOf(sectionIndex: 1), closeTo(6 / 13, 1e-9));
      expect(progression.fractionOf(sectionIndex: 1, charOffset: 5), closeTo(11 / 13, 1e-9));
      // The image page occupies an index but adds no text.
      expect(progression.fractionOf(sectionIndex: 2), closeTo(11 / 13, 1e-9));
      expect(progression.fractionOf(sectionIndex: 3, charOffset: 2), closeTo(1, 1e-9));
    });

    test('out-of-range queries clamp instead of throwing', () {
      expect(progression.fractionOf(sectionIndex: 99), 1);
      expect(progression.fractionOf(sectionIndex: -1), 0);
      expect(progression.sectionFraction(sectionIndex: 99, charOffset: 0), 0);
    });
  });

  group('BookProgression over non-text books', () {
    test('a comic-like book falls back to section positions', () {
      final book = SyntheticBook(
        files: htmlFiles(const <String>[]),
        navigation: navigationOf(const <NavPoint>[]),
        order: const <ReadingOrderItem>[
          ReadingOrderItem(name: 'p1.png', isHtml: false),
          ReadingOrderItem(name: 'p2.png', isHtml: false),
          ReadingOrderItem(name: 'p3.png', isHtml: false),
          ReadingOrderItem(name: 'p4.png', isHtml: false),
        ],
      );
      final progression = BookProgression.of(book);

      expect(progression.sectionCount, 4);
      expect(progression.totalCharacters, 0);
      expect(progression.sectionFraction(sectionIndex: 1, charOffset: 10), 0);
      expect(progression.fractionOf(sectionIndex: 0), 0);
      expect(progression.fractionOf(sectionIndex: 2), closeTo(0.5, 1e-9));
      expect(progression.fractionOf(sectionIndex: 4), 1);
    });

    test('an empty book measures zero and stays safe', () {
      final book = SyntheticBook(
        files: htmlFiles(const <String>[]),
        navigation: navigationOf(const <NavPoint>[]),
      );
      final progression = BookProgression.of(book);

      expect(progression.sectionCount, 0);
      expect(progression.totalCharacters, 0);
      expect(progression.fractionOf(sectionIndex: 0), 0);
      expect(progression.sectionFraction(sectionIndex: 0, charOffset: 0), 0);
    });
  });

  group('BookProgression over a real EPUB', () {
    final book = parseEpubBook(
      File('test/resources/epub/Alices Adventures in Wonderland.epub').readAsBytesSync(),
    );
    final progression = BookProgression.of(book);

    int lengthOf(final int index) {
      final name = book.readingOrder[index].name;
      return documentTextOf(book.files.html.firstWhere((final file) => file.path == name)).length;
    }

    test('totals the document text of every section', () {
      var expected = 0;
      for (var i = 0; i < progression.sectionCount; i++) {
        expected += lengthOf(i);
      }
      expect(progression.totalCharacters, expected);
      expect(progression.totalCharacters, greaterThan(0));
    });

    test('fractions are monotonic in position and span 0..1', () {
      expect(progression.fractionOf(sectionIndex: 0), 0);
      final last = progression.sectionCount - 1;

      var previous = -1.0;
      for (var i = 0; i < progression.sectionCount; i++) {
        final length = lengthOf(i);
        for (final step in const <double>[0, 0.25, 0.5, 1]) {
          final offset = (step * length).floor();
          final current = progression.fractionOf(
            sectionIndex: i,
            charOffset: offset > length ? length : offset,
          );
          expect(current, inInclusiveRange(0, 1));
          expect(current, greaterThanOrEqualTo(previous));
          previous = current;
        }
      }
      expect(progression.fractionOf(sectionIndex: last, charOffset: lengthOf(last)), 1);
    });

    test('sectionFraction respects section boundaries', () {
      for (var i = 0; i < progression.sectionCount; i++) {
        final length = lengthOf(i);
        expect(progression.sectionFraction(sectionIndex: i, charOffset: 0), 0);
        expect(
          progression.sectionFraction(sectionIndex: i, charOffset: length),
          length > 0 ? 1 : 0,
        );
      }
    });
  });
}
