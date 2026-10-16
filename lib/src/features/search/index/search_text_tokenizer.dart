/// Tokenizer of the per-publication search index.
///
/// One pass over a section's canonical text produces the index terms
/// together with their original UTF-16 ranges — the projection the
/// postings store, so every hit cuts the original text, not a
/// normalized copy.
///
/// The profile is self-contained (no ICU, no platform tables), so VM
/// and Chrome tokenize identically:
///
/// * tokens are maximal runs of *index word characters* — by default
///   everything not classified below, which keeps exotic scripts
///   searchable verbatim;
/// * soft hyphen, zero-width space/joiner/non-joiner, word joiner,
///   variation selectors and the listed combining marks are *ignorable*:
///   they neither split a run nor appear in the term, so `colo­rial`
///   indexes as `colorial` with an original range covering the soft
///   hyphen. Plain hyphens split like any punctuation — the legacy
///   grammar never joined them either;
/// * whitespace, ASCII/Latin-1/general punctuation, currency, arrows,
///   math and CJK punctuation end a run;
/// * normalization folds case and strips Latin diacritics to an ASCII
///   base (`É`→`e`, `ß`→`ss`, `œ`→`oe`, `Ĳ`→`ij`, fullwidth letters and
///   digits to ASCII), folds Greek and Cyrillic case (Greek monotonic
///   accents to their base vowel), and leaves every other script — CJK,
///   Hangul, Arabic, Devanagari, astral planes — verbatim. Polytonic
///   Greek stays accent-sensitive: documented limitation.
///
/// Profile identity: `unseal-index-tokenizer/1` +
/// `unseal-normalization-case-unaccent/1`. Serialized indexes record
/// both ids and refuse to load over a different profile.
library;

/// One token of the index tokenizer: the normalized term plus the
/// original UTF-16 `[start, end)` range it projects to.
final class IndexedToken {
  /// Creates a token.
  const IndexedToken(this.term, this.start, this.end);

  /// The normalized term (folded case, stripped diacritics).
  final String term;

  /// Inclusive start of the original run, in code units of the input.
  final int start;

  /// Exclusive end of the original run, in code units of the input.
  final int end;

  @override
  String toString() => 'IndexedToken($term, $start..$end)';
}

/// Reusable tokenizer of the search-index profile.
final class SearchIndexTokenizer {
  /// Tokenizer id recorded in serialized indexes.
  static const String tokenizerId = 'unseal-index-tokenizer/1';

  /// Normalization id recorded in serialized indexes.
  static const String normalizationId = 'unseal-normalization-case-unaccent/1';

  /// Canonical text space the tokenizer runs over.
  static const String textProfileId = 'unseal/canonical-document-text/1';

  List<int> _buffer = <int>[];

  /// Tokenizes [text] into normalized terms with original ranges.
  List<IndexedToken> tokenize(final String text) {
    _buffer = <int>[];
    final tokens = <IndexedToken>[];
    final units = text.codeUnits;
    var index = 0;
    var runStart = -1;
    while (index < units.length) {
      final unit = units[index];
      if (unit >= 0xD800 && unit <= 0xDBFF && index + 1 < units.length) {
        final low = units[index + 1];
        if (low >= 0xDC00 && low <= 0xDFFF) {
          // Astral code points stay verbatim word characters.
          if (runStart < 0) runStart = index;
          _buffer
            ..add(unit)
            ..add(low);
          index += 2;

          continue;
        }
      }

      final (kind, folded) = _classify(unit);
      switch (kind) {
        case _Kind.wordFold:
          if (runStart < 0) runStart = index;
          for (var i = 0; i < folded.length; i++) {
            _buffer.add(folded.codeUnitAt(i));
          }
        case _Kind.wordKeep:
          if (runStart < 0) runStart = index;
          _buffer.add(unit);
        case _Kind.ignorable:
          // Ignored inside a run (dehyphenation), skipped outside one.
          // The break matters: an empty case would fall through to the
          // boundary close below.
          break;
        case _Kind.boundary:
          if (runStart >= 0) {
            tokens.add(IndexedToken(String.fromCharCodes(_buffer), runStart, index));
            _buffer = <int>[];
            runStart = -1;
          }
      }
      index++;
    }
    if (runStart >= 0) {
      tokens.add(IndexedToken(String.fromCharCodes(_buffer), runStart, units.length));
    }

    return tokens;
  }
}

