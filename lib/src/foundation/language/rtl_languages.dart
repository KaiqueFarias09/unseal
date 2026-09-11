/// The set of right-to-left primary languages, used to infer the page flow of a book that does not
/// declare one.
library;

/// The ISO 639-2/3 codes recognized as right-to-left: Aramaic, Arabic, Azeri, Hebrew, Dhivehi,
/// Sorani (Central Kurdish), Syriac, Mandaic, Urdu and Farsi.
const _rtlIsoCodes = <String>{'ara', 'heb', 'aze', 'div', 'arc', 'syc', 'myz', 'ckb', 'urd', 'fas'};

/// The ISO 639-1 two-letter forms that canonicalize into the RTL set above (`ar` -> `ara`, `he` ->
/// `heb`, ...). The other RTL codes have no two-letter form.
const _rtlTwoLetterAliases = <String, String>{
  'ar': 'ara',
  'he': 'heb',
  'az': 'aze',
  'dv': 'div',
  'ur': 'urd',
  'fa': 'fas',
};

/// Whether [language] identifies a right-to-left language.
///
/// The tag is canonicalized first: lowercased, trimmed, `_` read as `-`, and the region/script
/// subtags dropped (`pt-BR` -> `pt`, 'AR' -> 'ar'). Both two-letter (`ar`) and three-letter (`ara`)
/// primary tags are recognized. Null, empty, and non-RTL tags return false.
bool isRtlLanguage(final String? language) {
  if (language == null) return false;

  final raw = language.trim().toLowerCase().replaceAll('_', '-');
  if (raw.isEmpty) return false;

  final primary = raw.split('-').first.trim();
  if (primary.isEmpty) return false;
  if (primary.length == 2) return _rtlTwoLetterAliases.containsKey(primary);

  return _rtlIsoCodes.contains(primary);
}
