/// The canonical character space of a content file: the concatenation of the visible text inside
/// `<body>`, with entities decoded and whitespace kept as-is.
///
/// A WebView-based reader walks the DOM text nodes rooted at `<body>` (skipping `script`/`style`)
/// and concatenates them; [DocumentTextScanner.scan] mirrors that exactly on the HTML source:
/// everything outside `<body>` (head, title, doctype) contributes nothing, entities are decoded in
/// a single pass (like the HTML parser), tags and comments contribute nothing, whitespace is kept
/// as-is. Char offsets in this space are stable across reflow and match the DOM on the WebView side
/// — search, CFI and reading positions all share this foundational representation.
library;

import '../entities/file/text_file.dart';

const _lessThan = 0x3C;
const _greaterThan = 0x3E;
const _bang = 0x21;

const _commentOpen = <int>[0x21, 0x2D, 0x2D]; // !--
const _cdataOpen = <int>[
  0x21, 0x5B, 0x43, 0x44, 0x41, 0x54, 0x41, 0x5B, // ![CDATA[
];

/// Named entities supported by the canonical text scanner.
const _namedEntities = <String, String>{
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': '\u00A0',
  'copy': '\u00A9',
  'reg': '\u00AE',
  'trade': '\u2122',
  'hellip': '\u2026',
  'mdash': '\u2014',
  'ndash': '\u2013',
  'lsquo': '\u2018',
  'rsquo': '\u2019',
  'ldquo': '\u201C',
  'rdquo': '\u201D',
  'laquo': '\u00AB',
  'raquo': '\u00BB',
  'deg': '\u00B0',
  'plusmn': '\u00B1',
  'times': '\u00D7',
  'divide': '\u00F7',
  'eacute': '\u00E9',
  'egrave': '\u00E8',
  'agrave': '\u00E0',
  'ccedil': '\u00E7',
  'uuml': '\u00FC',
  'ouml': '\u00F6',
  'auml': '\u00E4',
  'szlig': '\u00DF',
};

/// Memoized document text keyed by [TextFile] instance.
final Expando<String> _documentTextCache = Expando<String>();

/// Scans an HTML/XHTML source into the canonical document-text space.
///
/// Single left-to-right pass over the input, bulk-copying text spans between markup (like the
/// plain-text utility in `foundation/text/plain_text.dart`). The pass reproduces the output of the
/// previous seven-pass regex pipeline byte for byte:
///
/// * the `<body>` inner range is extracted first (everything outside contributes nothing; the
///   pipeline kept the text between the first `<body …>` and the *last* `</body>`);
/// * complete `<script>`/`<style>` blocks, comments and CDATA sections are removed, with the
///   priority and per-rule input view of the old sequential passes — e.g. a script block is removed
///   even when it sits inside what would later have been a comment; a `-->` inside a CDATA section
///   does not end a comment. A CDATA section collapses to the two characters `$1` — an artifact of
///   the old `replaceAll(…, r'$1')` whose replacement Dart does not interpolate — and must stay for
///   offset stability;
/// * `<` opens a tag only before an ASCII letter or `/` (HTML5 tokenizer rule — the same view a
///   WebView DOM takes); elsewhere (`a < b > c`) it stays literal text. Declarations (`<!…>`) and
///   tags (`<…>`) run to the next effective `>`, and a `<` left with no effective `>` ahead stays
///   literal;
/// * named and numeric entities are decoded with the exact edge semantics of [decodeEntity] (NUL/C1
///   → U+FFFD, invalid numerics and unknown names stay literal). Because entities were decoded by
///   the old pipeline *after* markup removal, an entity whose halves are glued together by removed
///   markup still decodes (`&am<p></p>p;` → `&`), which the scanner reproduces by keeping a pending
///   entity across removed spans;
/// * whitespace is kept as-is.
///
/// Scans one body range while keeping the state needed to decode entities across removed markup.
final class DocumentTextScanner {
  /// Creates a scanner for [html].
  DocumentTextScanner(final String html) : _html = html, _units = html.codeUnits;

  static const _ampersand = 0x26;
  static const _hash = 0x23;
  static const _lowerX = 0x78;
  static const _upperX = 0x58;
  static const _semicolon = 0x3B;
  static const _dollar = 0x24;
  static const _digitOne = 0x31;
  static const _slash = 0x2F;
  static const _question = 0x3F;

  final String _html;
  final List<int> _units;
  final StringBuffer _out = StringBuffer();
  final List<int> _pending = <int>[];
  var _isPending = false;
  var _isTagExhausted = false;
  var _isStreamExhausted = false;