final class _Kind {
  static const int wordFold = 0;
  static const int wordKeep = 1;
  static const int ignorable = 2;
  static const int boundary = 3;
}

/// Classification of one code unit: `(kind, folded)`. `folded` is only
/// meaningful for [_Kind.wordFold].
(int, String) _classify(final int unit) {
  // --- ASCII fast paths ------------------------------------------------------
  if (unit <= 0x7F) {
    if ((unit >= 0x61 && unit <= 0x7A) || (unit >= 0x30 && unit <= 0x39) || unit == 0x5F) {
      return (_Kind.wordKeep, '');
    }
    if (unit >= 0x41 && unit <= 0x5A) return (_Kind.wordFold, String.fromCharCode(unit + 0x20));
    if ((unit >= 0x09 && unit <= 0x0D) || unit == 0x20) return (_Kind.boundary, '');

    return (_Kind.boundary, ''); // Controls and ASCII punctuation.
  }

  // --- ignorable ---------------------------------------------------------------
  if (_isIgnorable(unit)) return (_Kind.ignorable, '');

  // --- folds that expand to more than one character -----------------------------
  final expanded = _multiCharFolds[unit];
  if (expanded != null) return (_Kind.wordFold, expanded);

  // --- whitespace ----------------------------------------------------------------
  if (_isWhitespace(unit)) return (_Kind.boundary, '');

  // --- Latin ---------------------------------------------------------------------
  if (unit < 0x100) return _classifyLatin1(unit);
  if (unit < 0x180) return _classifyLatinExtendedA(unit);
  if (unit >= 0x1E00 && unit <= 0x1EFF) return _classifyLatinAdditional(unit);

  // --- Greek ----------------------------------------------------------------------
  if (unit >= 0x370 && unit <= 0x3FF) return _classifyGreek(unit);

  // --- Cyrillic -------------------------------------------------------------------
  if (unit >= 0x400 && unit <= 0x52F) return _classifyCyrillic(unit);

  // --- General punctuation and symbols (carving out word ranges) --------------------
  if (unit >= 0x2000 && unit <= 0x2BFF) {
    // Roman numerals are Number letters in the legacy grammar.
    if (unit >= 0x2160 && unit <= 0x2188) return (_Kind.wordKeep, '');

    return (_Kind.boundary, '');
  }
  if (unit >= 0x2E00 && unit <= 0x2E7F) return (_Kind.boundary, '');

  // --- CJK punctuation (carving out the iteration mark and numerals) ----------------
  if (unit >= 0x3000 && unit <= 0x303F) {
    if (unit >= 0x3005 && unit <= 0x3007) return (_Kind.wordKeep, '');

    return (_Kind.boundary, '');
  }

  // --- Halfwidth and fullwidth forms -------------------------------------------------
  if (unit >= 0xFF00 && unit <= 0xFFEF) {
    if (unit >= 0xFF10 && unit <= 0xFF19) {
      return (_Kind.wordFold, String.fromCharCode(unit - 0xFF10 + 0x30));
    }
    if (unit >= 0xFF21 && unit <= 0xFF3A) {
      return (_Kind.wordFold, String.fromCharCode(unit - 0xFF21 + 0x61));
    }
    if (unit >= 0xFF41 && unit <= 0xFF5A) {
      return (_Kind.wordFold, String.fromCharCode(unit - 0xFF41 + 0x61));
    }
    if (unit >= 0xFF66 && unit <= 0xFFDC) {
      return (_Kind.wordKeep, '');
    }

    return (_Kind.boundary, '');
  }

  // Everything else — scripts, symbols, astral planes — stays a word
  // character so unknown writing systems keep indexing verbatim.
  return (_Kind.wordKeep, '');
}

