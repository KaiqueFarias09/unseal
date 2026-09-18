import '../text/word_count.dart';

/// Basic reading statistics computed from book content.
final class BookStatistics {
  /// Creates statistics with explicit plain-text counts.
  const BookStatistics({required this.characterCount, required this.wordCount});

  /// Builds statistics from the plain text of the book content files.
  factory BookStatistics.fromTexts(final Iterable<String> texts) {
    var wordsCount = 0;
    var characters = 0;
    for (final text in texts) {
      wordsCount += countWords(text);
      characters += text.length;
    }

    return BookStatistics(wordCount: wordsCount, characterCount: characters);
  }

  /// Number of characters of plain text.
  ///
  /// Counted in UTF-16 code units (`String.length`), matching Dart's string API. Astral characters
  /// such as emoji and rare hanzi therefore contribute two units instead of one code point.
  final int characterCount;

  /// Number of words of plain text.
  ///
  /// Counts each code point strictly above U+3000 as one word and splits the remaining text on
  /// whitespace. CJK punctuation therefore counts as words, while space-less scripts such as Thai
  /// are under-counted.
  final int wordCount;

  /// Estimated reading duration at [wordsPerMinute] (default 200).
  ///
  /// Derived from [wordCount]. Because CJK text counts one word per character, the estimate is
  /// meaningful for Chinese, Japanese and Korean text as well.
  Duration estimatedReadingTime({final int wordsPerMinute = 200}) {
    return wordCount <= 0 || wordsPerMinute <= 0
        ? Duration.zero
        : Duration(minutes: (wordCount / wordsPerMinute).ceil());
  }

  @override
  String toString() => 'BookStatistics(words: $wordCount, characters: $characterCount)';
}
