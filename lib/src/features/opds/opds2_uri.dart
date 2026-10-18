/// URI handling for OPDS 2.0: resolution against an explicit base and a
/// small URI-template expander.
///
/// Unseal never fetches anything. A link's `href` is data; this module
/// only computes what a host would fetch. Relative references resolve
/// only against a base URL the host passes explicitly — the feed URL the
/// host downloaded, an override it chose, or nothing at all. A href with
/// its own scheme (for example `opds://` or `mailto:`) stays untouched
/// data: resolution never invents a fetchable URL for an unknown scheme.
library;

/// Resolves [href] as an OPDS 2.0 link target against [baseUrl].
///
/// Without [baseUrl] the reference is parsed and returned unchanged.
/// With [baseUrl], RFC 3986 resolution applies ([Uri.resolve]); a
/// reference that already carries a scheme resolves to itself, so
/// `opds://` and other non-HTTP targets stay as data. Returns null only
/// when either URI cannot be parsed at all.
Uri? resolveOpds2Href(final String href, {final Uri? baseUrl}) {
  final parsed = Uri.tryParse(href);
  if (parsed == null) return null;
  if (baseUrl == null) return parsed;
  return baseUrl.resolveUri(parsed);
}

/// The RFC 6570 operator characters; `{var}` without one of these is a
/// simple string expansion.
const _templateOperators = <String>{'+', '#', '.', '/', ';', '?', '&'};

/// Expands the supported subset of RFC 6570 URI templates in [template].
///
/// Supported: literal text, simple string expansion `{var}`, and
/// form-style query expansion `{?var}` (the form OPDS 2.0 search uses).
/// Missing values drop the part. Every other expression form
/// (`{+var}`, `{#var}`, `{.var}`, `{/var}`, `{;var}`) is outside the
/// subset and is copied through unchanged, keeping the template as data.
String expandOpds2Template(final String template, final Map<String, Object?> values) {
  final output = StringBuffer();
  var index = 0;
  while (index < template.length) {
    final open = template.indexOf('{', index);
    if (open < 0) {
      output.write(template.substring(index));
      break;
    }
    output.write(template.substring(index, open));
    final close = template.indexOf('}', open);
    if (close < 0) {
      // Unbalanced expression: keep the rest verbatim.
      output.write(template.substring(open));
      break;
    }
    final expression = template.substring(open + 1, close);
    final operator = expression.isEmpty || !_templateOperators.contains(expression[0])
        ? ''
        : expression[0];
    final body = operator.isEmpty ? expression : expression.substring(1);
    if (operator == '' || operator == '?') {
      final parts = <String>[];
      for (final rawName in body.split(',')) {
        final name = rawName.trim();
        if (name.isEmpty) continue;
        final value = _encodeValue(values[name]);
        if (value == null) continue;
        parts.add(operator == '' ? value : '${Uri.encodeComponent(name)}=$value');
      }
      if (parts.isNotEmpty) {
        output.write(operator == '' ? parts.join(',') : '?${parts.join('&')}');
      }
    } else {
      // Unsupported expression form: keep it as data.
      output.write(template.substring(open, close + 1));
    }
    index = close + 1;
  }
  return output.toString();
}

String? _encodeValue(final Object? value) {
  if (value == null) return null;
  final text = value is bool ? (value ? 'true' : 'false') : '$value';
  if (text.isEmpty) return null;
  return Uri.encodeComponent(text);
}
