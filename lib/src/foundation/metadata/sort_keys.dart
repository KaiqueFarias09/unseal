/// Sort-key algorithms for metadata fields that do not include explicit sort values.
///
/// These functions implement the established `title_sort`, `author_to_author_sort`, and
/// `remove_bracketed_text` behavior. The implementation preserves byte-for-byte compatibility with
/// existing computed keys.
///
/// When a book file omits a sort key, read `BookMetadata.titleSort`/`authorSort` first and fall
/// back to these functions. The `effectiveTitleSort`/`effectiveAuthorSort` getters apply that
/// fallback.
library;

const _authorNameCopywords = {
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

const _authorNamePrefixes = {'Mr', 'Mrs', 'Ms', 'Dr', 'Prof'};

const _authorNameSuffixes = {
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

const _authorSurnamePrefixes = {'da', 'de', 'di', 'la', 'le', 'van', 'von'};

/// Leading articles grouped by language for title sorting.
const Map<String, List<String>> _titleSortArticles = {
  'eng': [r'A\s+', r'The\s+', r'An\s+'],
  'epo': [r'La\s+', r"L'", 'L´'],
  'spa': [
    r'El\s+',
    r'La\s+',
    r'Lo\s+',
    r'Los\s+',
    r'Las\s+',
    r'Un\s+',
    r'Una\s+',
    r'Unos\s+',
    r'Unas\s+',
  ],
  'fra': [
    r'Le\s+',
    r'La\s+',
    r"L'",
    r'L´',
    r'L’',
    r'Les\s+',
    r'Un\s+',
    r'Une\s+',
    r'Des\s+',
    r'De\s+(La\s+)?',
    r"D'",
    r'D´',
    r'D’',
  ],
  'pol': [],
  'ita': [
    r'Lo\s+',
    r'Il\s+',
    r"L'",
    r'L´',
    r'La\s+',
    r'Gli\s+',
    r'I\s+',
    r'Le\s+',
    r'Uno\s+',
    r'Un\s+',
    r'Una\s+',
    r"Un'",
    r'Un´',
    r'Dei\s+',
    r'Degli\s+',
    r'Delle\s+',
    r'Del\s+',
    r'Della\s+',
    r'Dello\s+',
    r"Dell'",
    r'Dell´',
  ],
  'por': [r'A\s+', r'O\s+', r'Os\s+', r'As\s+', r'Um\s+', r'Uns\s+', r'Uma\s+', r'Umas\s+'],
  'ron': [r'Un\s+', r'O\s+', r'Nişte\s+'],
  'deu': [
    r'Der\s+',
    r'Die\s+',
    r'Das\s+',
    r'Den\s+',
    r'Ein\s+',
    r'Eine\s+',
    r'Einen\s+',
    r'Dem\s+',
    r'Des\s+',
    r'Einem\s+',
    r'Eines\s+',
  ],
  'nld': [
    r'De\s+',
    r'Het\s+',
    r'Een\s+',
    r"'n\s+",
    r"'s\s+",
    r'Ene\s+',
    r'Ener\s+',
    r'Enes\s+',
    r'Den\s+',
    r'Der\s+',
    r'Des\s+',
    r"'t\s+",
  ],
  'swe': [r'En\s+', r'Ett\s+', r'Det\s+', r'Den\s+', r'De\s+'],
  'tur': [r'Bir\s+'],
  'afr': [r"'n\s+", r'Die\s+'],
  'ell': [
    r'O\s+',
    r'I\s+',
    r'To\s+',
    r'Ta\s+',
    r'Tus\s+',
    r'Tis\s+',
    r"'Enas\s+",
    r"'Mia\s+",
    r"'Ena\s+",
    r"'Enan\s+",
  ],
  'hun': [r'A\s+', r'Az\s+', r'Egy\s+'],
};

/// Two-letter aliases for [_titleSortArticles] keys.
const _languageAliases = {
  'en': 'eng',
  'eo': 'epo',
  'es': 'spa',
  'fr': 'fra',
  'pl': 'pol',
  'it': 'ita',
  'pt': 'por',
  'ro': 'ron',
  'de': 'deu',
  'nl': 'nld',
  'sv': 'swe',
  'tr': 'tur',
  'af': 'afr',
  'el': 'ell',
  'hu': 'hun',
};

/// Cached compiled title-article patterns by canonical language.
final Map<String, RegExp> _articlePatterns = {};

/// Quote pairs removed before title article sorting.
const _quotePairs = {
  '"': ['"'],
  "'": ["'"],
  '“': ['”', '“'],
  '”': ['”', '“'],
  '„': ['”', '“'],
  '‚': ['’', '‘'],
  '’': ['’', '‘'],
  '‘': ['’', '‘'],
  '‹': ['›'],
  '›': ['‹'],
  '《': ['》'],
  '〈': ['〉'],
  '»': ['«', '»'],
  '«': ['«', '»'],
  '「': ['」'],
  '『': ['』'],
};

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
  if (author == null || author.isEmpty) return '';
  if (method == AuthorSortMethod.copy) return author;

  final sauthor = removeBracketedText(author).trim();
  if (method == AuthorSortMethod.comma && sauthor.contains(',')) return author;

  final tokens = sauthor.split(RegExp(r'\s+')).where((final token) => token.isNotEmpty).toList();
  if (tokens.length < 2) return author;

  final lowerTokens = tokens.map((final token) => token.toLowerCase()).toSet();
  final effectiveCopywords = (copywords ?? _authorNameCopywords)
      .map((final word) => word.toLowerCase())
      .toSet();
  if (lowerTokens.intersection(effectiveCopywords).isNotEmpty) return author;

  final effectiveSurnamePrefixes = (surnamePrefixes ?? _authorSurnamePrefixes)
      .map((final word) => word.toLowerCase())
      .toSet();
  if (useSurnamePrefixes &&
      tokens.length == 2 &&
      effectiveSurnamePrefixes.contains(tokens.first.toLowerCase())) {
    return author;
  }

  final effectiveNamePrefixes = _withDotted((namePrefixes ?? _authorNamePrefixes));
  var first = -1;

  for (var i = 0; i < tokens.length; i++) {
    if (!effectiveNamePrefixes.contains(tokens[i].toLowerCase())) {
      first = i;

      break;
    }
  }
  if (first == -1) return author;

  final effectiveNameSuffixes = _withDotted((nameSuffixes ?? _authorNameSuffixes));
  var last = -1;

  for (var i = tokens.length - 1; i >= first; i--) {
    if (!effectiveNameSuffixes.contains(tokens[i].toLowerCase())) {
      last = i;

      break;
    }
  }
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
      .map(
        (final author) => authorToAuthorSort(
          author,
          method: method,
          copywords: copywords,
          useSurnamePrefixes: useSurnamePrefixes,
          surnamePrefixes: surnamePrefixes,
          namePrefixes: namePrefixes,
          nameSuffixes: nameSuffixes,
        ),
      )
      .join(' & ');
}

/// The leading-article pattern for [lang] (e.g. `en`, `pt-BR`, `deu`), falling back to English
/// articles for unknown languages.
RegExp _articlePatternFor(final String? lang) {
  final key = _canonicalLanguage(lang) ?? 'eng';
  return _articlePatterns.putIfAbsent(key, () {
    final articles = _titleSortArticles[key] ?? _titleSortArticles['eng']!;
    if (articles.isEmpty) return RegExp(r'^$');

    return RegExp('^(${articles.join('|')})', caseSensitive: false);
  });
}

String? _canonicalLanguage(final String? lang) {
  if (lang == null || lang.isEmpty) return null;

  final lowered = lang.toLowerCase();
  if (_titleSortArticles.containsKey(lowered)) return lowered;

  final alias = _languageAliases[lowered];
  if (alias != null) return alias;

  for (final entry in _languageAliases.entries) {
    if (lowered.startsWith(entry.key)) return entry.value;
  }

  return null;
}

String _stripMatchingQuote(final String title) {
  if (title.isEmpty || !_quotePairs.containsKey(title[0])) return title;

  final closing = _quotePairs[title[0]]!;

  var result = title.substring(1);
  if (result.isNotEmpty && closing.contains(result[result.length - 1])) {
    result = result.substring(0, result.length - 1);
  }

  return result;
}

/// Computes the sortable form of a [title], moving a leading article to the end (`The Lord of the
/// Rings` → `Lord of the Rings, The`).
///
/// Applies the established title-sort rules. [lang] selects the article list (e.g. `en`, `pt-BR`,
/// `deu`); unknown languages use the English article list.
String titleSort(final String title, {final String? lang}) {
  var result = title.trim();
  result = _stripMatchingQuote(result);

  final match = _articlePatternFor(lang).firstMatch(result);
  if (match == null) return result.trim();

  final prep = match.group(1)!;
  if (prep.isNotEmpty) {
    result = '${result.substring(prep.length)}, $prep';
    result = _stripMatchingQuote(result);
  }

  return result.trim();
}

Set<String> _withDotted(final Set<String> words) {
  return {
    for (final word in words) ...<String>{word.toLowerCase(), '${word.toLowerCase()}.'},
  };
}
