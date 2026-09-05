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

    test('Latin text keeps the whitespace-split count', () {
      expect(countWords('hello, world!'), 2);
      expect(countWords('one\ntwo\rthree four'), 4);
      // NBSP splits like Python's str.split (Calibre parity).
      expect(countWords('a\u00A0b c'), 3);
    });

    test('pure CJK counts one word per character', () {
      // No spaces: every code point above U+3000 is one word.
      expect(countWords('吾輩は猫である名前はまだ無い'), 14);
      expect(countWords('这是一个中文测试句子'), 10);
      expect(countWords('이것은한국어문장입니다'), 11);
    });

    test('mixed Latin and CJK sums both counts', () {
      // The docstring example of Calibre's nonj_len: 7 CJK characters
      // plus the 2 Latin words interleaved with them.
      expect(countWords('日本語AアジアンB'), 9);
      expect(countWords('hello 世界 world'), 4);
    });

    test('CJK punctuation counts as a word (Calibre parity over-count)', () {
      // 猫、犬。 is four code points above U+3000, so four "words" —
      // the two full-width marks inflate the count on purpose.
      expect(countWords('猫、犬。'), 4);
    });

    test('the ideographic space U+3000 splits like whitespace', () {
      expect(countWords('川\u3000犬'), 2);
      expect(countWords('a\u3000b'), 2);
      expect(countWords('\u3000\u3000'), 0);
    });

    test('space-less scripts stay under-counted (Calibre parity)', () {
      // Thai sits below U+3000 and carries no spaces: the whole run is
      // one "word" here and in Calibre alike.
      expect(countWords('ภาษาไทยไม่มีช่องว่างระหว่างคำ'), 1);
    });

    test('astral code points count once each', () {
      expect(countWords('a \u{1F600} b'), 3);
      expect(countWords('\u{1F600}\u{1F600}'), 2);
    });

    test('empty and whitespace-only text count zero words', () {
      expect(countWords(''), 0);
      expect(countWords(' \t\n\r '), 0);
      expect(countWords('\u3000'), 0);
    });
  });

  group('BookStatistics — CJK word counting', () {
    test('word counts follow the Calibre formula', () {
      final statistics = BookStatistics.fromTexts(['Hello world. ', '吾輩は猫である。名前はまだ無い。']);
      // 2 Latin words + 14 CJK characters + 2 CJK full stops.
      expect(statistics.wordCount, 18);
      // characterCount stays UTF-16 code units (String.length): all
      // BMP here, so 13 + 16.
      expect(statistics.characterCount, 29);
    });

    test('estimated reading time scales with CJK word counts', () {
      final statistics = BookStatistics.fromTexts(['猫' * 200]);
      expect(statistics.wordCount, 200);
      expect(statistics.estimatedReadingTime().inMinutes, 1);
      expect(statistics.estimatedReadingTime(wordsPerMinute: 100).inMinutes, 2);
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
