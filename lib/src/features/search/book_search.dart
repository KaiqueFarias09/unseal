import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/features/text/document_text.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';

/// How a search query is interpreted.
enum SearchMode {
  /// Lenient substring match (default): invisible typesetting
  /// characters (soft hyphens, zero-width spaces) are tolerated
  /// between query characters, whitespace runs match any whitespace
  /// run, and straight quotes match curly ones. Calibre's reader
  /// parity.
  contains,

  /// Every whitespace-separated token must occur as a whole word;
  /// tokens keep the [SearchMode.contains] leniency and are joined by
  /// whitespace runs. Word boundaries are Unicode-aware: a word
  /// character is any letter (`\p{L}`), number (`\p{N}`) or
  /// underscore — the `\w` class of the Python `re` module that
  /// Calibre's legacy viewer effectively used for whole-word search
  /// (the same legacy viewer this mode's design follows).
  ///
  /// This is a deliberate, documented divergence from Calibre's
  /// current browser viewer, whose ASCII ECMAScript `\b` finds zero
  /// matches for words whose first or last letter is non-ASCII
  /// (Cyrillic, Arabic, Greek, CJK, accented Latin, …). The legacy
  /// viewer and Calibre's DB full-text search were Unicode-aware;
  /// e_livre follows them, not the current viewer's regression.
  wholeWords,

  /// The query is a regular expression, always multiline
  /// (ECMAScript/Dart syntax). Invalid patterns throw
  /// [FormatException].
  regex,

  /// Proximity search, Calibre's "near": whitespace-separated words
  /// must occur in the given order, each word starting within
  /// `nearChars` characters of the previous one. A trailing
  /// all-digits token in the query overrides the interval
  /// (`alpha beta 120` searches within 120 characters). Words are
  /// matched with the same Unicode whole-word boundaries as
  /// [SearchMode.wholeWords] — a deliberate divergence from the ASCII
  /// `\b` of Calibre's current viewer (see [SearchMode.wholeWords]).
  proximity,
}

/// One hit of a full-text search over a book's content.
final class SearchMatch {
  /// Creates a [SearchMatch].
  const SearchMatch({
    required this.sectionIndex,
    required this.sectionName,
    required this.start,
    required this.end,
    required this.snippet,
  });

  /// Index of the content section inside the book's reading order.
  final int sectionIndex;

  /// Path of the content file holding the match.
  final String sectionName;

  /// Start offset of the match within the section's document text.
  final int start;

  /// End offset (exclusive) of the match within the section's
  /// document text.
  final int end;

  /// The surrounding text, with `…` markers where context was cut.
  final String snippet;

  @override
  String toString() => 'SearchMatch(section: $sectionIndex, $start..$end, snippet: $snippet)';
}

/// The result of a full-text search over a [Book].
final class SearchResults {
  /// Creates [SearchResults].
  const SearchResults({required this.query, required this.matches, required this.truncated});

  /// The search query.
  final String query;

  /// The matches, in reading order.
  final List<SearchMatch> matches;

  /// Whether [matches] was cut short by `maxMatches`.
  final bool truncated;

  @override
  String toString() =>
      'SearchResults(query: $query, matches: ${matches.length}, truncated: $truncated)';
}

/// Full-text search over a book's plain text.
///
/// Finds every occurrence of the query across the book's HTML
/// sections (in reading order). Matching is case-insensitive by
/// default and, in the tolerant mode, ignores soft hyphens and
/// zero-width characters and collapses whitespace runs — the same
/// leniency Calibre's reader applies. Match offsets address the
/// `documentText` space of each section, so a hit can be highlighted
/// in a rendered page or turned into a reading position.
extension BookSearch on Book {
  /// Searches the book's document text for [query].
  ///
  /// [mode] selects how [query] is interpreted (see [SearchMode]).
  /// [caseSensitive] disables case folding on every mode. [tolerant]
  /// enables the hyphenation/whitespace leniency on the non-regex
  /// modes (disable for exact matching). [nearChars] is the
  /// proximity interval used when the query carries no trailing
  /// number. [contextChars] controls how much surrounding text each
  /// snippet carries on either side; [maxMatches] caps the result
  /// size.
  ///
  /// Throws [FormatException] for an invalid [SearchMode.regex]
  /// pattern or a [SearchMode.proximity] query with fewer than two
  /// words.
  SearchResults search(
    final String query, {
    final SearchMode mode = SearchMode.contains,
    final bool caseSensitive = false,
    final bool tolerant = true,
    final int nearChars = _defaultNearChars,
    final int contextChars = 48,
    final int maxMatches = 200,
  }) {
    final results = <SearchMatch>[];
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return SearchResults(query: query, matches: results, truncated: false);
    }

