import 'package:e_livre/features/core/utils/plain_text.dart';

/// Basic reading statistics computed from book content.
final class BookStatistics {
  const BookStatistics({
    required this.wordCount,
    required this.characterCount,
  });

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

  /// Number of whitespace-separated words.
  ///
  /// CJK text is under-counted since it carries no spaces.
  final int wordCount;

  /// Number of characters of plain text.
  final int characterCount;

  /// Estimated reading duration at [wordsPerMinute] (default 200).
  Duration estimatedReadingTime({final int wordsPerMinute = 200}) {
    if (wordCount <= 0 || wordsPerMinute <= 0) {
      return Duration.zero;
    }
    return Duration(minutes: (wordCount / wordsPerMinute).ceil());
  }

  @override
  String toString() =>
      'BookStatistics(words: $wordCount, characters: $characterCount)';
}