bool _isWhitespace(final int unit) {
  return unit == 0x85 ||
      unit == 0xA0 ||
      unit == 0x1680 ||
      (unit >= 0x2000 && unit <= 0x200A) ||
      unit == 0x2028 ||
      unit == 0x2029 ||
      unit == 0x202F ||
      unit == 0x205F ||
      unit == 0x3000;
}

bool _isIgnorable(final int unit) {
  return unit == 0xAD ||
      // Zero-width and directional formatting characters.
      (unit >= 0x200B && unit <= 0x200F) ||
      (unit >= 0x202A && unit <= 0x202E) ||
      (unit >= 0x2060 && unit <= 0x2064) ||
      unit == 0xFEFF ||
      // Variation selectors.
      (unit >= 0xFE00 && unit <= 0xFE0F) ||
      // Combining marks: Latin, Hebrew, Arabic, Syriac, Thaana, Devanagari,
      // Kana voicing, and the universal combining ranges.
      (unit >= 0x0300 && unit <= 0x036F) ||
      (unit >= 0x0483 && unit <= 0x0489) ||
      (unit >= 0x0591 && unit <= 0x05BD) ||
      unit == 0x05BF ||
      unit == 0x05C1 ||
      unit == 0x05C2 ||
      (unit >= 0x05C4 && unit <= 0x05C5) ||
      unit == 0x05C7 ||
      (unit >= 0x0610 && unit <= 0x061A) ||
      (unit >= 0x064B && unit <= 0x065F) ||
      unit == 0x0670 ||
      (unit >= 0x06D6 && unit <= 0x06DC) ||
      (unit >= 0x06DF && unit <= 0x06E4) ||
      (unit >= 0x06E7 && unit <= 0x06E8) ||
      (unit >= 0x06EA && unit <= 0x06ED) ||
      unit == 0x0711 ||
      (unit >= 0x0730 && unit <= 0x074A) ||
      (unit >= 0x07A6 && unit <= 0x07B0) ||
      (unit >= 0x07EB && unit <= 0x07F3) ||
      (unit >= 0x0816 && unit <= 0x0819) ||
      (unit >= 0x081B && unit <= 0x0823) ||
      (unit >= 0x0825 && unit <= 0x0827) ||
      (unit >= 0x0829 && unit <= 0x082D) ||
      (unit >= 0x0900 && unit <= 0x0902) ||
      unit == 0x093A ||
      unit == 0x093C ||
      (unit >= 0x0941 && unit <= 0x0948) ||
      unit == 0x094D ||
      (unit >= 0x0951 && unit <= 0x0957) ||
      (unit >= 0x0962 && unit <= 0x0963) ||
      (unit >= 0x3099 && unit <= 0x309A) ||
      (unit >= 0x1AB0 && unit <= 0x1AFF) ||
      (unit >= 0x1DC0 && unit <= 0x1DFF) ||
      (unit >= 0x20D0 && unit <= 0x20F0) ||
      (unit >= 0xFE20 && unit <= 0xFE2F);
}

/// Single-character folds that expand to more than one character.
const Map<int, String> _multiCharFolds = <int, String>{
  0xDF: 'ss', // ß.
  0xDE: 'th', // Þ.
  0xFE: 'th', // þ.
  0xE6: 'ae', // æ.
  0xF0: 'd', // ð.
  0x132: 'ij', // Ĳ.
  0x133: 'ij', // ĳ.
  0x14A: 'ng', // Ŋ.
  0x14B: 'ng', // ŋ.
  0x152: 'oe', // Œ.
  0x153: 'oe', // œ.
  0x1E9E: 'ss', // ẞ capital sharp s.
};

