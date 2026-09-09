import '../text/plain_text.dart';

/// Basic reading statistics computed from book content.
final class BookStatistics {
  /// Creates statistics with explicit plain-text counts.
  const BookStatistics({required this.characterCount, required this.wordCount});

  /// Builds statistics from the plain text of the book content files.
  factory BookStatistics.fromTexts(final Iterable<String> texts) {
    var words = 0;
    var characters = 0;
    for (final text in texts) {
      words += countWords(text);
      characters += text.length;
    }

    return BookStatistics(wordCount: words, characterCount: characters);
  }

  /// Number of characters of plain text.
  ///
  /// Counted in UTF-16 code units (`String.length`). Calibre counts
  /// code points instead; the two differ only for texts containing
  /// astral characters (emoji, rare hanzi), which are rare in books.
  final int characterCount;

  /// Number of words of plain text.
  ///
  /// Counted the way Calibre does: every CJK code point (anything
  /// above U+3000) is one word and the remaining text is
  /// whitespace-split. CJK punctuation therefore counts as words (a
  /// deliberate Calibre-parity over-count) and space-less scripts such
  /// as Thai are under-counted (parity as well).
  final int wordCount;

  /// Estimated reading duration at [wordsPerMinute] (default 200).
  ///
  /// Derived from [wordCount]. Because CJK text counts one word per
  /// character, the estimate is meaningful for Chinese, Japanese and
  /// Korean text as well.
  Duration estimatedReadingTime({final int wordsPerMinute = 200}) {
    return wordCount <= 0 || wordsPerMinute <= 0
        ? Duration.zero
        : Duration(minutes: (wordCount / wordsPerMinute).ceil());
  }

  @override
  String toString() => 'BookStatistics(words: $wordCount, characters: $characterCount)';
}
