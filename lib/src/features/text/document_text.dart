/// The canonical character space of a content file: the concatenation
/// of the visible text inside `<body>`, with entities decoded and
/// whitespace kept as-is.
///
/// A WebView-based reader walks the DOM text nodes rooted at
/// `<body>` (skipping `script`/`style`) and concatenates them;
/// [documentText] mirrors that exactly on the HTML source: everything
/// outside `<body>` (head, title, doctype) contributes nothing,
/// entities are decoded in a single pass (like the HTML parser), tags
/// and comments contribute nothing, whitespace is kept as-is. Char
/// offsets in this space are stable across reflow and match the DOM
/// on the WebView side — search, CFI and reading positions all share
/// it.
library;

import 'package:e_livre/src/foundation/entities/file/text_file.dart';

/// Extracts the canonical document text of an HTML/XHTML [html]
/// source.
///
/// Single left-to-right pass over the input, bulk-copying text spans
/// between markup (like the plain-text utility in
/// `foundation/utils/plain_text.dart`). The pass reproduces the
/// output of the previous seven-pass regex pipeline byte for byte:
///
/// * the `<body>` inner range is extracted first (everything outside
///   contributes nothing; the pipeline kept the text between the first
///   `<body …>` and the *last* `</body>`);
/// * complete `<script>`/`<style>` blocks, comments and CDATA
///   sections are removed, with the priority and per-rule input view
///   of the old sequential passes — e.g. a script block is removed
///   even when it sits inside what would later have been a comment,
///   and a `-->` inside a CDATA section does not end a comment.
///   A CDATA section collapses to the two characters `$1` — an
///   artifact of the old `replaceAll(…, r'$1')` whose replacement
///   Dart does not interpolate — and must stay for offset stability;
/// * an unterminated `<` stays literal text; declarations (`<!…>`)
///   and tags (`<…>`) run to the next effective `>`;
/// * named and numeric entities are decoded with the exact edge
///   semantics of [decodeEntity] (NUL/C1 → U+FFFD, invalid numerics
///   and unknown names stay literal). Because entities were decoded
///   by the old pipeline *after* markup removal, an entity whose
///   halves are glued together by removed markup still decodes
///   (`&am<p></p>p;` → `&`), which the scanner reproduces by keeping
///   a pending entity across removed spans;
/// * whitespace is kept as-is.
String documentText(final String html) {
  final units = html.codeUnits;
  final (start, end) = _bodyRange(units);
  final out = StringBuffer();

  // Pending entity state: characters collected after a live '&' (the
  // body without '&' and ';'). Removed markup is transparent to it,
  // mirroring the old pipeline where entities were matched on the
  // final stripped string.
  final pending = <int>[];
  var isPending = false;

  void flushPending() {
    out.writeCharCode(_ampersand);
    out.write(String.fromCharCodes(pending));
    pending.clear();
    isPending = false;
  }

  // Ends a pending entity with the ';': decodes it, or keeps the
  // whole `&…;` literal when [decodeEntity] rejects it.
  void completePending() {
    final body = String.fromCharCodes(pending);
    final decoded = decodeEntity(body);
    if (decoded == null) {
      flushPending();
      out.writeCharCode(_semicolon);
    } else {
      out.write(decoded);
      pending.clear();
      isPending = false;
    }
  }

  // Feeds one live text character into the pending entity. Invalid
  // characters flush the pending text literally and are reprocessed
  // as plain text (or start a fresh entity when they are themselves
  // an '&').
  void feedUnit(final int unit) {
    final length = pending.length;
    if (length == 0) {
      if (unit == _hash || _isAlpha(unit)) {
        pending.add(unit);
        return;
      }
    } else if (length == 1 && pending[0] == _hash) {
      if (unit == _lowerX || unit == _upperX || _isDigit(unit)) {
        pending.add(unit);
        return;
      }
    } else if (pending[0] == _hash && (pending[1] == _lowerX || pending[1] == _upperX)) {
      // Hexadecimal reference: at most six digits before ';'.
      if (unit == _semicolon) {
        completePending();
        return;
      }
      if (_isHexUnit(unit) && length - 2 < 6) {
        pending.add(unit);
        return;
      }
    } else if (pending[0] == _hash) {
      // Decimal reference: at most seven digits before ';'.
      if (unit == _semicolon) {
        completePending();
        return;
      }
      if (_isDigit(unit) && length - 1 < 7) {
        pending.add(unit);
        return;
      }
    } else {
      // Named reference: at most 32 alphanumeric characters.
      if (unit == _semicolon) {
        completePending();
        return;
      }
      if (_isAlphanumeric(unit) && length < 32) {
        pending.add(unit);
        return;
      }
    }
    // Not part of the entity grammar: flush and reprocess.
    flushPending();
    if (unit == _ampersand) {
      isPending = true;
    } else {
      out.writeCharCode(unit);
    }
  }

  // Writes one live text character, resolving a pending entity first
  // so output order is preserved.
  void writeUnit(final int unit) {
    if (isPending) {
      flushPending();
    }
    out.writeCharCode(unit);
  }

  // Lookahead failure flags. A failed tag scan means no effective '>'
  // is left for tags; declarations may still close on their own '>'.
  // A failed declaration scan means no '>' is left in the stream at
  // all, so neither can match anymore.
  var isTagExhausted = false;
  var isStreamExhausted = false;

  var i = start;
  while (i < end) {
    final unit = units[i];
    if (unit == _lessThan) {
      // Pass 1: complete <script>/<style> blocks.
      final block = _scriptBlockEnd(units, i, end);
      if (block != -1) {
        i = block;
        continue;
      }
      // Pass 2: comments (an unterminated '<!--' falls through).
      if (_startsWith(units, i + 1, _commentOpen)) {
        final close = _commentEnd(units, i, end);
        if (close != -1) {
          i = close;
          continue;
        }
      }
      // Pass 3: CDATA sections collapse to the literal `$1`.
      if (_startsWith(units, i + 1, _cdataOpen)) {
        final close = _cdataEnd(units, i, end);
        if (close != -1) {
          writeUnit(_dollar);
          writeUnit(_digitOne);
          i = close;
          continue;
        }
      }
      // Pass 4: declarations '<!…>' up to the next effective '>'.
      final isDeclaration = i + 1 < end && units[i + 1] == _bang;
      if (isDeclaration && !isStreamExhausted) {
        final gt = _findGtEnding(units, i + 2, end, isDeclarationSkipping: false);
        if (gt != -1) {
          i = gt + 1;
          continue;
        }
        isStreamExhausted = true;
        isTagExhausted = true;
      }
      // Pass 5: tags '<…>' up to the next effective '>' (declarations
      // were already removed at that point, so their '>' does not
      // count).
      if (!isTagExhausted) {
        final gt = _findGtEnding(units, i + 1, end, isDeclarationSkipping: true);
        if (gt != -1) {
          i = gt + 1;
          continue;
        }
        isTagExhausted = true;
      }
      // Unterminated '<': literal text.
      writeUnit(unit);
      i++;
      continue;
    }
    if (unit == _ampersand) {
      if (isPending) {
        flushPending();
      }
      isPending = true;
      pending.clear();
      i++;
      continue;
    }
    if (isPending) {
      feedUnit(unit);
      i++;
      continue;
    }
    // Plain run: bulk-copy up to the next '<' or '&'.
    var runEnd = i + 1;
    while (runEnd < end) {
      final next = units[runEnd];
      if (next == _lessThan || next == _ampersand) {
        break;
      }
      runEnd++;
    }
    out.write(html.substring(i, runEnd));
    i = runEnd;
  }
  if (isPending) {
    flushPending();
  }
  return out.toString();
}

