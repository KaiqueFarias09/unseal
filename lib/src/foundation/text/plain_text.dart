part 'plain_text_writer.dart';

const _greaterThan = 0x3E;

/// Named entities recognized while extracting plain text.
const _namedEntities = <String, String>{
  '&nbsp;': ' ',
  '&amp;': '&',
  '&lt;': '<',
  '&gt;': '>',
  '&quot;': '"',
  '&#39;': "'",
  '&apos;': "'",
};

/// Extracts the readable plain text out of an HTML/XHTML document.
///
/// Removes `script`/`style` blocks, strips tags, decodes the common named and numeric entities and
/// collapses whitespace runs into single spaces — in a single left-to-right pass over the input,
/// bulk-copying plain text spans between markup, entities and whitespace.
///
/// Semantics carried over from the previous regex-pipeline implementation:
///
/// * markup (`<script>`/`<style>` blocks, comments and tags) becomes one collapsed space; an
///   unterminated `<` stays literal text;
/// * the seven named entities are case-sensitive and the numeric forms require their trailing `;`;
/// * entities are decoded once, after markup removal — an entity expanding to `<` (e.g. `&#60;`) is
///   text, not a tag. Double escaped sequences such as `&amp;lt;` therefore decode once and yield
///   `&lt;` (browser behaviour; the old pipeline decoded them twice).
String extractPlainText(final String html) {
  const lessThan = 0x3C;
  const ampersand = 0x26;
  final units = html.codeUnits;
  final length = units.length;
  final writer = _PlainTextWriter();
  var i = 0;
  while (i < length) {
    final codeUnit = units[i];
    if (codeUnit == lessThan) {
      final after = _consumeMarkup(units, i);
      if (after > i) {
        writer.markPendingSpace();
        i = after;
        continue;
      }
      // A lone '<' that opens no markup: one literal character.
      writer.writeUnit(codeUnit);
      i++;

      continue;
    }
    if (codeUnit == ampersand) {
      final entity = _decodeEntity(html, units, i);
      if (entity != null) {
        writer.writeDecoded(entity.$1);
        i += entity.$2;
        continue;
      }
      // An '&' that opens no known entity: one literal character.
      writer.writeUnit(codeUnit);
      i++;

      continue;
    }
    if (_isWhitespace(codeUnit)) {
      writer.markPendingSpace();
      i++;

      continue;
    }

    // Plain run: bulk-copy up to the next '<', '&' or whitespace. Runs never contain whitespace,
    // so the pending space (if any) is flushed right before them.
    var end = i + 1;
    while (end < length) {
      final next = units[end];
      if (next == lessThan || next == ampersand || _isWhitespace(next)) break;
      end++;
    }
    writer.writeText(html.substring(i, end));
    i = end;
  }
  // String.trim covers a few edge characters (e.g. U+0085) beyond the RegExp \s set collapsed
  // above, matching the previous implementation's final `.replaceAll(\s+, ' ').trim()`.

  return writer.finish();
}

/// Returns the index right after the markup starting at [start], or [start] itself when the '<'
/// opens no markup.
int _consumeMarkup(final List<int> units, final int start) {
  const commentOpen = <int>[0x21, 0x2D, 0x2D]; // !--
  const commentClose = <int>[0x2D, 0x2D, 0x3E]; // -->

  // <script ...>...</script> / <style ...>...</style>: the closing tag must match the opening name
  // case-insensitively.
  final block = _blockElementLength(units, start);
  if (block != null) return block;

  // <!-- comment -->: without a closing '-->' the comment pattern never matches and the generic tag
  // rule takes over below.
  if (_startsWith(units, start + 1, commentOpen)) {
    final close = _indexOf(units, start + 4, commentClose);
    if (close != -1) return close + commentClose.length;
  }

  // Any other tag: from '<' up to and including the first '>'.
  for (var i = start + 1; i < units.length; i++) {
    if (units[i] == _greaterThan) return i + 1;
  }

  return start;
}

