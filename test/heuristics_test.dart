import 'package:e_livre/src/heuristics.dart';
import 'package:test/test.dart';

/// Parity tests for the Calibre heuristic-processing port
/// (src/calibre/ebooks/oeb/polish/smarten_punctuation.py and
/// calibre.ebooks.heuristics). The Calibre ships no unit tests for
/// these transforms; the golden values below pin the behaviour the
/// port reproduces.
void main() {
  group('smartenPunctuation', () {
    test('opens quotes after whitespace and closes before it', () {
      expect(smartenPunctuation('She said "hello" to me'), 'She said “hello” to me');
      expect(smartenPunctuation("'Twas the night"), '\u2018Twas the night');
      expect(smartenPunctuation("the boy's book"), 'the boy\u2019s book');
    });

    test('dashes and ellipses', () {
      expect(smartenPunctuation('wait--what'), 'wait\u2014what');
      expect(smartenPunctuation('and then... nothing'), 'and then\u2026 nothing');
    });

    test('leaves existing typography alone', () {
      expect(smartenPunctuation('“curly” — already'), '“curly” — already');
    });
  });

  group('normalizeSceneBreaks', () {
    test('canonicalizes the common markers', () {
      expect(normalizeSceneBreaks('<p>* * *</p>'), '<p>• • •</p>');
      expect(normalizeSceneBreaks('<p>***</p>'), '<p>• • •</p>');
      expect(normalizeSceneBreaks('<p class="mb">-=-=</p>'), '<p>• • •</p>');
    });

    test('leaves normal paragraphs alone', () {
      expect(normalizeSceneBreaks('<p>once * twice</p>'), '<p>once * twice</p>');
    });
  });

  group('guessChapters', () {
    test('detects english, portuguese and roman headings', () {
      final guesses = guessChapters('''
preface text
Chapter 1: Down the Rabbit-Hole
body text
CAPÍTULO 3 - A Pool
more text
VI
even more text
''');
      final titles = guesses.map((final g) => g.title).toList();
      expect(titles, contains('Chapter 1: Down the Rabbit-Hole'));
      expect(titles, contains('CAPÍTULO 3 - A Pool'));
      expect(titles, contains('VI'));
      expect(guesses.length, 3);
      // Offsets are in document order.
      expect(guesses.first.offset, lessThan(guesses.last.offset));
    });

    test('does not fire on prose containing the word chapter', () {
      expect(guessChapters('the chapter of my life is long\n').length, 0);
    });
  });

  group('unwrapHardLineBreaks', () {
    test('joins mid-sentence breaks, keeps paragraph breaks', () {
      expect(
        unwrapHardLineBreaks('broken sen-\ntence here\n\nNew paragraph'),
        'broken sentence here\n\nNew paragraph',
      );
    });
  });
}
