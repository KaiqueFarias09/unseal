/// Layout and whitespace cleanup heuristics for imported book text.
library;

/// Normalizes common scene-break markers (`* * *`, `***`, `# # #`,
/// `-=-=`) to a single canonical marker so downstream layout sees one representation.
String normalizeSceneBreaks(final String html, {final String marker = '• • •'}) {
  return html.replaceAllMapped(
    RegExp(r'<p[^>]*>\s*(?:[*&#•\-=_]\s*){3,}[*&#•\-=_]?\s*<\/p>', caseSensitive: false),
    (final _) => '<p>$marker</p>',
  );
}

/// Joins lines broken mid-sentence: a newline followed by a lowercase
/// word continues the paragraph. A hyphenated match drops the hyphen; other matches become one
/// space.
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
