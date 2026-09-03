/// The canonical character space of a content file: the concatenation
/// of the visible text inside `<body>`, with entities decoded and
/// whitespace kept as-is.
///
/// A WebView-based reader walks the DOM text nodes rooted at
/// `<body>` (skipping `script`/`style`) and concatenates them;
/// [documentText] mirrors that exactly on the HTML source: everything
/// outside `<body>` (head, title, doctype) contributes nothing,
/// entities are decoded in a single pass (like the HTML parser), tags
/// and comments contribute nothing, whitespace is kept as-is. Char
/// offsets in this space are stable across reflow and match the DOM
/// on the WebView side — search, CFI and reading positions all share
/// it.
library;

/// Extracts the canonical document text of an HTML/XHTML [html]
/// source.
String documentText(final String html) {
  var text = html;
  final body = RegExp(
    r'<body[^>]*>(.*)</body>',
    dotAll: true,
    caseSensitive: false,
  ).firstMatch(text);
  if (body != null) {
    text = body.group(1)!;
  }
  return text
      .replaceAll(
        RegExp(r'<(script|style)\b[^>]*>.*?</\1>', dotAll: true, caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
      .replaceAll(RegExp(r'<!\[CDATA\[(.*?)\]\]>', dotAll: true), r'$1')
      .replaceAll(RegExp(r'<![^>]*>'), '')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAllMapped(_entityPattern, (final match) {
        return decodeEntity(match.group(1)!) ?? match.group(0)!;
      });
}

final RegExp _entityPattern = RegExp(
  r'&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});',
);

/// Decodes a single entity body (without `&` and `;`).
String? decodeEntity(final String body) {
  if (body.startsWith('#')) {
    final codePoint = body.startsWith('#x') || body.startsWith('#X')
        ? int.tryParse(body.substring(2), radix: 16)
        : int.tryParse(body.substring(1));
    if (codePoint == null || codePoint < 0 || codePoint > 0x10FFFF) {
      return null;
    }
    // HTML parser maps NUL and C1 controls to the replacement char.
    if (codePoint == 0 || (codePoint >= 0x80 && codePoint <= 0x9F)) {
      return String.fromCharCodes(const [0xFFFD]);
    }
    return String.fromCharCodes([codePoint]);
  }
  return _namedEntities[body];
}

const Map<String, String> _namedEntities = <String, String>{
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': '\u00A0',
  'copy': '\u00A9',
  'reg': '\u00AE',
  'trade': '\u2122',
  'hellip': '\u2026',
  'mdash': '\u2014',
  'ndash': '\u2013',
  'lsquo': '\u2018',
  'rsquo': '\u2019',
  'ldquo': '\u201C',
  'rdquo': '\u201D',
  'laquo': '\u00AB',
  'raquo': '\u00BB',
  'deg': '\u00B0',
  'plusmn': '\u00B1',
  'times': '\u00D7',
  'divide': '\u00F7',
  'eacute': '\u00E9',
  'egrave': '\u00E8',
  'agrave': '\u00E0',
  'ccedil': '\u00E7',
  'uuml': '\u00FC',
  'ouml': '\u00F6',
  'auml': '\u00E4',
  'szlig': '\u00DF',
};
