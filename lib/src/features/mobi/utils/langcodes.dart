/// Palm MOBI main language ids mapped to ISO 639-1 codes.
const Map<int, String> mobiLanguageCodes = <int, String>{
  0: '', // neutral
  54: 'af', 28: 'sq', 1: 'ar', 43: 'hy', 77: 'as', 44: 'az',
  45: 'eu', 35: 'be', 69: 'bn', 2: 'bg', 3: 'ca', 4: 'zh',
  5: 'cs', 6: 'da', 19: 'nl', 9: 'en', 37: 'et', 56: 'fo',
  41: 'fa', 11: 'fi', 12: 'fr', 55: 'ka', 7: 'de', 8: 'el',
  71: 'gu', 13: 'he', 57: 'hi', 14: 'hu', 15: 'is', 33: 'id',
  16: 'it', 17: 'ja', 75: 'kn', 63: 'kk', 87: 'kok', 18: 'ko',
  38: 'lv', 39: 'lt', 47: 'mk', 62: 'ms', 76: 'ml', 58: 'mt',
  78: 'mr', 97: 'ne', 20: 'no', 72: 'or', 21: 'pl', 22: 'pt',
  70: 'pa', 23: 'rm', 24: 'ro', 25: 'ru', 59: 'se', 79: 'sa',
  26: 'sr', 27: 'sk', 36: 'sl', 46: 'wen', 48: 'st', 65: 'sw',
  29: 'sv', 73: 'ta', 68: 'tt', 74: 'te', 30: 'th', 49: 'ts',
  50: 'tn', 31: 'tr', 51: 'uk', 52: 'ur', 32: 'wen', 34: 'vi',
  53: 'cy', 85: 'xh', 42: 'ii', 61: 'yi', 86: 'zu',
  66: 'so', 67: 'swb', 60: 'ga', 40: 'wen', 10: 'es',
  64: 'my', 81: 'tl', 82: 'tzm', 83: 'uga', 84: 'de',
  88: 'mis', 89: 'sg', 90: 'wen', 91: 'wen', 92: 'wen',
  93: 'wen', 94: 'wen', 95: 'wen', 96: 'wen', 98: 'wen',
};

/// Resolves a MOBI locale word (langid in the low byte, sublang in
/// bits 10+) into an ISO language code with region when relevant
/// (e.g. `pt-BR`).
String resolveMobiLanguage(final int langCode) {
  final langId = langCode & 0xFF;
  final subLangId = (langCode >> 10) & 0xFF;
  final language = mobiLanguageCodes[langId] ?? '';
  if (language.isEmpty) return '';
  if (language == 'pt' && subLangId == 0x02) return 'pt-BR';
  if (language == 'en' && subLangId == 0x03) return 'en-GB';
  if (language == 'zh' && subLangId == 0x03) return 'zh-HK';

  return language;
}
