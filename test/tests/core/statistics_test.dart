import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

void main() {
  group('extractPlainText', () {
    test('strips tags and decodes entities', () {
      const html =
          '<p>Hello&nbsp;<b>world</b> &amp; friends!</p>'
          '<script>evil()</script>';
      expect(extractPlainText(html), 'Hello world & friends!');
    });

    test('decodes numeric entities', () {
      expect(extractPlainText('&#65;&#x42;'), 'AB');
    });

    test('collapses whitespace runs', () {
      expect(extractPlainText('<p>a\n\t  b</p>'), 'a b');
    });
  });

  group('countWords', () {
    test('counts whitespace separated words', () {
      expect(countWords('one two  three\n\tfour'), 4);
      expect(countWords(''), 0);
      expect(countWords('   '), 0);
    });
  });

  group('BookStatistics', () {
    test('MOBI statistics are computed from the content', () {
      final book = parseMobiBook(File('test/resources/mobi/alice-old.mobi').readAsBytesSync());
      final statistics = book.statistics;
      expect(statistics.wordCount, greaterThan(20000));
      expect(statistics.characterCount, greaterThan(statistics.wordCount));
      final reading = statistics.estimatedReadingTime();
      expect(reading.inMinutes, greaterThan(10));
      expect(
        statistics.estimatedReadingTime(wordsPerMinute: 400).inMinutes,
        lessThan(reading.inMinutes),
      );
    });

    test('FB2 statistics are computed from the content', () {
      final book = parseFb2Book(
        Uint8List.fromList(File('test/resources/fb2/alice.fb2').readAsBytesSync()),
      );
      expect(book.statistics.wordCount, greaterThan(20000));
    });

    test('plainText on TextFile matches the util', () {
      final file = TextFile(
        name: 'a.html',
        type: 'html',
        path: 'a.html',
        content: '<p>ola &amp; mundo</p>',
      );
      expect(file.plainText, 'ola & mundo');
    });
  });
}
