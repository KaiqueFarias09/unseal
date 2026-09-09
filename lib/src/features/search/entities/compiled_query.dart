/// A compiled internal search query that owns candidate validation and offset recovery.
///
/// This type is public-named only because Dart privacy is library-scoped. It remains an
/// implementation detail under `lib/src` and is not exported from a package entry point.
final class CompiledQuery {
  /// Creates a compiled query from its candidate and optional required-word patterns.
  const CompiledQuery(this._pattern, this._requiredWords, {final bool hasTokenSpanGroup = false})
    : _hasTokenSpanGroup = hasTokenSpanGroup;

  final RegExp _pattern;
  final List<RegExp>? _requiredWords;
  final bool _hasTokenSpanGroup;

  /// Finds valid query spans in [text] as half-open `[start, end)` offsets.
  Iterable<({int start, int end})> findMatches(final String text) sync* {
    for (final candidate in _pattern.allMatches(text)) {
      final requiredWords = _requiredWords;
      if (requiredWords != null && !_hasAllWordsInWindow(candidate, requiredWords)) {
        continue;
      }

      // Group 1 captures the token span for Unicode whole-word scans. Only a zero-width lookahead
      // follows it, so the token start is recovered from the two match lengths.
      final start = _hasTokenSpanGroup
          ? candidate.start + candidate.group(0)!.length - candidate.group(1)!.length
          : candidate.start;
      if (_hasTokenSpanGroup && _isInsideWord(text, start)) continue;

      yield (start: start, end: candidate.end);
    }
  }
}

/// Whether [candidate] contains every required proximity word.
bool _hasAllWordsInWindow(final RegExpMatch candidate, final List<RegExp> requiredWords) {
  final window = candidate.group(0)!;
  for (final word in requiredWords) {
    if (!word.hasMatch(window)) return false;
  }

  return true;
}

/// A single Unicode word character, anchored.
final RegExp _wordChar = RegExp(r'^[\p{L}\p{N}_]$', unicode: true);

/// Whether a token at [index] starts inside a longer Unicode word.
bool _isInsideWord(final String text, final int index) {
  if (index == 0) return false;

  final unit = text.codeUnitAt(index - 1);
  if (unit < 0x80) {
    // ASCII fast path: `_`, digits, A-Z, a-z.
    return unit == 0x5F ||
        (unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x41 && unit <= 0x5A) ||
        (unit >= 0x61 && unit <= 0x7A);
  }

  var from = index - 1;
  if (unit >= 0xDC00 && unit <= 0xDFFF && from > 0) {
    // A low surrogate may be the back half of an astral character; test the complete pair.
    from -= 1;
  }
  return _wordChar.hasMatch(text.substring(from, index));
}
