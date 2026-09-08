/// How a search query is interpreted.
enum SearchMode {
  /// Lenient substring match (default): invisible typesetting characters (soft hyphens, zero-width
  /// spaces) are tolerated between query characters, whitespace runs match any whitespace run, and
  /// straight quotes match curly ones.
  contains,

  /// Every whitespace-separated token must occur as a whole word; tokens keep the
  /// [SearchMode.contains] leniency and are joined by whitespace runs. Word boundaries are
  /// Unicode-aware: a word character is any letter (`\p{L}`), number (`\p{N}`) or underscore. This
  /// keeps whole-word matching correct for non-ASCII text, including Cyrillic, Arabic, Greek, CJK,
  /// and accented Latin.
  wholeWords,

  /// The query is a regular expression, always multiline (ECMAScript/Dart syntax). Invalid patterns
  /// throw [FormatException].
  regex,

  /// Proximity search: whitespace-separated words must occur in the given order, each word starting
  /// within `nearChars` characters of the previous one. A trailing all-digits token in the query
  /// overrides the interval (`alpha beta 120` searches within 120 characters). Words are matched
  /// with the same Unicode whole-word boundaries as [SearchMode.wholeWords].
  proximity,
}