/// Returns the `(start, end)` range of the `<body>` inner source: the
/// text after the first `<body …>`'s `'>'` up to the *last*
/// `</body>`, matching the greedy `(.*)` of the previous pipeline.
/// The whole range when no `<body …>…</body>` pair exists.
(int, int) _bodyRange(final List<int> units) {
  final length = units.length;
  var from = 0;
  while (true) {
    final open = _indexOfIgnoreCase(units, from, length, _bodyOpen);
    if (open == -1) {
      return (0, length);
    }
    final afterName = open + _bodyOpen.length;
    var gt = afterName;
    while (gt < length && units[gt] != _greaterThan) {
      gt++;
    }
    if (gt == length) {
      from = afterName;
      continue;
    }
    final close = _lastIndexOfIgnoreCase(units, gt + 1, length, _bodyClose);
    if (close == -1) {
      from = afterName;
      continue;
    }
    return (gt + 1, close);
  }
}

/// Index right after a complete `<script>…</script>` /
/// `<style>…</style>` span starting at [start], or `-1` when [start]
/// opens no such block. Mirrors the old `<(script|style)\b[^>]*>.*?</\1>`
/// with `dotAll` + `caseSensitive: false`: the name matches
/// case-insensitively (so the backreference close does too), and the
/// closing tag is the *first* one after the opening tag's `'>'`.
int _scriptBlockEnd(final List<int> units, final int start, final int end) {
  final isScript = _matchesName(units, start + 1, _scriptName, end);
  if (!isScript && !_matchesName(units, start + 1, _styleName, end)) {
    return -1;
  }
  final nameLength = isScript ? _scriptName.length : _styleName.length;
  final afterName = start + 1 + nameLength;
  // `\b`: the name must not run into another word character.
  if (afterName < end && _isWordUnit(units[afterName])) {
    return -1;
  }
  // Opening tag up to the first '>'; without one the block cannot
  // match.
  var openEnd = -1;
  for (var i = afterName; i < end; i++) {
    if (units[i] == _greaterThan) {
      openEnd = i;
      break;
    }
  }
  if (openEnd == -1) {
    return -1;
  }
  final closePattern = isScript ? _scriptClose : _styleClose;
  final close = _indexOfIgnoreCase(units, openEnd + 1, end, closePattern);
  if (close == -1) {
    return -1;
  }
  return close + closePattern.length;
}

