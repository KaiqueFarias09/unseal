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
  /// whitespace runs. Word boundaries use ECMAScript `\b` semantics
  /// (like Calibre's browser viewer, not the Python `regex` module).
  wholeWords,

  /// The query is a regular expression, always multiline
  /// (ECMAScript/Dart syntax). Invalid patterns throw
  /// [FormatException].
  regex,

  /// Proximity search, Calibre's "near": whitespace-separated words
  /// must occur in the given order, each word starting within
  /// `nearChars` characters of the previous one. A trailing
  /// all-digits token in the query overrides the interval
  /// (`alpha beta 120` searches within 120 characters).
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

      final text = documentText(file.content);
      final requiredWords = compiled.requiredWords;
      for (final candidate in compiled.pattern.allMatches(text)) {
        if (requiredWords != null && !_windowHasAllWords(candidate, requiredWords)) {
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
            start: candidate.start,
            end: candidate.end,
            snippet: _snippet(text, candidate.start, candidate.end, contextChars),
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
  const _CompiledQuery(this.pattern, this.requiredWords);

  final RegExp pattern;
  final List<RegExp>? requiredWords;
}

/// Default proximity interval in characters. Parity: Calibre
/// `words_and_interval_for_near(default_interval=60)`.
const int _defaultNearChars = 60;

/// Optional separators between query characters: soft hyphens and
/// zero-width characters inserted by typesetting.
const String _invisibleSeparators = r'[\u00AD\u200B\u200C\u200D]?';

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
        _joinTokens([_tokenPattern(trimmed, tolerant: tolerant)], caseSensitive: caseSensitive),
        null,
      );
    case SearchMode.wholeWords:
      // Parity: calibre pyj/read_book/search_worker.pyj:232-237 —
      // split on whitespace, wrap each token in word boundaries,
      // join with whitespace runs.
      final tokens = trimmed.split(RegExp(r'\s+'))..removeWhere((final token) => token.isEmpty);
      return _CompiledQuery(
        _joinTokens([
          for (final token in tokens) r'\b' + _tokenPattern(token, tolerant: tolerant) + r'\b',
        ], caseSensitive: caseSensitive),
        null,
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
      // Parity: calibre gui2/viewer/search.py:148-160 — a candidate
      // window regex joins an any-word alternation with `.{1,N}`
      // (dotAll), then every word pattern is verified inside the
      // window, so all words occur in the given order within N
      // characters of each other.
      final alternation = near.words
          .map((final word) => r'\b' + _tokenPattern(word, tolerant: tolerant) + r'\b')
          .join('|');
      final joiner = '.{1,${near.interval}}';
      final candidate = RegExp(
        [for (var i = 0; i < near.words.length; i++) '(?:$alternation)'].join(joiner),
        dotAll: true,
        caseSensitive: caseSensitive,
      );
      final words = <RegExp>[
        for (final word in near.words)
          RegExp(
            r'\b' + _tokenPattern(word, tolerant: tolerant) + r'\b',
            caseSensitive: caseSensitive,
          ),
      ];
      return _CompiledQuery(candidate, words);
  }
}

RegExp _joinTokens(final List<String> tokens, {required final bool caseSensitive}) {
  return RegExp(tokens.join(r'\s+'), caseSensitive: caseSensitive);
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
/// repeats a word).
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