    final compiled = _compile(
      trimmed,
      mode: mode,
      caseSensitive: caseSensitive,
      tolerant: tolerant,
      nearChars: nearChars,
    );

    final htmlByPath = <String, TextFile>{for (final file in files.html) file.path: file};
    final sections = readingOrder;
    var truncated = false;
    for (var sectionIndex = 0; sectionIndex < sections.length; sectionIndex++) {
      final section = sections[sectionIndex];
      if (!section.isHtml) continue;

      final file = htmlByPath[section.name];
      if (file == null) continue;

      final text = documentTextOf(file);
      final requiredWords = compiled.requiredWords;
      for (final candidate in compiled.pattern.allMatches(text)) {
        if (requiredWords != null && !_windowHasAllWords(candidate, requiredWords)) {
          continue;
        }
        // The token span is group 1, the match's suffix (only a
        // zero-width lookahead follows it), so its start is recovered
        // from the two lengths.
        final start = compiled.tokenSpanGroup
            ? candidate.start + candidate.group(0)!.length - candidate.group(1)!.length
            : candidate.start;
        if (compiled.tokenSpanGroup && _insideWord(text, start)) {
          continue;
        }
        if (results.length >= maxMatches) {
          truncated = true;
          break;
        }
        results.add(
          SearchMatch(
            sectionIndex: sectionIndex,
            sectionName: section.name,
            start: start,
            end: candidate.end,
            snippet: _snippet(text, start, candidate.end, contextChars),
          ),
        );
      }
      if (truncated) break;
    }

    return SearchResults(query: query, matches: results, truncated: truncated);
  }

  /// Builds a context snippet around `[start, end)` with ellipses
  /// where the surrounding text was cut.
  static String _snippet(
    final String text,
    final int start,
    final int end,
    final int contextChars,
  ) {
    final from = (start - contextChars).clamp(0, text.length);
    final to = (end + contextChars).clamp(0, text.length);
    final prefix = from > 0 ? '…' : '';
    final suffix = to < text.length ? '…' : '';
    return '$prefix${text.substring(from, to)}$suffix';
  }
}

/// A compiled query: the candidate pattern plus, for proximity
/// searches, the word patterns every candidate window must contain.
final class _CompiledQuery {
  const _CompiledQuery(this.pattern, this.requiredWords, {this.tokenSpanGroup = false});

  final RegExp pattern;

  final List<RegExp>? requiredWords;

  /// Whether [pattern] is a Unicode whole-word scan: group 1 captures
  /// the token span of a match (the match's suffix — only a zero-width
  /// [_wordBoundaryAhead] follows it), so a [SearchMatch.start] is
  /// `match.start + match.group(0).length - match.group(1).length`,
  /// its end is `match.end`, and the boundary-behind is verified per
  /// candidate with [_insideWord] — kept out of the scan pattern
  /// because a `\p{...}` class in the per-position scan path makes
  /// the regex engine's automaton an order of magnitude slower.
  final bool tokenSpanGroup;
}

/// Default proximity interval in characters. Parity: Calibre
/// `words_and_interval_for_near(default_interval=60)`.
const int _defaultNearChars = 60;