/// Index right after the `-->` of the comment starting at [start], or
/// `-1` when it never closes. Runs on the pass-1 view: script blocks
/// are already removed, so their `'>'`s — and any `-->` inside them —
/// do not count (the classic `<script><!-- … --></script>` idiom).
int _commentEnd(final List<int> units, final int start, final int end) {
  var i = start + _commentOpen.length;
  while (i < end) {
    if (units[i] == _lessThan) {
      final block = _scriptBlockEnd(units, i, end);
      if (block != -1) {
        i = block;
        continue;
      }
    }
    if (_startsWith(units, i, _commentClose)) {
      return i + _commentClose.length;
    }
    i++;
  }
  return -1;
}

/// Index right after the `]]>` of the CDATA section starting at
/// [start], or `-1` when it never closes. Runs on the pass-2 view:
/// script blocks *and* comments are already removed, so a `]]>` inside
/// either does not count.
int _cdataEnd(final List<int> units, final int start, final int end) {
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
    if (_startsWith(units, i, _cdataClose)) {
      return i + _cdataClose.length;
    }
    i++;
  }
  return -1;
}

/// Index of the first `'>'` of the effective stream — the input with
/// script blocks, comments and CDATA sections removed — at or after
/// [from], or `-1`.
///
/// With [isDeclarationSkipping] the stream is the pass-5 view, where
/// declarations were removed as well: their `'>'`s do not count and an
/// unterminated `<!--`/`<![CDATA[` is declaration food instead.
int _findGtEnding(
  final List<int> units,
  final int from,
  final int end, {
  required final bool isDeclarationSkipping,
}) {
  var i = from;
  while (i < end) {
    final unit = units[i];
    if (unit == _greaterThan) {
      return i;
    }
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
      if (gt == -1) {
        return -1;
      }
      i = gt + 1;
      continue;
    }
    i++;
  }
  return -1;
}

