/// Counts words in [text] according to the reader's compatibility rule for reading-time estimates.
///
/// Every Asian code point strictly above U+3000 counts as one word. The remaining text is split
/// using Pythoncompatible whitespace rules so reading-time estimates remain stable across
/// implementations.
int countWords(final String text) {
  const ideographicSpace = 0x3000;

  final units = text.codeUnits;
  final length = units.length;
  var nonAsianWords = 0;
  var asianChars = 0;
  var isInWord = false;
  var i = 0;
  while (i < length) {
    var rune = units[i];
    if (_isHighSurrogate(rune) && i + 1 < length && _isLowSurrogate(units[i + 1])) {
      rune = 0x10000 + ((rune - 0xD800) << 10) + (units[i + 1] - 0xDC00);
      i += 2;
    } else {
      i++;
    }
    if (rune > ideographicSpace) {
      asianChars++;
      isInWord = false;
    } else if (_isSplitWhitespace(rune)) {
      isInWord = false;
    } else if (!isInWord) {
      isInWord = true;
      nonAsianWords++;
    }
  }

  return nonAsianWords + asianChars;
}

bool _isHighSurrogate(final int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(final int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

bool _isSplitWhitespace(final int rune) {
  return rune == 0x20 ||
      (rune >= 0x09 && rune <= 0x0D) ||
      (rune >= 0x1C && rune <= 0x1F) ||
      rune == 0x85 ||
      rune == 0xA0 ||
      rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x200A) ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202F ||
      rune == 0x205F ||
      rune == 0x3000;
}
