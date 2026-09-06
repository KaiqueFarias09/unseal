import 'dart:typed_data';

/// A parsed CMap: character code to Unicode string (ToUnicode) and
/// character code to CID (embedded `/Encoding` CMaps of Type0 fonts).
///
/// Reads the `begincodespacerange` / `beginbfchar` / `beginbfrange`
/// blocks of a ToUnicode stream (PDF 32000-1:2008 §9.10.3), all
/// three `bfrange` destination forms (single base value, per-code
/// array, and the plain range form), plus the `begincidrange` block
/// (§9.7.4.2) that maps codes onto CIDs. The byte width a code
/// occupies comes from the code space; `Identity-*` CMaps without a
/// code space fall back to 2 bytes.
class PdfCMap {
  /// Parses a CMap [program] (the decoded stream text).
  factory PdfCMap.parse(final String program) {
    var codeBytes = 2;
    final map = <int, String>{};
    final cids = <int, int>{};
    final tokens = _tokenize(program);
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (token is! _Keyword) continue;
      switch (token.text) {
        case 'begincodespacerange':
          final count = _intBefore(tokens, i);
          var cursor = i + 1;
          var seen = 0;
          while (cursor + 1 < tokens.length && seen < (count ?? 1)) {
            final low = tokens[cursor];
            final high = tokens[cursor + 1];
            if (low is _Hex && high is _Hex) {
              codeBytes = low.bytes.length;
              seen++;
              cursor += 2;
            } else {
              break;
            }
          }
        case 'begincidrange':
          final count = _intBefore(tokens, i) ?? 0;
          var cursor = i + 1;
          var seen = 0;
          while (cursor + 2 < tokens.length && seen < count) {
            final low = tokens[cursor];
            final high = tokens[cursor + 1];
            final base = tokens[cursor + 2];
            if (low is _Hex && high is _Hex && base is _Int) {
              final start = _codeOf(low.bytes);
              final end = _codeOf(high.bytes);
              if (end >= start && end - start <= 65535) {
                for (var code = start; code <= end; code++) {
                  cids[code] = base.value + code - start;
                }
              }
              seen++;
              cursor += 3;
            } else {
              break;
            }
          }
        case 'beginbfchar':
          final count = _intBefore(tokens, i) ?? 0;
          var cursor = i + 1;
          var seen = 0;
          while (cursor + 1 < tokens.length && seen < count) {
            final source = tokens[cursor];
            final destination = tokens[cursor + 1];
            if (source is _Hex && destination is _Hex) {
              _addRange(map, _codeOf(source.bytes), _codeOf(source.bytes), [destination.bytes]);
              seen++;
              cursor += 2;
            } else if (source is _Hex) {
              cursor += 1;
            } else {
              break;
            }
          }
        case 'beginbfrange':
          var cursor = i + 1;
          final count = _intBefore(tokens, i) ?? 0;
          var seen = 0;
          while (cursor + 2 < tokens.length && seen < count) {
            final low = tokens[cursor];
            final high = tokens[cursor + 1];
            final destination = tokens[cursor + 2];
            if (low is _Hex && high is _Hex && destination is _Hex) {
              _addRange(map, _codeOf(low.bytes), _codeOf(high.bytes), [destination.bytes]);
              seen++;
              cursor += 3;
            } else if (low is _Hex && high is _Hex && destination is _ArrayStart) {
              // Array destination form: one hex value per code.
              final values = <Uint8List>[];
              var scan = cursor + 2;
              while (scan < tokens.length && tokens[scan] is! _ArrayEnd) {
                final entry = tokens[scan];
                if (entry is _Hex) values.add(entry.bytes);
                scan++;
              }
              _addRange(map, _codeOf(low.bytes), _codeOf(high.bytes), values);
              seen++;
              cursor = scan + 1;
            } else {
              break;
            }
          }
      }
    }

    return PdfCMap._(codeBytes, map, cids);
  }

  const PdfCMap._(this.codeBytes, this.map, this.cidMap);

  /// Bytes per character code (1, 2 or 4).
  final int codeBytes;

  /// Character code to Unicode string.
  final Map<int, String> map;

  /// Character code to CID (from a `begincidrange` block, as found in
  /// the embedded `/Encoding` CMap of a Type0 font); empty when the
  /// program carries none.
  final Map<int, int> cidMap;

  /// Reads the [codeBytes] code starting at [offset] in [bytes];
  /// null when the buffer ends mid-code.
  int? codeAt(final Uint8List bytes, final int offset) {
    if (offset + codeBytes > bytes.length) return null;
    var value = 0;
    for (var i = 0; i < codeBytes; i++) {
      value = value * 256 + bytes[offset + i];
    }

    return value;
  }

  /// The Unicode string for [code], or null when unmapped.
  String? unicodeOf(final int code) => map[code];
}

