import 'hocr_exception.dart';

/// One property of an hOCR `title` attribute: the name and the value
/// tokens exactly as written, quotes removed.
final class HocrTitleProperty {
  /// Creates a property.
  const HocrTitleProperty({required this.name, required this.tokens});

  /// The property name (`[a-z][a-z0-9_]*`).
  final String name;

  /// The whitespace-separated value tokens; a quoted string is one token.
  final List<String> tokens;
}

/// Parses an hOCR `title` attribute under the grammar `doc/hocr.md`
/// fixes: `;`-separated properties, the comma rule for kraken-style
/// titles, quoted strings, letter-first lowercase names, no duplicates.
///
/// [maxProperties] and [maxTokens] bound the work; exceeding either, a
/// malformed name, an unterminated quote or a repeated name throws
/// [HocrException].
List<HocrTitleProperty> parseHocrTitle(
  final String title, {
  required final int maxProperties,
  required final int maxTokens,
}) {
  final segments = _splitProperties(title);
  final result = <HocrTitleProperty>[];
  final seen = <String>{};
  for (final segment in segments) {
    final tokens = _tokenize(segment, maxTokens);
    if (tokens.isEmpty) continue;
    final name = tokens.first;
    if (!_isPropertyName(name)) {
      throw HocrException('hOCR title property name "$name" is not lowercase letter-first.');
    }
    if (!seen.add(name)) {
      throw HocrException('hOCR title declares property "$name" more than once.');
    }
    if (result.length >= maxProperties) {
      throw const HocrException('hOCR title exceeds the property budget.');
    }
    result.add(HocrTitleProperty(name: name, tokens: tokens.sublist(1)));
  }

  return result;
}

/// Whether [name] satisfies the property-name grammar.
bool _isPropertyName(final String name) {
  if (name.isEmpty) return false;
  final first = name.codeUnitAt(0);
  if (first < 0x61 || first > 0x7A) return false;
  for (var i = 1; i < name.length; i++) {
    final unit = name.codeUnitAt(i);
    final isLower = unit >= 0x61 && unit <= 0x7A;
    final isDigit = unit >= 0x30 && unit <= 0x39;
    if (!isLower && !isDigit && unit != 0x5F) return false;
  }

  return true;
}

/// Splits on `;` outside quotes, then applies the comma rule inside each
/// segment: a `,` outside quotes followed by optional whitespace, a
/// property name and at least one space starts a new property.
List<String> _splitProperties(final String title) {
  final segments = <String>[];
  var start = 0;
  var inQuote = false;
  for (var i = 0; i < title.length; i++) {
    final unit = title.codeUnitAt(i);
    if (unit == 0x22) {
      inQuote = !inQuote;
    } else if (unit == 0x3B && !inQuote) {
      segments.add(title.substring(start, i));
      start = i + 1;
    } else if (unit == 0x2C && !inQuote && _commaStartsProperty(title, i + 1)) {
      segments.add(title.substring(start, i));
      start = i + 1;
    }
  }
  if (inQuote) {
    throw const HocrException('hOCR title has an unterminated quoted string.');
  }
  segments.add(title.substring(start));

  return segments;
}

/// Whether the text after a comma at [from] reads as `*ws name 1*space`.
bool _commaStartsProperty(final String title, final int from) {
  var i = from;
  while (i < title.length && _isSpace(title.codeUnitAt(i))) {
    i++;
  }
  final nameStart = i;
  while (i < title.length) {
    final unit = title.codeUnitAt(i);
    final isLower = unit >= 0x61 && unit <= 0x7A;
    final isDigit = unit >= 0x30 && unit <= 0x39;
    if (!isLower && !isDigit && unit != 0x5F) break;
    i++;
  }
  if (i == nameStart || !_isPropertyName(title.substring(nameStart, i))) return false;

  return i < title.length && _isSpace(title.codeUnitAt(i));
}

/// Whitespace-separated tokens with quoted strings kept whole, quotes
/// removed.
List<String> _tokenize(final String segment, final int maxTokens) {
  final tokens = <String>[];
  var i = 0;
  while (i < segment.length) {
    final unit = segment.codeUnitAt(i);
    if (_isSpace(unit)) {
      i++;
      continue;
    }
    if (tokens.length > maxTokens) {
      throw const HocrException('hOCR title property exceeds the value token budget.');
    }
    if (unit == 0x22) {
      final close = segment.indexOf('"', i + 1);
      if (close < 0) {
        throw const HocrException('hOCR title has an unterminated quoted string.');
      }
      tokens.add(segment.substring(i + 1, close));
      i = close + 1;
      continue;
    }
    final start = i;
    while (i < segment.length && !_isSpace(segment.codeUnitAt(i))) {
      i++;
    }
    tokens.add(segment.substring(start, i));
  }

  return tokens;
}

bool _isSpace(final int unit) => unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;
