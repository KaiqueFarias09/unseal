/// Reading-experience heuristics ported from the Calibre conversion
/// pipeline (src/calibre/ebooks/oeb/polish/smarten_punctuation.py and
/// the heuristic processing in calibre.ebooks.heuristics). Pure string
/// transforms over the HTML/text of one document — apply at import
/// time for books whose source lacks proper typography or navigation.
library;

/// Chapter heading candidates found in [text], in document order.
/// Parity: calibre heuristic chapter detection ("Chapter N",
/// localized "Capítulo/Capitolo/Kapitel", roman numerals alone on a
/// line, ALL-CAPS short lines).
class ChapterGuess {
  const ChapterGuess({required this.title, required this.offset});

  /// Detected heading text.
  final String title;

  /// Character offset of the heading line in [text].
  final int offset;
}

/// Parity: calibre smarten_punctuation — straight quotes become curly
/// (open if preceded by start/whitespace/opening punctuation, close
/// otherwise), `--` becomes an em dash and `...` an ellipsis.
String smartenPunctuation(final String text) {
  final out = text.replaceAll('...', '…').replaceAll('--', '—');
  final quote = StringBuffer();
  var previous = '\n';
  for (var i = 0; i < out.length; i++) {
    final char = out[i];
    if (char == '"') {
      final opens = RegExp(r'[\s\(\[\{—–]').hasMatch(previous);
      quote.write(opens ? '\u201C' : '\u201D');
    } else if (char == "'") {
      final opens = RegExp(r'[\s\(\[\{—–]').hasMatch(previous);
      quote.write(opens ? '\u2018' : '\u2019');
    } else {
      quote.write(char);
    }
    previous = char;
  }

  return quote.toString();
}

/// Normalizes common scene-break markers (`* * *`, `***`, `# # #`,
/// `-=-=`) to a single canonical marker. Parity: calibre heuristic
/// scene-break detection (calibre.ebooks.heuristics).
String normalizeSceneBreaks(final String html, {final String marker = '• • •'}) {
  return html.replaceAllMapped(
    RegExp(r'<p[^>]*>\s*(?:[*&#•\-=_]\s*){3,}[*&#•\-=_]?\s*<\/p>', caseSensitive: false),
    (final _) => '<p>$marker</p>',
  );
}

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

List<ChapterGuess> guessChapters(final String text) {
  final guesses = <ChapterGuess>[];
  for (final match in _chapterKeyword.allMatches(text)) {
    final line = match.group(0)?.trim();
    if (line == null || line.isEmpty) {
      continue;
    }
    guesses.add(ChapterGuess(title: line, offset: match.start));
  }
  for (final match in _romanOrCaps.allMatches(text)) {
    final line = match.group(0)?.trim();
    if (line == null || line.isEmpty) {
      continue;
    }
    guesses.add(ChapterGuess(title: line, offset: match.start));
  }
  guesses.sort((final a, final b) => a.offset.compareTo(b.offset));

  return guesses;
}

/// Joins lines broken mid-sentence: a newline followed by a lowercase
/// word continues the paragraph. Parity: calibre heuristic "unwrap
/// hard line breaks".
String unwrapHardLineBreaks(final String text) {
  // A hyphen at the break is a soft hyphenation: join without it.
  final out = text.replaceAllMapped(
    RegExp('([a-z\\u00C0-\\u024F])\\-[ \\t]*\\n([a-z\\u00C0-\\u024F])'),
    (final m) => '${m.group(1)}${m.group(2)}',
  );

  return out.replaceAllMapped(
    RegExp('([a-z,;])[ \\t]*\\n([a-z\\u00C0-\\u024F])'),
    (final m) => '${m.group(1)} ${m.group(2)}',
  );
}