/// Optional separators between query characters: soft hyphens and
/// zero-width characters inserted by typesetting.
const String _invisibleSeparators = r'[\u00AD\u200B\u200C\u200D]?';

/// A character that is not a Unicode word character: anything outside
/// `\p{L}` (letters), `\p{N}` (numbers) and `_` — the negated image
/// of the Python `re` `\w` class (see [SearchMode.wholeWords]).
const String _nonWordChar = r'[^\p{L}\p{N}_]';

/// A single Unicode word character, anchored. Only ever run on the
/// one or two code units preceding a candidate match — never on the
/// scanned text (see [_insideWord]).
final RegExp _wordChar = RegExp(r'^[\p{L}\p{N}_]$', unicode: true);

/// Consumed boundary-behind prefix: string start or one non-word
/// character. Used where the scanned string is tiny (the proximity
/// required-word patterns run against the candidate window only); the
/// whole-text scan patterns use the per-candidate [_insideWord] check
/// instead (see [_CompiledQuery.tokenSpanGroup]).
const String _wordBoundaryBehind = '(?:^|$_nonWordChar)';

/// Zero-width boundary after a whole-word token: a non-word character
/// or the end of the text. Kept as a lookahead in the scan patterns —
/// it runs once per candidate, where a boundary-behind class would
/// run once per scanned position.
const String _wordBoundaryAhead = '(?=$_nonWordChar|\$)';

/// Whether a token starting at [index] in [text] sits inside a longer
/// word — i.e. whether the character before [index] is a Unicode word
/// character. This is the per-candidate image of a consumed
/// boundary-behind prefix (`(?:^|$_nonWordChar)`), evaluated in Dart
/// rather than in the scan pattern so the `\p{...}` classes never
/// take part in the per-position scan (see [_CompiledQuery]).
bool _insideWord(final String text, final int index) {
  if (index == 0) {
    return false;
  }
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
    // A low surrogate may be the back half of an astral (surrogate
    // pair) character; test the whole pair as one code point.
    from -= 1;
  }
  return _wordChar.hasMatch(text.substring(from, index));
}

_CompiledQuery _compile(
  final String trimmed, {
  required final SearchMode mode,
  required final bool caseSensitive,
  required final bool tolerant,
  required final int nearChars,
}) {
  switch (mode) {
    case SearchMode.contains:
      return _CompiledQuery(
        RegExp(_tokenPattern(trimmed, tolerant: tolerant), caseSensitive: caseSensitive),
        null,
      );
    case SearchMode.wholeWords:
      // Divergence from calibre pyj/read_book/search_worker.pyj:232-237:
      // the viewer splits on whitespace and wraps each token in ASCII
      // `\b`, which never matches words with non-ASCII edge letters.
      // e_livre instead wraps the whole token phrase in Unicode word
      // boundaries: the zero-width non-word lookahead behind the
      // phrase stays in the pattern, the boundary-behind is verified
      // per candidate with [_insideWord] (a look-behind is no option
      // — dart2js support for it is browser-dependent — and a
      // consumed-prefix class in the scan path makes matching an
      // order of magnitude slower). Interior tokens need no
      // boundaries of their own: the whitespace runs joining them are
      // non-word characters on both sides.
      final tokens = trimmed.split(RegExp(r'\s+'))..removeWhere((final token) => token.isEmpty);
      final phrase = tokens
          .map((final token) => _tokenPattern(token, tolerant: tolerant))
          .join(r'\s+');
      return _CompiledQuery(
        RegExp('($phrase)$_wordBoundaryAhead', caseSensitive: caseSensitive, unicode: true),
        null,
        tokenSpanGroup: true,
      );
    case SearchMode.regex:
      // Parity: calibre gui2/viewer/search.py:133-146 — verbatim
      // expression, always multiline.
      return _CompiledQuery(RegExp(trimmed, multiLine: true, caseSensitive: caseSensitive), null);
    case SearchMode.proximity:
      final near = _nearWordsAndInterval(trimmed, defaultInterval: nearChars);
      if (near.words.length < 2) {
        throw const FormatException(
          'A proximity search needs at least two words; optionally '
          'follow them with a number of characters.',
        );
      }
      // Divergence from calibre gui2/viewer/search.py:148-160 — the
      // same two-phase structure (an any-word candidate window joined
      // by gaps, then every word verified inside the window), but
      // with Unicode word boundaries instead of ASCII `\b`: gaps
      // whose first and last characters are non-word (the image of
      // the old `\b` + `.{1,N}` + `\b` trio, consuming what the
      // zero-width boundaries checked), a zero-width non-word
      // lookahead behind the window's last word, and the window's
      // leading boundary verified per candidate with [_insideWord]
      // (dotAll preserved).
      final alternation = near.words
          .map((final word) => '(?:${_tokenPattern(word, tolerant: tolerant)})')
          .join('|');
      final candidate = RegExp(
        '(${List.filled(near.words.length, '(?:$alternation)').join(_proximityGap(near.interval))})'
        '$_wordBoundaryAhead',
        dotAll: true,
        caseSensitive: caseSensitive,
        unicode: true,
      );
      final words = <RegExp>[
        for (final word in near.words)
          RegExp(
            '$_wordBoundaryBehind(${_tokenPattern(word, tolerant: tolerant)})$_wordBoundaryAhead',
            caseSensitive: caseSensitive,
            unicode: true,
          ),
      ];
      return _CompiledQuery(candidate, words, tokenSpanGroup: true);
  }
}

