/// Extracts the readable plain text out of an HTML/XHTML document.
///
/// Removes `script`/`style` blocks, strips tags, decodes the common
/// named and numeric entities and collapses whitespace runs into
/// single spaces.
String extractPlainText(final String html) {
  var text = html
      .replaceAll(RegExp(r'<(script|style)\b[^>]*>.*?</\1>', dotAll: true, caseSensitive: false), ' ')
      .replaceAll(RegExp('<!--.*?-->', dotAll: true), ' ')
      .replaceAll(RegExp('<[^>]*>'), ' ');

  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (final match) => String.fromCharCode(int.parse(match.group(1)!)),
      )
      .replaceAllMapped(
        RegExp('&#x([0-9A-Fa-f]+);'),
        (final match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
      );

  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Counts whitespace-separated words in [text].
int countWords(final String text) {
  var count = 0;
  var inWord = false;
  for (final codeUnit in text.codeUnits) {
    final isSpace = codeUnit == 0x20 || (codeUnit >= 0x09 && codeUnit <= 0x0D);
    if (isSpace) {
      inWord = false;
    } else if (!inWord) {
      inWord = true;
      count++;
    }
  }
  return count;
}
