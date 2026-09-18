/// Author sort-key algorithms for metadata fields that do not include explicit sort values.
///
/// These functions implement the established `author_to_author_sort` and `remove_bracketed_text`
/// behavior. The implementation preserves byte-for-byte compatibility with existing computed keys.
///
/// When a book file omits an author sort key, read `BookMetadata.authorSort` first and fall back to
/// these functions. The `effectiveAuthorSort` getter applies that fallback.
library;

/// Determines how a missing author sort key is derived from an author name.
///
/// The default matches the library's surname-first sort behavior.
enum AuthorSortMethod {
  /// Moves the surname before the given name: `Surname, Given`.
  invert,

  /// Keeps the author name unchanged.
  copy,

  /// Uses [invert] unless the name already contains a comma.
  comma,

  /// Moves the surname before the given name without a comma: `Surname Given`.
  nocomma,
}

/// Removes balanced `(...)`, `[...]` and `{...}` spans from [source].
///
/// Unbalanced closers are dropped, and an unclosed opener consumes the rest. This matches the
/// established bracket-removal behavior.
String removeBracketedText(final String source) {
  const brackets = {'(': ')', '[': ']', '{': '}'};
  final closerToOpener = {for (final entry in brackets.entries) entry.value: entry.key};
  final counts = <String, int>{};
  var total = 0;
  final buf = StringBuffer();
  for (final rune in source.runes) {
    final char = String.fromCharCode(rune);
    if (brackets.containsKey(char)) {
      counts[char] = (counts[char] ?? 0) + 1;
      total++;
    } else if (closerToOpener.containsKey(char)) {
      final opener = closerToOpener[char]!;
      if ((counts[opener] ?? 0) > 0) {
        counts[opener] = counts[opener]! - 1;
        total--;
      }
    } else if (total < 1) {
      buf.write(char);
    }
  }

  return buf.toString();
}

/// Derives the sort form of one author name (`Last, First` style).
///
/// Applies the established author-sort rules for name prefixes, Roman-numeral and honorific
/// suffixes, and corporate copywords. A null or empty input yields the empty string; names that
/// cannot be rearranged are returned unchanged.
String authorToAuthorSort(
  final String? author, {
  final AuthorSortMethod method = AuthorSortMethod.comma,
  final Set<String>? copywords,
  final bool useSurnamePrefixes = false,
  final Set<String>? surnamePrefixes,
  final Set<String>? namePrefixes,
  final Set<String>? nameSuffixes,
}) {
  const authorNameCopywords = {
    'Agency',
    'Corporation',
    'Company',
    'Co.',
    'Council',
    'Committee',
    'Inc.',
    'Institute',
    'National',
    'Society',
    'Club',
    'Team',
    'Software',
    'Games',
    'Entertainment',
    'Media',
    'Studios',
  };
  const authorNameSuffixes = {
    'Jr',
    'Sr',
    'Inc',
    'Ph.D',
    'Phd',
    'MD',
    'M.D',
    'I',
    'II',
    'III',
    'IV',
    'Junior',
    'Senior',
  };

  const authorNamePrefixes = {'Mr', 'Mrs', 'Ms', 'Dr', 'Prof'};
  const authorSurnamePrefixes = {'da', 'de', 'di', 'la', 'le', 'van', 'von'};

  if (author == null || author.isEmpty) return '';
  if (method == AuthorSortMethod.copy) return author;

  final sauthor = removeBracketedText(author).trim();
  if (method == AuthorSortMethod.comma && sauthor.contains(',')) return author;

  final tokens = sauthor.split(RegExp(r'\s+')).where((final token) => token.isNotEmpty).toList();
  if (tokens.length < 2) return author;

  final lowerTokens = tokens.map((final token) => token.toLowerCase()).toSet();
  final effectiveCopywords = (copywords ?? authorNameCopywords)
      .map((final word) => word.toLowerCase())
      .toSet();
  if (lowerTokens.intersection(effectiveCopywords).isNotEmpty) return author;

  final effectiveSurnamePrefixes = (surnamePrefixes ?? authorSurnamePrefixes)
      .map((final word) => word.toLowerCase())
      .toSet();
  if (useSurnamePrefixes &&
      tokens.length == 2 &&
      effectiveSurnamePrefixes.contains(tokens.first.toLowerCase())) {
    return author;
  }

  final effectiveNamePrefixes = _withDotted((namePrefixes ?? authorNamePrefixes));
  final first = _firstNonMatchingToken(tokens, effectiveNamePrefixes);
  if (first == -1) return author;

  final effectiveNameSuffixes = _withDotted((nameSuffixes ?? authorNameSuffixes));
  var last = _lastNonMatchingToken(tokens, first, effectiveNameSuffixes);
  if (last == -1) return author;

  final suffix = tokens.sublist(last + 1).join(' ');
  if (useSurnamePrefixes &&
      last > first &&
      effectiveSurnamePrefixes.contains(tokens[last - 1].toLowerCase())) {
    tokens[last - 1] = '${tokens[last - 1]} ${tokens[last]}';
    last--;
  }
  final sortTokens = <String>[...tokens.sublist(last, last + 1), ...tokens.sublist(first, last)];
  final numToks = sortTokens.length;
  if (suffix.isNotEmpty) sortTokens.add(suffix);
  if (method != AuthorSortMethod.nocomma && numToks > 1) sortTokens[0] = '${sortTokens[0]},';

  return sortTokens.join(' ');
}

/// Derives the sort string for a list of authors, joined with ` & `.
///
/// Applies the established author-sort rules to each name and joins the results with ` & `.
String authorsToSortString(
  final Iterable<String?> authors, {
  final AuthorSortMethod method = AuthorSortMethod.comma,
  final Set<String>? copywords,
  final bool useSurnamePrefixes = false,
  final Set<String>? surnamePrefixes,
  final Set<String>? namePrefixes,
  final Set<String>? nameSuffixes,
}) {
  return authors
      .map((final author) {
        return authorToAuthorSort(
          author,
          method: method,
          copywords: copywords,
          useSurnamePrefixes: useSurnamePrefixes,
          surnamePrefixes: surnamePrefixes,
          namePrefixes: namePrefixes,
          nameSuffixes: nameSuffixes,
        );
      })
      .join(' & ');
}

int _firstNonMatchingToken(final List<String> tokens, final Set<String> ignored) {
  for (var i = 0; i < tokens.length; i++) {
    if (!ignored.contains(tokens[i].toLowerCase())) return i;
  }

  return -1;
}

int _lastNonMatchingToken(final List<String> tokens, final int first, final Set<String> ignored) {
  for (var i = tokens.length - 1; i >= first; i--) {
    if (!ignored.contains(tokens[i].toLowerCase())) return i;
  }

  return -1;
}

Set<String> _withDotted(final Set<String> words) {
  return {
    for (final word in words) ...<String>{word.toLowerCase(), '${word.toLowerCase()}.'},
  };
}