int? _intBefore(final List<_Token> tokens, final int operatorIndex) {
  for (var i = operatorIndex - 1; i >= 0; i--) {
    if (tokens[i] is _Int) return (tokens[i] as _Int).value;
  }

  return null;
}

int _codeOf(final Uint8List hex) {
  var value = 0;
  for (final byte in hex) {
    value = value * 256 + byte;
  }

  return value;
}

void _addRange(
  final Map<int, String> map,
  final int low,
  final int high,
  final List<Uint8List> values,
) {
  if (high < low || high - low > 65535) return;
  for (var code = low; code <= high; code++) {
    final index = code - low;
    final bytes = values.length == 1 ? values[0] : (index < values.length ? values[index] : null);
    if (bytes == null) continue;
    map[code] = _utf16Of(bytes);
  }
}

/// Destination hex strings are UTF-16BE; odd-length tails read as if
/// padded (lenient, matching Poppler's tolerance).
String _utf16Of(final Uint8List bytes) {
  if (bytes.length == 1) return String.fromCharCode(bytes[0]);
  final codes = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    codes.add(bytes[i] * 256 + bytes[i + 1]);
  }

  return String.fromCharCodes(codes);
}

List<_Token> _tokenize(final String program) {
  final tokens = <_Token>[];
  final bytes = program.codeUnits;
  var i = 0;
  while (i < bytes.length) {
    final char = bytes[i];
    if (char == 0x25) {
      // % comment to end of line.
      while (i < bytes.length && bytes[i] != 0x0A && bytes[i] != 0x0D) {
        i++;
      }
      continue;
    }
    if (char == 0x20 || char == 0x09 || char == 0x0A || char == 0x0D) {
      i++;
      continue;
    }
    if (char == 0x3C) {
      // <hex> or <<.
      if (i + 1 < bytes.length && bytes[i + 1] == 0x3C) {
        tokens.add(const _Keyword('<<'));
        i += 2;
        continue;
      }
      var end = program.indexOf('>', i);
      if (end < 0) end = bytes.length;
      tokens.add(_Hex(_decodeHex(program.substring(i + 1, end))));
      i = end + 1;
      continue;
    }
    if (char == 0x3E) {
      tokens.add(const _Keyword('>>'));
      i += 2;
      continue;
    }
    if (char == 0x5B) {
      tokens.add(const _ArrayStart());
      i++;
      continue;
    }
    if (char == 0x5D) {
      tokens.add(const _ArrayEnd());
      i++;
      continue;
    }
    if (char == 0x2F) {
      var end = i + 1;
      while (end < bytes.length && _isRegular(bytes[end])) {
        end++;
      }
      tokens.add(_Keyword(program.substring(i + 1, end)));
      i = end;
      continue;
    }
    var end = i;
    while (end < bytes.length && _isRegular(bytes[end])) {
      end++;
    }
    if (end == i) {
      i++;
      continue;
    }
    final text = program.substring(i, end);
    final value = int.tryParse(text);
    if (value != null) {
      tokens.add(_Int(value));
    } else {
      tokens.add(_Keyword(text));
    }
    i = end;
  }

  return tokens;
}

bool _isRegular(final int char) =>
    char != 0x20 &&
    char != 0x09 &&
    char != 0x0A &&
    char != 0x0D &&
    char != 0x3C &&
    char != 0x3E &&
    char != 0x5B &&
    char != 0x5D &&
    char != 0x2F &&
    char != 0x28 &&
    char != 0x29 &&
    char != 0x25;

Uint8List _decodeHex(final String hex) {
  final digits = <int>[];
  for (final char in hex.codeUnits) {
    var value = -1;
    if (char >= 0x30 && char <= 0x39) {
      value = char - 0x30;
    } else if (char >= 0x41 && char <= 0x46) {
      value = char - 0x41 + 10;
    } else if (char >= 0x61 && char <= 0x66) {
      value = char - 0x61 + 10;
    } else {
      continue;
    }
    digits.add(value);
  }
  if (digits.length.isOdd) digits.add(0);
  final out = Uint8List(digits.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = digits[i * 2] * 16 + digits[i * 2 + 1];
  }

  return out;
}

sealed class _Token {
  const _Token();
}

final class _Keyword extends _Token {
  const _Keyword(this.text);

  final String text;
}

final class _Int extends _Token {
  const _Int(this.value);

  final int value;
}

final class _Hex extends _Token {
  const _Hex(this.bytes);

  final Uint8List bytes;
}

final class _ArrayStart extends _Token {
  const _ArrayStart();
}

final class _ArrayEnd extends _Token {
  const _ArrayEnd();
}