(int, String) _classifyLatin1(final int unit) {
  if (unit == 0xAA) return (_Kind.wordFold, 'a'); // Feminine ordinal.
  if (unit == 0xBA) return (_Kind.wordFold, 'o'); // Masculine ordinal.
  if (unit == 0xB5) return (_Kind.wordKeep, ''); // Micro sign.
  if ((unit >= 0xC0 && unit <= 0xC5) || (unit >= 0xE0 && unit <= 0xE5)) {
    return (_Kind.wordFold, 'a'); // À-Å à-å.
  }
  if (unit == 0xC7 || unit == 0xE7) return (_Kind.wordFold, 'c'); // Ç ç.
  if ((unit >= 0xC8 && unit <= 0xCB) || (unit >= 0xE8 && unit <= 0xEB)) {
    return (_Kind.wordFold, 'e'); // È-Ë è-ë.
  }
  if ((unit >= 0xCC && unit <= 0xCF) || (unit >= 0xEC && unit <= 0xEF)) {
    return (_Kind.wordFold, 'i'); // Ì-Ï ì-ï.
  }
  if (unit == 0xD1 || unit == 0xF1) return (_Kind.wordFold, 'n'); // Ñ ñ.
  if ((unit >= 0xD2 && unit <= 0xD6) ||
      (unit >= 0xF2 && unit <= 0xF6) ||
      unit == 0xD8 ||
      unit == 0xF8) {
    return (_Kind.wordFold, 'o'); // Ò-Ö ò-ö Ø ø.
  }
  if ((unit >= 0xD9 && unit <= 0xDC) || (unit >= 0xF9 && unit <= 0xFC)) {
    return (_Kind.wordFold, 'u'); // Ù-Ü ù-ü.
  }
  if (unit == 0xDD || unit == 0xFD || unit == 0xFF) return (_Kind.wordFold, 'y'); // Ý ý ÿ.

  return (_Kind.boundary, ''); // ¡¢£¤¥¦§¨©ª­®¯°±²³´¶·¸¹º»¼½¾¿ × ÷.
}

/// 0x100–0x17F folded to its lowercase base letter, one entry per code
/// unit; `?` marks the multi-char folds handled in [_multiCharFolds].
/// Groups: ĀĂĄ | ĆĈĊČ | ĎĐ | ĒĔĖĘĚ | ĜĞĠĢ | ĤĦ | ĨĪĬĮİı | Ĳĳ | Ĵ | Ķĸ |
/// ĹĻĽĿŁł | ŃŅŇŉ | Ŋŋ | ŌŎŐ | Œœ | ŔŖŘ | ŚŜŞŠ | ŢŤŦ | ŨŪŬŮŰŲ | Ŵ | ŶŷŸ |
/// ŹŻŽ | ſ.
const String _latinExtendedATable =
    'aaaaaa'
    'cccccccc'
    'dddd'
    'eeeeeeeeee'
    'gggggggg'
    'hhhh'
    'iiiiiiiiii'
    '??'
    'jj'
    'kkk'
    'llllllllll'
    'nnnnnnn'
    '??'
    'oooooo'
    '??'
    'rrrrrr'
    'ssssssss'
    'tttttt'
    'uuuuuuuuuuuu'
    'ww'
    'yyy'
    'zzzzzz'
    's';

(int, String) _classifyLatinExtendedA(final int unit) {
  final base = _latinExtendedATable.codeUnitAt(unit - 0x100);
  if (base == 0x3F) return (_Kind.wordKeep, '');

  return (_Kind.wordFold, String.fromCharCode(base));
}