  /// Returns the canonical text after removing markup and decoding supported entities.
  String scan() {
    final (start, end) = _bodyRange(_units);
    var i = start;
    while (i < end) {
      final unit = _units[i];
      if (unit == _lessThan) {
        final next = _consumeLessThan(i, end);
        if (next != i) {
          i = next;

          continue;
        }

        _writeUnit(unit);
        i++;

        continue;
      }

      if (unit == _ampersand) {
        if (_isPending) _flushPending();
        _isPending = true;
        _pending.clear();
        i++;

        continue;
      }

      if (_isPending) {
        _feedUnit(unit);
        i++;

        continue;
      }

      i = _writePlainRun(i, end);
    }
    if (_isPending) _flushPending();

    return _out.toString();
  }

  int _consumeLessThan(final int start, final int end) {
    final block = _scriptBlockEnd(_units, start, end);
    if (block != -1) return block;

    if (_startsWith(_units, start + 1, _commentOpen)) {
      final close = _commentEnd(_units, start, end);
      if (close != -1) return close;
    }

    if (_startsWith(_units, start + 1, _cdataOpen)) {
      final close = _cdataEnd(_units, start, end);

      if (close != -1) {
        _writeUnit(_dollar);
        _writeUnit(_digitOne);

        return close;
      }
    }
    final isDeclaration = start + 1 < end && _units[start + 1] == _bang;
    if (isDeclaration && !_isStreamExhausted) {
      final gt = _findGtEnding(_units, start + 2, end, isDeclarationSkipping: false);
      if (gt != -1) return gt + 1;

      _isStreamExhausted = true;
      _isTagExhausted = true;
    }
    final next = start + 1 < end ? _units[start + 1] : -1;
    final opensTag = _isAlpha(next) || next == _slash || next == _question;
    if (!_isTagExhausted && opensTag) {
      final gt = _findGtEnding(_units, start + 1, end, isDeclarationSkipping: true);
      if (gt != -1) return gt + 1;

      _isTagExhausted = true;
    }

    return start;
  }

  int _writePlainRun(final int start, final int end) {
    var runEnd = start + 1;
    while (runEnd < end) {
      final next = _units[runEnd];
      if (next == _lessThan || next == _ampersand) break;

      runEnd++;
    }
    _out.write(_html.substring(start, runEnd));

    return runEnd;
  }

  void _feedUnit(final int unit) {
    final length = _pending.length;
    final isNumeric = length > 0 && _pending.first == _hash;
    final isHex = isNumeric && length > 1 && (_pending[1] == _lowerX || _pending[1] == _upperX);
    final closesEntity =
        unit == _semicolon && ((!isNumeric && length > 0) || (isNumeric && length > 1));
    if (closesEntity) {
      _completePending();
      return;
    }

    final canAppend = switch (length) {
      0 => unit == _hash || _isAlpha(unit),
      1 when isNumeric => unit == _lowerX || unit == _upperX || _isDigit(unit),
      _ when isHex => _isHexUnit(unit) && length - 2 < 6,
      _ when isNumeric => _isDigit(unit) && length - 1 < 7,
      _ => _isAlphanumeric(unit) && length < 32,
    };
    if (canAppend) {
      _pending.add(unit);
      return;
    }

    _flushPending();
    if (unit == _ampersand) {
      _isPending = true;
    } else {
      _out.writeCharCode(unit);
    }
  }

  void _completePending() {
    final decoded = decodeEntity(String.fromCharCodes(_pending));

    if (decoded == null) {
      _flushPending();
      _out.writeCharCode(_semicolon);

      return;
    }

    _out.write(decoded);
    _pending.clear();
    _isPending = false;
  }

  void _flushPending() {
    _out.writeCharCode(_ampersand);
    _out.write(String.fromCharCodes(_pending));
    _pending.clear();
    _isPending = false;
  }

  void _writeUnit(final int unit) {
    if (_isPending) _flushPending();
    _out.writeCharCode(unit);
  }
}

/// Returns the `(start, end)` range of the `<body>` inner source: the text after the first opening
/// tag's `>` up to the *last* `</body>`, matching the greedy `(.*)` of the previous pipeline.
/// Returns the whole range when no body pair exists.
(int, int) _bodyRange(final List<int> units) {
  const bodyOpen = <int>[0x3C, 0x62, 0x6F, 0x64, 0x79];
  const bodyClose = <int>[0x3C, 0x2F, 0x62, 0x6F, 0x64, 0x79, 0x3E];

  final length = units.length;
  var from = 0;
  while (true) {
    final open = _indexOfIgnoreCase(units, from, length, bodyOpen);
    if (open == -1) return (0, length);

    final afterName = open + bodyOpen.length;
    var gt = afterName;
    while (gt < length && units[gt] != _greaterThan) {
      gt++;
    }

    if (gt == length) {
      from = afterName;

      continue;
    }

    final close = _lastIndexOfIgnoreCase(units, gt + 1, length, bodyClose);
    if (close == -1) {
      from = afterName;

      continue;
    }

    return (gt + 1, close);
  }
}

