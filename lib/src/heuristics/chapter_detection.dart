/// Chapter heading detection heuristics for imported book text.
library;

// Chapter-number headings match case-insensitively; standalone roman
// numerals and ALL-CAPS lines must stay case-sensitive.
final RegExp _chapterKeyword = RegExp(
  r'^\s*(?:chapter|cap[i\u00ED]tulo|capitolo|kapitel)\s+([0-9]+|[ivxlcIVXLC]+)\b[^\n]{0,60}\s*$',
  multiLine: true,
  caseSensitive: false,
);

final RegExp _romanOrCaps = RegExp(
  r'''^\s*(?:[IVXLC]{1,7}|[A-Z][A-Z\s:'\-,.]{3,60})\s*$''',
  multiLine: true,
);

/// Chapter heading candidates found in the input text, in document order.
/// Candidates include "Chapter N", localized "Capítulo/Capitolo/Kapitel", Roman numerals alone on
/// a line, and short ALL-CAPS lines.
class ChapterGuess {
  /// Creates a chapter candidate with its title and source offset.
  const ChapterGuess({required this.title, required this.offset});

  /// Detected heading text.
  final String title;

  /// Character offset of the heading line in `text`.
  final int offset;
}

/// Finds likely chapter headings in [text], ordered by their character offset.
List<ChapterGuess> guessChapters(final String text) {
  final guesses = <ChapterGuess>[];
  for (final match in _chapterKeyword.allMatches(text)) {
    final line = match.group(0)?.trim();
    if (line == null || line.isEmpty) continue;

    guesses.add(ChapterGuess(title: line, offset: match.start));
  }
  for (final match in _romanOrCaps.allMatches(text)) {
    final line = match.group(0)?.trim();
    if (line == null || line.isEmpty) continue;

    guesses.add(ChapterGuess(title: line, offset: match.start));
  }
  guesses.sort((final a, final b) => a.offset.compareTo(b.offset));

  return guesses;
}