/// Index right after a `<script>...</script>` / `<style>...</style>` span starting at [start], or
/// `null` when [start] opens no such block.
int? _blockElementLength(final List<int> units, final int start) {
  const scriptName = <int>[0x73, 0x63, 0x72, 0x69, 0x70, 0x74];
  const styleName = <int>[0x73, 0x74, 0x79, 0x6C, 0x65];
  const scriptClose = <int>[0x3C, 0x2F, 0x73, 0x63, 0x72, 0x69, 0x70, 0x74, 0x3E];
  const styleClose = <int>[0x3C, 0x2F, 0x73, 0x74, 0x79, 0x6C, 0x65, 0x3E];

  final isScript = _matchesName(units, start + 1, scriptName);
  if (!isScript && !_matchesName(units, start + 1, styleName)) return null;

  final name = isScript ? scriptName : styleName;
  final closing = isScript ? scriptClose : styleClose;
  final afterName = start + 1 + name.length;
  // \b: the name must not run into another word character.
  if (afterName < units.length && _isWordUnit(units[afterName])) return null;

  // Opening tag up to the first '>'; without one the pattern cannot match at all.
  var openEnd = -1;
  for (var i = afterName; i < units.length; i++) {
    if (units[i] == _greaterThan) {
      openEnd = i;
      break;
    }
  }

  if (openEnd == -1) return null;

  // Lazy search for the exact closing tag; when absent, only the opening tag is consumed as a plain
  // tag.
  final close = _indexOfIgnoreCase(units, openEnd + 1, closing);
  if (close == -1) return openEnd + 1;

  return close + closing.length;
}

bool _matchesName(final List<int> units, final int at, final List<int> lowerName) {
  if (at + lowerName.length > units.length) return false;

  for (var i = 0; i < lowerName.length; i++) {
    if (_toLowerCase(units[at + i]) != lowerName[i]) return false;
  }

  return true;
}

/// Decodes the entity starting at [start].
///
/// Returns the decoded text and the number of code units consumed, or `null` when the '&' opens no
/// known entity (literal text).
(String, int)? _decodeEntity(final String html, final List<int> units, final int start) {
  const hash = 0x23;
  const lowerX = 0x78;
  const semicolon = 0x3B;

  for (final entry in _namedEntities.entries) {
    if (html.startsWith(entry.key, start)) return (entry.value, entry.key.length);
  }

  if (start + 2 < units.length && units[start + 1] == hash) {
    final digits = start + 2;
    if (units[digits] == lowerX) {
      // &#xHH...; hexadecimal reference.
      var end = digits + 1;
      while (end < units.length && _isHexUnit(units[end])) {
        end++;
      }

      if (end > digits + 1 && end < units.length && units[end] == semicolon) {
        return (
          String.fromCharCode(int.parse(html.substring(digits + 1, end), radix: 16)),
          end + 1 - start,
        );
      }

      return null;
    }
    // &#DD...; decimal reference.
    var end = digits;
    while (end < units.length && units[end] >= 0x30 && units[end] <= 0x39) {
      end++;
    }

    if (end > digits && end < units.length && units[end] == semicolon) {
      return (String.fromCharCode(int.parse(html.substring(digits, end))), end + 1 - start);
    }
  }

  return null;
}

int _indexOfIgnoreCase(final List<int> units, final int from, final List<int> lowercasePattern) {
  for (var i = from; i + lowercasePattern.length <= units.length; i++) {
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

/// The RegExp `\s` set (ECMAScript): ASCII whitespace, NBSP, Zs category separators, line/paragraph
/// separators and ZWNBSP.
bool _isWhitespace(final int codeUnit) {
  const space = 0x20;

  return codeUnit == space ||
      (codeUnit >= 0x09 && codeUnit <= 0x0D) ||
      codeUnit == 0xA0 ||
      codeUnit == 0x1680 ||
      (codeUnit >= 0x2000 && codeUnit <= 0x200A) ||
      codeUnit == 0x2028 ||
      codeUnit == 0x2029 ||
      codeUnit == 0x202F ||
      codeUnit == 0x205F ||
      codeUnit == 0x3000 ||
      codeUnit == 0xFEFF;
}

bool _isWordUnit(final int codeUnit) {
  return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
      (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
      codeUnit == 0x5F;
}

bool _isHexUnit(final int codeUnit) {
  return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x46) ||
      (codeUnit >= 0x61 && codeUnit <= 0x66);
}

int _toLowerCase(final int codeUnit) {
  return codeUnit >= 0x41 && codeUnit <= 0x5A ? codeUnit + 0x20 : codeUnit;
}

bool _startsWith(final List<int> units, final int at, final List<int> prefix) {
  if (at < 0 || at + prefix.length > units.length) return false;

  for (var i = 0; i < prefix.length; i++) {
    if (units[at + i] != prefix[i]) return false;
  }

  return true;
}

int _indexOf(final List<int> units, final int from, final List<int> pattern) {
  for (var i = from; i + pattern.length <= units.length; i++) {
    var isMatched = true;
    for (var j = 0; j < pattern.length; j++) {
      if (units[i + j] != pattern[j]) {
        isMatched = false;
        break;
      }
    }

    if (isMatched) return i;
  }

  return -1;
}