/// Index right after a complete `<script>…</script>` / `<style>…</style>` span starting at [start].
/// Returns `-1` when [start] opens no such block. Mirrors the old `<(script|style)\b[^>]*>.*?</\1>`
/// with `dotAll` + `caseSensitive: false`: the name matches case-insensitively (so the
/// backreference close does too), and the closing tag is the *first* one after the opening tag's
/// `'>'`.
int _scriptBlockEnd(final List<int> units, final int start, final int end) {
  const scriptName = <int>[0x73, 0x63, 0x72, 0x69, 0x70, 0x74];
  const styleName = <int>[0x73, 0x74, 0x79, 0x6C, 0x65];
  const scriptClose = <int>[0x3C, 0x2F, 0x73, 0x63, 0x72, 0x69, 0x70, 0x74, 0x3E];
  const styleClose = <int>[0x3C, 0x2F, 0x73, 0x74, 0x79, 0x6C, 0x65, 0x3E];

  final isScript = _matchesName(units, start + 1, scriptName, end);
  if (!isScript && !_matchesName(units, start + 1, styleName, end)) return -1;

  final nameLength = isScript ? scriptName.length : styleName.length;
  final afterName = start + 1 + nameLength;
  // `\b`: the name must not run into another word character.
  if (afterName < end && _isWordUnit(units[afterName])) return -1;

  // Opening tag up to the first '>'; without one the block cannot match.
  var openEnd = -1;
  for (var i = afterName; i < end; i++) {
    if (units[i] == _greaterThan) {
      openEnd = i;

      break;
    }
  }
  if (openEnd == -1) return -1;

  final closePattern = isScript ? scriptClose : styleClose;
  final close = _indexOfIgnoreCase(units, openEnd + 1, end, closePattern);
  if (close == -1) return -1;

  return close + closePattern.length;
}

/// Index right after the `-->` of the comment starting at [start], or `-1` when it never closes.
/// Runs on the pass-1 view: script blocks are already removed, so their `'>'`s — and any `-->`
/// inside them — do not count (the classic `<script><!-- … --></script>` idiom).
int _commentEnd(final List<int> units, final int start, final int end) {
  const commentClose = <int>[0x2D, 0x2D, 0x3E];

  var i = start + _commentOpen.length;
  while (i < end) {
    if (units[i] == _lessThan) {
      final block = _scriptBlockEnd(units, i, end);
      if (block != -1) {
        i = block;

        continue;
      }
    }
    if (_startsWith(units, i, commentClose)) return i + commentClose.length;

    i++;
  }

  return -1;
}

/// Index right after the `]]>` of the CDATA section starting at [start], or `-1` when it never
/// closes. Runs on the pass-2 view: script blocks *and* comments are already removed, so a `]]>`
/// inside either does not count.
int _cdataEnd(final List<int> units, final int start, final int end) {
  const cdataClose = <int>[0x5D, 0x5D, 0x3E];

  var i = start + _cdataOpen.length;
  while (i < end) {
    if (units[i] == _lessThan) {
      final block = _scriptBlockEnd(units, i, end);
      if (block != -1) {
        i = block;

        continue;
      }

      if (_startsWith(units, i + 1, _commentOpen)) {
        final close = _commentEnd(units, i, end);
        if (close != -1) {
          i = close;

          continue;
        }
      }
    }
    if (_startsWith(units, i, cdataClose)) return i + cdataClose.length;

    i++;
  }

  return -1;
}

/// Index of the first `'>'` of the effective stream — the input with script blocks, comments and
/// CDATA sections removed — at or after [from], or `-1`.
///
/// With [isDeclarationSkipping] the stream is the pass-5 view, where declarations were removed as
/// well: their `'>'`s do not count, and an unterminated `<!--`/`<![CDATA[` is treated as
/// declaration content instead.
int _findGtEnding(
  final List<int> units,
  final int from,
  final int end, {
  required final bool isDeclarationSkipping,
}) {
  var i = from;
  while (i < end) {
    final unit = units[i];
    if (unit == _greaterThan) return i;

    if (unit != _lessThan) {
      i++;

      continue;
    }

    final block = _scriptBlockEnd(units, i, end);
    if (block != -1) {
      i = block;

      continue;
    }

    if (_startsWith(units, i + 1, _commentOpen)) {
      final close = _commentEnd(units, i, end);
      if (close != -1) {
        i = close;

        continue;
      }
    }

    if (_startsWith(units, i + 1, _cdataOpen)) {
      final close = _cdataEnd(units, i, end);
      if (close != -1) {
        i = close;

        continue;
      }
    }

    if (isDeclarationSkipping && i + 1 < end && units[i + 1] == _bang) {
      final gt = _findGtEnding(units, i + 2, end, isDeclarationSkipping: false);
      if (gt == -1) return -1;

      i = gt + 1;

      continue;
    }

    i++;
  }

  return -1;
}