/// Returns the document text of [file], memoized per instance.
///
/// [TextFile] instances are stable per parsed book — parsers create
/// them once and expose them through the final `Files.html` list — and
/// immutable (`content` is final), so the computed text is cached in
/// an [Expando] keyed by the instance. Search and other repeated
/// consumers hit the memo instead of re-running the scan.
String documentTextOf(final TextFile file) {
  final cached = _documentTextCache[file];
  if (cached != null) {
    return cached;
  }
  final computed = documentText(file.content);
  _documentTextCache[file] = computed;
  return computed;
}

/// Memoized document text keyed by [TextFile] instance.
final Expando<String> _documentTextCache = Expando<String>();

/// Decodes a single entity body (without `&` and `;`).
String? decodeEntity(final String body) {
  if (body.startsWith('#')) {
    final codePoint = body.startsWith('#x') || body.startsWith('#X')
        ? int.tryParse(body.substring(2), radix: 16)
        : int.tryParse(body.substring(1));
    if (codePoint == null || codePoint < 0 || codePoint > 0x10FFFF) {
      return null;
    }
    // HTML parser maps NUL and C1 controls to the replacement char.
    if (codePoint == 0 || (codePoint >= 0x80 && codePoint <= 0x9F)) {
      return String.fromCharCodes(const [0xFFFD]);
    }
    return String.fromCharCodes([codePoint]);
  }
  return _namedEntities[body];
}

const Map<String, String> _namedEntities = <String, String>{
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

const int _lessThan = 0x3C;
const int _greaterThan = 0x3E;
const int _ampersand = 0x26;
const int _hash = 0x23;
const int _lowerX = 0x78;
const int _upperX = 0x58;
const int _bang = 0x21;
const int _semicolon = 0x3B;
const int _dollar = 0x24;
const int _digitOne = 0x31;

const List<int> _bodyOpen = <int>[0x3C, 0x62, 0x6F, 0x64, 0x79]; // <body
const List<int> _bodyClose = <int>[
  0x3C, 0x2F, 0x62, 0x6F, 0x64, 0x79, 0x3E, // </body>
];
const List<int> _commentOpen = <int>[0x21, 0x2D, 0x2D]; // !--
const List<int> _commentClose = <int>[0x2D, 0x2D, 0x3E]; // -->
const List<int> _cdataOpen = <int>[
  0x21, 0x5B, 0x43, 0x44, 0x41, 0x54, 0x41, 0x5B, // ![CDATA[
];
const List<int> _cdataClose = <int>[0x5D, 0x5D, 0x3E]; // ]]>
const List<int> _scriptName = <int>[0x73, 0x63, 0x72, 0x69, 0x70, 0x74];
const List<int> _styleName = <int>[0x73, 0x74, 0x79, 0x6C, 0x65];
const List<int> _scriptClose = <int>[0x3C, 0x2F, 0x73, 0x63, 0x72, 0x69, 0x70, 0x74, 0x3E];
const List<int> _styleClose = <int>[0x3C, 0x2F, 0x73, 0x74, 0x79, 0x6C, 0x65, 0x3E];

bool _isAlpha(final int codeUnit) =>
    (codeUnit >= 0x41 && codeUnit <= 0x5A) || (codeUnit >= 0x61 && codeUnit <= 0x7A);

bool _isDigit(final int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

bool _isAlphanumeric(final int codeUnit) => _isAlpha(codeUnit) || _isDigit(codeUnit);

bool _isWordUnit(final int codeUnit) => _isAlphanumeric(codeUnit) || codeUnit == 0x5F;

bool _isHexUnit(final int codeUnit) =>
    _isDigit(codeUnit) ||
    (codeUnit >= 0x41 && codeUnit <= 0x46) ||
    (codeUnit >= 0x61 && codeUnit <= 0x66);

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

int _toLowerCase(final int codeUnit) =>
    codeUnit >= 0x41 && codeUnit <= 0x5A ? codeUnit + 0x20 : codeUnit;

/// First index of case-insensitive [lowercasePattern] between `from`
/// and `end`, or -1.
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

/// Last index of case-insensitive [lowercasePattern] starting between
/// `from` and `end`, or -1.
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
