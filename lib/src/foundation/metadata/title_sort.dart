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

/// Computes the sort key for a [title].
///
/// A leading article moves to the end: `The Lord of the Rings` becomes `Lord of the Rings, The`.
///
/// [language] selects the article list (for example `en`, `pt-BR`, or `deu`); unknown languages use
/// the English article list.
String computeTitleSortKey(final String title, {final String? language}) {
  var result = _stripMatchingQuote(title.trim());
  final match = _articlePatternFor(language).firstMatch(result);
  if (match == null) return result.trim();

  final prep = match.group(1)!;
  if (prep.isNotEmpty) {
    result = '${result.substring(prep.length)}, $prep';
    result = _stripMatchingQuote(result);
  }

  return result.trim();
}

RegExp _articlePatternFor(final String? language) {
  final key = _canonicalLanguage(language) ?? 'eng';
  return _articlePatterns.putIfAbsent(key, () {
    final articles = _titleSortArticles[key] ?? _titleSortArticles['eng']!;
    if (articles.isEmpty) return RegExp(r'^$');

    return RegExp('^(${articles.join('|')})', caseSensitive: false);
  });
}

String? _canonicalLanguage(final String? language) {
  if (language == null || language.isEmpty) return null;

  final lowered = language.toLowerCase();
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