/// Returns the document text of [file], memoized per instance.
///
/// [TextFile] instances are stable per parsed book — parsers create them once and expose them
/// through the final `Files.html` list — and immutable (`content` is final), so the computed text
/// is cached in an [Expando] keyed by the instance. Search and other repeated consumers hit the
/// memo instead of re-running the scan.
String documentTextOf(final TextFile file) {
  final cached = _documentTextCache[file];
  if (cached != null) return cached;

  final computed = DocumentTextScanner(file.content).scan();
  _documentTextCache[file] = computed;

  return computed;
}

/// Decodes a single entity body (without `&` and `;`).
String? decodeEntity(final String body) {
  if (body.startsWith('#')) {
    final codePoint = body.startsWith('#x') || body.startsWith('#X')
        ? int.tryParse(body.substring(2), radix: 16)
        : int.tryParse(body.substring(1));
    if (codePoint == null || codePoint < 0 || codePoint > 0x10FFFF) return null;
    // HTML parser maps NUL and C1 controls to the replacement char.
    if (codePoint == 0 || (codePoint >= 0x80 && codePoint <= 0x9F)) {
      return String.fromCharCodes(const [0xFFFD]);
    }

    return String.fromCharCodes([codePoint]);
  }

  return _namedEntities[body];
}

bool _isAlpha(final int codeUnit) {
  return (codeUnit >= 0x41 && codeUnit <= 0x5A) || (codeUnit >= 0x61 && codeUnit <= 0x7A);
}

bool _isDigit(final int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

bool _isAlphanumeric(final int codeUnit) => _isAlpha(codeUnit) || _isDigit(codeUnit);

bool _isWordUnit(final int codeUnit) => _isAlphanumeric(codeUnit) || codeUnit == 0x5F;

bool _isHexUnit(final int codeUnit) {
  return _isDigit(codeUnit) ||
      (codeUnit >= 0x41 && codeUnit <= 0x46) ||
      (codeUnit >= 0x61 && codeUnit <= 0x66);
}

bool _matchesName(final List<int> units, final int at, final List<int> lowerName, final int end) {
  if (at + lowerName.length > end) return false;

  for (var i = 0; i < lowerName.length; i++) {
    if (_toLowerCase(units[at + i]) != lowerName[i]) return false;
  }

  return true;
}

bool _startsWith(final List<int> units, final int at, final List<int> prefix) {
  if (at < 0 || at + prefix.length > units.length) return false;

  for (var i = 0; i < prefix.length; i++) {
    if (units[at + i] != prefix[i]) return false;
  }

  return true;
}

int _toLowerCase(final int codeUnit) {
  return codeUnit >= 0x41 && codeUnit <= 0x5A ? codeUnit + 0x20 : codeUnit;
}

/// First index of case-insensitive [lowercasePattern] between `from` and `end`, or -1.
int _indexOfIgnoreCase(
  final List<int> units,
  final int from,
  final int end,
  final List<int> lowercasePattern,
) {
  final lastStart = end - lowercasePattern.length;
  for (var i = from; i <= lastStart; i++) {
    var isMatched = true;
    for (var j = 0; j < lowercasePattern.length; j++) {
      if (_toLowerCase(units[i + j]) != lowercasePattern[j]) {
        isMatched = false;

        break;
      }
    }
    if (isMatched) return i;
  }

  return -1;
}

/// Last index of case-insensitive [lowercasePattern] starting between `from` and `end`, or -1.
int _lastIndexOfIgnoreCase(
  final List<int> units,
  final int from,
  final int end,
  final List<int> lowercasePattern,
) {
  for (var i = end - lowercasePattern.length; i >= from; i--) {
    var isMatched = true;
    for (var j = 0; j < lowercasePattern.length; j++) {
      if (_toLowerCase(units[i + j]) != lowercasePattern[j]) {
        isMatched = false;

        break;
      }
    }
    if (isMatched) return i;
  }

  return -1;
}