(int, String) _classifyLatinAdditional(final int unit) {
  // Base-letter groups of 0x1E00–0x1EFF; each pair (upper, lower) folds
  // to the same base.
  if (unit <= 0x1E01) return (_Kind.wordFold, 'a'); // Ḁḁ.
  if (unit <= 0x1E07) return (_Kind.wordFold, 'b'); // ḂḃḄḅḆḇ.
  if (unit <= 0x1E09) return (_Kind.wordFold, 'c'); // Ḉḉ.
  if (unit <= 0x1E13) return (_Kind.wordFold, 'd'); // ḊḋḌḍḎḏḐḑ.
  if (unit <= 0x1E1D) return (_Kind.wordFold, 'e'); // Ḕ…ḝ.
  if (unit <= 0x1E1F) return (_Kind.wordFold, 'f'); // Ḟḟ.
  if (unit <= 0x1E21) return (_Kind.wordFold, 'g'); // Ḡḡ.
  if (unit <= 0x1E2B) return (_Kind.wordFold, 'h'); // Ḣ…ḫ.
  if (unit <= 0x1E2F) return (_Kind.wordFold, 'i'); // ḬḭḮḯ.
  if (unit <= 0x1E35) return (_Kind.wordFold, 'k'); // Ḱ…ḵ.
  if (unit <= 0x1E3D) return (_Kind.wordFold, 'l'); // Ḷ…ḽ.
  if (unit <= 0x1E43) return (_Kind.wordFold, 'm'); // Ḿ…ṃ.
  if (unit <= 0x1E4B) return (_Kind.wordFold, 'n'); // Ṅ…ṋ.
  if (unit <= 0x1E53) return (_Kind.wordFold, 'o'); // Ṍ…ṓ.
  if (unit <= 0x1E57) return (_Kind.wordFold, 'p'); // ṔṕṖṗ.
  if (unit <= 0x1E5F) return (_Kind.wordFold, 'r'); // Ṙ…ṟ.
  if (unit <= 0x1E69) return (_Kind.wordFold, 's'); // Ṡ…ṩ.
  if (unit <= 0x1E6F) return (_Kind.wordFold, 't'); // Ṫ…ṯ.
  if (unit <= 0x1E7B) return (_Kind.wordFold, 'u'); // Ṱṱ.
  if (unit <= 0x1E7F) return (_Kind.wordFold, 'v'); // ṼṽṾṿ.
  if (unit <= 0x1E89) return (_Kind.wordFold, 'w'); // Ẁ…ẉ.
  if (unit <= 0x1E8D) return (_Kind.wordFold, 'x'); // ẊẋẌẍ.
  if (unit <= 0x1E8F) return (_Kind.wordFold, 'y'); // Ẏẏ.
  if (unit <= 0x1E95) return (_Kind.wordFold, 'z'); // Ẑ…ẕ.
  if (unit == 0x1E96) return (_Kind.wordFold, 'h'); // ẖ.
  if (unit == 0x1E97) return (_Kind.wordFold, 't'); // ẗ.
  if (unit == 0x1E98) return (_Kind.wordFold, 'w'); // ẘ.
  if (unit == 0x1E99) return (_Kind.wordFold, 'y'); // ẙ.
  if (unit <= 0x1E9D) return (_Kind.wordFold, 's'); // ẚ ẛ ẜ ẝ.
  // 0x1E9E ẞ folds in _multiCharFolds.
  if (unit == 0x1E9F) return (_Kind.wordFold, 'd'); // ẟ.
  if (unit <= 0x1EB7) return (_Kind.wordFold, 'a'); // Ạ…ặ Vietnamese.
  if (unit <= 0x1EC7) return (_Kind.wordFold, 'e'); // Ẹ…ệ.
  if (unit <= 0x1ECB) return (_Kind.wordFold, 'i'); // ỈỉỊị.
  if (unit <= 0x1EE3) return (_Kind.wordFold, 'o'); // Ọ…ợ.
  if (unit <= 0x1EF1) return (_Kind.wordFold, 'u'); // Ụ…ự.
  if (unit <= 0x1EF9) return (_Kind.wordFold, 'y'); // Ỳ…ỹ.

  return (_Kind.wordKeep, '');
}

