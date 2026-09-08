part of 'book_search.dart';

/// Whether a token starting at [index] in [text] sits inside a longer word — that is, whether the
/// character before [index] is a Unicode word character. This is the per-candidate image of a
/// consumed boundary-behind prefix (`(?:^|$_nonWordChar)`), evaluated in Dart rather than in the
/// scan pattern so the `\p{...}` classes never take part in the per-position scan (see
/// [_CompiledQuery]).
bool _isInsideWord(final String text, final int index) {
  if (index == 0) return false;

  final unit = text.codeUnitAt(index - 1);
  var isWordCharacter = false;

  if (unit < 0x80) {
    // ASCII fast path: `_`, digits, A-Z, a-z.
    isWordCharacter =
        unit == 0x5F ||
        (unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x41 && unit <= 0x5A) ||
        (unit >= 0x61 && unit <= 0x7A);
  } else {
    var from = index - 1;
    if (unit >= 0xDC00 && unit <= 0xDFFF && from > 0) {
      // A low surrogate may be the back half of an astral (surrogate pair) character; test the
      // whole pair as one code point.
      from -= 1;
    }
    isWordCharacter = _wordChar.hasMatch(text.substring(from, index));
  }

  return isWordCharacter;
}

_CompiledQuery _compile(
  final String trimmed, {
  required final SearchMode mode,
  required final bool isCaseSensitive,
  required final bool isTolerant,
  required final int nearChars,
}) {
  switch (mode) {
    case SearchMode.contains:
      return _CompiledQuery(
        RegExp(_tokenPattern(trimmed, isTolerant: isTolerant), caseSensitive: isCaseSensitive),
        null,
      );
    case SearchMode.wholeWords:
      // Whole-word matching wraps the complete token phrase in Unicode word boundaries. The
      // zero-width non-word lookahead behind the phrase stays in the pattern, while the
      // boundary-behind is verified per candidate with [_isInsideWord]. A look-behind is no option
      // — dart2js support for it is browser-dependent — and a consumed-prefix class in the scan
      // path makes matching an order of magnitude slower. Interior tokens need no boundaries of
      // their own: the whitespace runs joining them are non-word characters on both sides.
      final tokens = trimmed.split(RegExp(r'\s+'))..removeWhere((final token) => token.isEmpty);
      final phrase = tokens
          .map((final token) => _tokenPattern(token, isTolerant: isTolerant))
          .join(r'\s+');

      return _CompiledQuery(
        RegExp('($phrase)$_wordBoundaryAhead', caseSensitive: isCaseSensitive, unicode: true),
        null,
        hasTokenSpanGroup: true,
      );
    case SearchMode.regex:
      // Regular expressions are interpreted verbatim and always run in multiline mode.
      return _CompiledQuery(RegExp(trimmed, multiLine: true, caseSensitive: isCaseSensitive), null);
    case SearchMode.proximity:
      final near = _nearWordsAndInterval(trimmed, defaultInterval: nearChars);
      if (near.words.length < 2) {
        throw const FormatException(
          'A proximity search needs at least two words; optionally '
          'follow them with a number of characters.',
        );
      }
      // Proximity matching uses a two-phase structure: an any-word candidate window joined by gaps,
      // then every word is verified inside the window. Gaps use Unicode word boundaries: gaps whose
      // first and last characters are non-word (the image of the old `\b` + `.{1,N}` + `\b` trio,
      // consuming what the zero-width boundaries checked), a zero-width non-word lookahead behind
      // the window's last word, and the window's leading boundary verified per candidate with
      // [_isInsideWord] (dotAll preserved).
      final alternation = near.words
          .map((final word) => '(?:${_tokenPattern(word, isTolerant: isTolerant)})')
          .join('|');
      final candidate = RegExp(
        '(${List.filled(near.words.length, '(?:$alternation)').join(_proximityGap(near.interval))})'
        '$_wordBoundaryAhead',
        dotAll: true,
        caseSensitive: isCaseSensitive,
        unicode: true,
      );
      final words = <RegExp>[
        for (final word in near.words)
          RegExp(
            '$_wordBoundaryBehind(${_tokenPattern(word, isTolerant: isTolerant)})$_wordBoundaryAhead',
            caseSensitive: isCaseSensitive,
            unicode: true,
          ),
      ];

      return _CompiledQuery(candidate, words, hasTokenSpanGroup: true);
  }
}

/// The consumed gap between two proximity words: 1..[interval] characters whose first and last are
/// not word characters — the consumed image of the previous `\b` + `.{1,interval}` + `\b` trio,
/// where the boundaries were zero-width.
String _proximityGap(final int interval) {
  if (interval <= 1) return _nonWordChar;

  return '$_nonWordChar(?:.{0,${interval - 2}}$_nonWordChar)?';
}

/// Parses a proximity query: a trailing all-digits token is the interval in characters, and the
/// remaining tokens are words.
({List<String> words, int interval}) _nearWordsAndInterval(
  final String expr, {
  required final int defaultInterval,
}) {
  final parts = expr.trim().split(RegExp(r'\s+'))..removeWhere((final part) => part.isEmpty);
  var interval = defaultInterval;

  if (parts.length > 1 && RegExp(r'^\d+$').hasMatch(parts.last)) {
    interval = int.tryParse(parts.removeLast()) ?? defaultInterval;
  }

  return (words: parts, interval: interval < 1 ? 1 : interval);
}

/// Whether [candidate] contains a match of every [requiredWords]. The two-phase check keeps windows
/// valid when the any-word alternation repeats a word. The word patterns themselves use the same
/// Unicode boundaries as whole-word mode.
bool _hasAllWordsInWindow(final RegExpMatch candidate, final List<RegExp> requiredWords) {
  final window = candidate.group(0)!;
  for (final word in requiredWords) {
    if (!word.hasMatch(window)) return false;
  }

  return true;
}

/// Builds the match pattern for one query token: each whitespace run in the token matches any
/// whitespace run in the text, straight quotes match curly ones, and (when [isTolerant]) invisible
/// separators may sit between characters. With [isTolerant] off the token is a plain escaped
/// literal.
String _tokenPattern(final String token, {required final bool isTolerant}) {
  if (!isTolerant) return RegExp.escape(token);

  final buffer = StringBuffer();
  const invisibleSeparators = r'[\u00AD\u200B\u200C\u200D]?';
  var wasPreviousWhitespace = false;

  for (final rune in token.runes) {
    final char = String.fromCharCode(rune);
    final isWhitespace = RegExp(r'\s').hasMatch(char);

    // collapse the whitespace run into one `\s+`
    if (isWhitespace && wasPreviousWhitespace) continue;

    if (buffer.isNotEmpty) buffer.write(invisibleSeparators);
    if (isWhitespace) {
      buffer.write(r'\s+');
    } else if (char == '"') {
      buffer.write('["“”]');
    } else if (char == "'") {
      buffer.write("['‘’]");
    } else {
      buffer.write(RegExp.escape(char));
    }
    wasPreviousWhitespace = isWhitespace;
  }
  if (buffer.isEmpty) {
    buffer.write(RegExp.escape(token));
  }

  return buffer.toString();
}
