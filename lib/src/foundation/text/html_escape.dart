import 'dart:convert' as convert;

/// Escapes untrusted document text before placing it in generated XHTML.
String escapeHtml(final String value) => const convert.HtmlEscape().convert(value);