(int, String) _classifyGreek(final int unit) {
  // Monotonic uppercase with accent → accented lowercase.
  if (unit == 0x386) return (_Kind.wordFold, 'ά');
  if (unit >= 0x388 && unit <= 0x38A) {
    return (_Kind.wordFold, String.fromCharCode(unit + 0x25)); // ΈΉΊ.
  }
  if (unit == 0x38C) return (_Kind.wordFold, 'ό');
  if (unit >= 0x38E && unit <= 0x38F) {
    return (_Kind.wordFold, String.fromCharCode(unit + 0x3F)); // ΎΏ.
  }
  // Plain uppercase → lowercase.
  if ((unit >= 0x391 && unit <= 0x3A1) || (unit >= 0x3A3 && unit <= 0x3AB)) {
    return (_Kind.wordFold, String.fromCharCode(unit + 0x20));
  }
  // Monotonic accented lowercase → base vowel.
  if (unit == 0x390 || unit == 0x3AF) return (_Kind.wordFold, 'ί'); // ΐ ί.
  if (unit == 0x3AC) return (_Kind.wordFold, 'α'); // ά.
  if (unit == 0x3AD) return (_Kind.wordFold, 'ε'); // έ.
  if (unit == 0x3AE) return (_Kind.wordFold, 'η'); // ή.
  if (unit == 0x3B0) return (_Kind.wordFold, 'υ'); // ΰ.
  if (unit == 0x3C2) return (_Kind.wordFold, 'σ'); // Final sigma.
  if (unit == 0x3CC) return (_Kind.wordFold, 'ο'); // ό.
  if (unit == 0x3CD) return (_Kind.wordFold, 'υ'); // ύ.
  if (unit == 0x3CE) return (_Kind.wordFold, 'ω'); // ώ.

  // Punctuation of the block.
  if (unit == 0x374 ||
      unit == 0x375 ||
      unit == 0x37E ||
      unit == 0x384 ||
      unit == 0x385 ||
      unit == 0x387) {
    return (_Kind.boundary, '');
  }

  // Lowercase letters, archaic letters, and the symbol-letter forms stay
  // verbatim; the Coptic upper/lower pairs fold like Cyrillic extensions.
  if (unit >= 0x3E2 && unit <= 0x3EF && unit.isEven) {
    return (_Kind.wordFold, String.fromCharCode(unit + 1));
  }
  if ((unit >= 0x376 && unit <= 0x37D) ||
      unit == 0x37F ||
      (unit >= 0x3B1 && unit <= 0x3CB) ||
      (unit >= 0x3D0 && unit <= 0x3DD) ||
      (unit >= 0x3E2 && unit <= 0x3FF)) {
    return (_Kind.wordKeep, '');
  }

  return (_Kind.boundary, '');
}

(int, String) _classifyCyrillic(final int unit) {
  // ЁЂЃ… (0x400-0x40F) → ѐёѓ…; А-Я (0x410-0x42F) → а-я.
  if (unit >= 0x400 && unit <= 0x40F) {
    return (_Kind.wordFold, String.fromCharCode(unit + 0x50));
  }
  if (unit >= 0x410 && unit <= 0x42F) {
    return (_Kind.wordFold, String.fromCharCode(unit + 0x20));
  }
  if (unit == 0x482) return (_Kind.boundary, ''); // Cyrillic thousands sign.
  // Extension letters alternate upper/lower by parity (Ѡѡ Ѥѥ …); the
  // palochka (0x4C0) stands alone and folds to nothing.
  if (unit >= 0x460 && unit <= 0x52F && unit.isEven && unit != 0x4C0) {
    return (_Kind.wordFold, String.fromCharCode(unit + 1));
  }

  return (_Kind.wordKeep, ''); // а-я, ѐ-џ, and the lowercase extensions.
}
