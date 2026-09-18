/// Typography normalization heuristics for imported book text.
library;

/// Straight quotes become curly (open after start/whitespace/opening punctuation, close otherwise),
/// `--` becomes an em dash, and `...` becomes an ellipsis.
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