/// The consumed gap between two proximity words: 1..[interval]
/// characters whose first and last are not word characters — the
/// consumed image of the previous `\b` + `.{1,interval}` + `\b`
/// trio, where the boundaries were zero-width.
String _proximityGap(final int interval) {
  if (interval <= 1) {
    return _nonWordChar;
  }
  return '$_nonWordChar(?:.{0,${interval - 2}}$_nonWordChar)?';
}

/// Parses Calibre's near query: a trailing all-digits token is the
/// interval in characters, the rest are words.
/// Parity: calibre gui2/viewer/search.py:101-111.
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

/// Whether [candidate] contains a match of every [requiredWords].
/// Parity: calibre gui2/viewer/search.py:429-439 (the two-phase
/// check that keeps windows honest when the any-word alternation
/// repeats a word); the word patterns themselves are Unicode-boundary
/// wrapped like the whole-word mode.
bool _windowHasAllWords(final RegExpMatch candidate, final List<RegExp> requiredWords) {
  final window = candidate.group(0)!;
  for (final word in requiredWords) {
    if (!word.hasMatch(window)) {
      return false;
    }
  }
  return true;
}

/// Builds the match pattern for one query token: each whitespace run
/// in the token matches any whitespace run in the text, straight
/// quotes match curly ones, and (when [tolerant]) invisible
/// separators may sit between characters. With [tolerant] off the
/// token is a plain escaped literal. Parity: calibre `text_to_regex`
/// (search.py:68-98, search_worker.pyj:35-57).
String _tokenPattern(final String token, {required final bool tolerant}) {
  if (!tolerant) {
    return RegExp.escape(token);
  }
  final buffer = StringBuffer();
  var previousWasWhitespace = false;
  for (final rune in token.runes) {
    final char = String.fromCharCode(rune);
    final isWhitespace = RegExp(r'\s').hasMatch(char);
    if (isWhitespace && previousWasWhitespace) {
      continue; // collapse the whitespace run into one `\s+`
    }
    if (buffer.isNotEmpty) {
      buffer.write(_invisibleSeparators);
    }
    if (isWhitespace) {
      buffer.write(r'\s+');
    } else if (char == '"') {
      buffer.write('["“”]');
    } else if (char == "'") {
      buffer.write("['‘’]");
    } else {
      buffer.write(RegExp.escape(char));
    }
    previousWasWhitespace = isWhitespace;
  }
  if (buffer.isEmpty) {
    buffer.write(RegExp.escape(token));
  }
  return buffer.toString();
}
