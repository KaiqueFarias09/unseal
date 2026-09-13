import 'dart:typed_data';

import '../exceptions/pdf_exception.dart';
import 'pdf_object.dart';

/// Maximum PDF object nesting (arrays inside dictionaries inside
/// arrays…) the parser tolerates. Real documents nest a handful of
/// levels; anything beyond this cap is hostile by construction.
const int maxPdfObjectNestingDepth = 64;

/// Parses single PDF objects out of a document's raw bytes.
///
/// The parser is offset-driven: the document reads cross-reference
/// tables, hands object byte offsets over and receives the parsed
/// object back. It never resolves indirect references itself — a
/// `num gen R` inside an array or dictionary parses into a
/// [PdfIndirectRef] and stays that way until the owning document
/// follows it. The one exception is the `/Length` entry of a stream,
/// which must be known before the stream body can be sliced; the
/// optional streamLengthOf hook answers it (and falls back to
/// scanning for `endstream` when absent or wrong).
class PdfObjectParser {
  /// Creates a parser over [bytes].
  ///
  /// [streamLengthOf] resolves a stream dictionary's `/Length` —
  /// including indirect lengths — to a byte count, or returns null
  /// when it cannot.
  PdfObjectParser(this.bytes, {final int? Function(PdfDictionary dictionary)? streamLengthOf})
    : _streamLengthOf = streamLengthOf;

  /// The document bytes.
  final Uint8List bytes;

  final int? Function(PdfDictionary dictionary)? _streamLengthOf;

  int _pos = 0;

  int _nestingDepth = 0;

  /// Reads the `num gen obj` header at [offset].
  ///
  /// Returns the object number, the generation number and the byte
  /// offset just past the `obj` keyword, or null when [offset] does
  /// not hold an object header.
  (int, int, int)? objectHeaderAt(final int offset) {
    _pos = offset;
    final number = _tryReadInt();
    if (number == null) return null;

    _skipSpace();
    final generation = _tryReadInt() ?? 0;
    _skipSpace();
    if (!_consumeKeyword('obj')) return null;

    return (number, generation, _pos);
  }

  /// Parses the object body starting at [offset].
  ///
  /// [offset] must sit on the first byte of the body (right after
  /// the `obj` keyword). A dictionary followed by the `stream`
  /// keyword parses into a [PdfStream]; everything else parses into
  /// its matching object.
  PdfObject parseAt(final int offset) {
    _pos = offset;
    final value = _parseValue();
    if (value is PdfDictionary) return _maybeStream(value);

    return value;
  }

  bool _atEnd() => _pos >= bytes.length;

  void _skipSpace() {
    while (!_atEnd()) {
      final byte = bytes[_pos];
      if (byte == 0x25) {
        // Comment: % to end of line.
        while (!_atEnd() && bytes[_pos] != 0x0A && bytes[_pos] != 0x0D) {
          _pos++;
        }
      } else if (byte == 0 ||
          byte == 0x09 ||
          byte == 0x0A ||
          byte == 0x0C ||
          byte == 0x0D ||
          byte == 0x20) {
        _pos++;
      } else {
        return;
      }
    }
  }

  /// Reads a bare keyword such as `R`, `obj`, `stream`, `endobj`,
  /// `true` — anything made of regular characters that is not a
  /// number, name, string or collection.
  String? _tryReadKeyword() {
    final start = _pos;
    while (!_atEnd() && _isRegularChar(bytes[_pos])) {
      _pos++;
    }

    return _pos == start ? null : String.fromCharCodes(bytes, start, _pos);
  }

  bool _consumeKeyword(final String keyword) {
    _skipSpace();
    final restore = _pos;
    final token = _tryReadKeyword();
    if (token == keyword) return true;

    _pos = restore;

    return false;
  }

  PdfObject _parseValue() {
    // Bounded recursion: deep arrays/dictionaries are the classic
    // stack-overflow fuzz vector, so the nesting depth is capped.
    if (++_nestingDepth > maxPdfObjectNestingDepth) {
      throw const PdfException(
        'PDF object nesting exceeds the maximum depth of '
        '$maxPdfObjectNestingDepth.',
      );
    }
    try {
      return _parseValueBounded();
    } finally {
      _nestingDepth--;
    }
  }

  PdfObject _parseValueBounded() {
    _skipSpace();
    if (_atEnd()) return const PdfNull();

    final byte = bytes[_pos];
    if (byte == 0x2F) return _parseName();
    if (byte == 0x28) return _parseLiteralString();
    if (byte == 0x3C) {
      if (_pos + 1 < bytes.length && bytes[_pos + 1] == 0x3C) return _parseDictionary();

      return _parseHexString();
    }
    if (byte == 0x5B) return _parseArray();
    if (byte == 0x2B || byte == 0x2D || byte == 0x2E || (byte >= 0x30 && byte <= 0x39)) {
      return _parseNumber();
    }

    return _parseKeywordValue();
  }

  PdfObject _parseKeywordValue() {
    final restore = _pos;
    final token = _tryReadKeyword();
    if (token == null) {
      _pos = restore + 1;

      return const PdfNull();
    }
    if (token == 'true') return const PdfBool(true);
    if (token == 'false') return const PdfBool(false);

    return const PdfNull();
  }

  PdfObject _parseNumber() {
    final start = _pos;
    while (!_atEnd()) {
      final byte = bytes[_pos];
      final isNumeric =
          (byte >= 0x30 && byte <= 0x39) || byte == 0x2B || byte == 0x2D || byte == 0x2E;
      if (!isNumeric) break;
      _pos++;
    }

    var literal = String.fromCharCodes(bytes, start, _pos);
    // PDF tolerates `4.` and `-.5`; Dart's double parser does not
    // accept a trailing dot.
    if (literal.endsWith('.')) literal = '${literal}0';
    final value = double.tryParse(literal) ?? 0;

    return PdfNumber(value);
  }

  PdfName _parseName() {
    _pos++; // leading /
    final codes = <int>[];
    while (!_atEnd() && _isRegularChar(bytes[_pos])) {
      if (bytes[_pos] == 0x23) {
        // #xx hex escape.
        final hi = _hexValue(_pos + 1 < bytes.length ? bytes[_pos + 1] : 0x30);
        final lo = _hexValue(_pos + 2 < bytes.length ? bytes[_pos + 2] : 0x30);
        if (hi != null && lo != null) {
          codes.add(hi * 16 + lo);
          _pos += 3;
          continue;
        }
      }
      codes.add(bytes[_pos]);
      _pos++;
    }

    return PdfName(String.fromCharCodes(codes));
  }

  PdfString _parseLiteralString() {
    _pos++; // (
    final out = BytesBuilder(copy: false);
    var depth = 1;
    while (!_atEnd() && depth > 0) {
      final byte = bytes[_pos];
      if (byte == 0x5C) {
        _pos++;
        if (_atEnd()) break;

        final escape = bytes[_pos];
        switch (escape) {
          case 0x6E:
            out.addByte(0x0A);
            _pos++;
          case 0x72:
            out.addByte(0x0D);
            _pos++;
          case 0x74:
            out.addByte(0x09);
            _pos++;
          case 0x62:
            out.addByte(0x08);
            _pos++;
          case 0x66:
            out.addByte(0x0C);
            _pos++;
          case 0x28:
            out.addByte(0x28);
            _pos++;
          case 0x29:
            out.addByte(0x29);
            _pos++;
          case 0x5C:
            out.addByte(0x5C);
            _pos++;
          case 0x0D:
            // Line continuation: \<EOL> (and \<CR><LF>) emits nothing.
            _pos++;
            if (!_atEnd() && bytes[_pos] == 0x0A) _pos++;
          case 0x0A:
            _pos++;
          default:
            if (escape >= 0x30 && escape <= 0x37) {
              var octal = escape - 0x30;
              _pos++;
              for (var digit = 0; digit < 2 && !_atEnd(); digit++) {
                final next = bytes[_pos];
                if (next < 0x30 || next > 0x37) break;

                octal = octal * 8 + (next - 0x30);
                _pos++;
              }
              out.addByte(octal & 0xFF);
            } else {
              // Unknown escape stands for the character itself.
              out.addByte(escape);
              _pos++;
            }
        }

        continue;
      }
      if (byte == 0x28) depth++;
      if (byte == 0x29) {
        depth--;

        if (depth == 0) {
          _pos++;

          break;
        }
      }
      out.addByte(byte);
      _pos++;
    }

    return PdfString(out.toBytes());
  }

  PdfString _parseHexString() {
    _pos++; // <
    final out = BytesBuilder(copy: false);
    var pending = -1;
    while (!_atEnd()) {
      final byte = bytes[_pos];
      _pos++;
      if (byte == 0x3E) break;
      if (byte == 0 ||
          byte == 0x09 ||
          byte == 0x0A ||
          byte == 0x0C ||
          byte == 0x0D ||
          byte == 0x20) {
        continue;
      }

      final value = _hexValue(byte);
      if (value == null) continue;
      if (pending < 0) {
        pending = value;
        continue;
      }

      out.addByte(pending * 16 + value);
      pending = -1;
    }
    if (pending >= 0) out.addByte(pending * 16);

    return PdfString(out.toBytes());
  }

  PdfArray _parseArray() {
    _pos++; // [
    final items = <PdfObject>[];
    while (true) {
      _skipSpace();
      if (_atEnd()) break;
      if (bytes[_pos] == 0x5D) {
        _pos++;

        break;
      }

      final value = _parseValue();
      if (value is PdfNumber) {
        final reference = _maybeIndirectRef(value);
        items.add(reference ?? value);
        continue;
      }

      items.add(value);
    }

    return PdfArray(items);
  }

  PdfDictionary _parseDictionary() {
    _pos += 2; // <<
    final entries = <String, PdfObject>{};
    while (true) {
      _skipSpace();
      if (_atEnd()) break;
      if (bytes[_pos] == 0x3E && _pos + 1 < bytes.length && bytes[_pos + 1] == 0x3E) {
        _pos += 2;
        break;
      }
      if (bytes[_pos] != 0x2F) {
        // Not a key: skip the stray byte and keep going.
        _pos++;

        continue;
      }

      final key = _parseName();
      _skipSpace();
      if (_atEnd()) break;

      final value = _parseValue();
      entries[key.value] = value is PdfNumber ? (_maybeIndirectRef(value) ?? value) : value;
    }

    return PdfDictionary(entries);
  }

  /// After a first number, tries to consume `gen R` and return the
  /// reference; restores the position when the lookahead fails.
  PdfObject? _maybeIndirectRef(final PdfNumber first) {
    final restore = _pos;
    _skipSpace();
    final generation = _tryReadInt();
    if (generation == null) {
      _pos = restore;

      return null;
    }

    _skipSpace();
    final token = _tryReadKeyword();
    if (token == 'R') return PdfIndirectRef(first.intValue, generation);

    _pos = restore;

    return null;
  }

  int? _tryReadInt() {
    final start = _pos;
    while (!_atEnd()) {
      final byte = bytes[_pos];
      if (byte < 0x30 || byte > 0x39) break;
      _pos++;
    }

    if (_pos == start) return null;

    return int.tryParse(String.fromCharCodes(bytes, start, _pos));
  }

  PdfObject _maybeStream(final PdfDictionary dictionary) {
    final restore = _pos;
    _skipSpace();
    final token = _tryReadKeyword();
    if (token != 'stream') {
      _pos = restore;

      return dictionary;
    }
    // Exactly one EOL (\r\n, \n or \r) follows the keyword.
    if (!_atEnd() && bytes[_pos] == 0x0D) _pos++;
    if (!_atEnd() && bytes[_pos] == 0x0A) _pos++;

    final declared = _streamLengthOf?.call(dictionary);
    var end = -1;
    if (declared != null && declared >= 0 && _pos + declared <= bytes.length) {
      // Trust the declared length when the bytes just past it lead
      // into `endstream` (tolerating stray EOLs); otherwise scan.
      var probe = _pos + declared;
      while (probe < bytes.length && (bytes[probe] == 0x0D || bytes[probe] == 0x0A)) {
        probe++;
      }
      if (_keywordAt(probe, 'endstream')) end = _pos + declared;
    }
    if (end < 0) end = _scanEndstream(_pos);

    final body = end < 0
        ? Uint8List.sublistView(bytes, _pos, bytes.length)
        : Uint8List.sublistView(bytes, _pos, end);

    return PdfStream(dictionary, body);
  }

  int _scanEndstream(final int from) {
    // Search for the next `endstream` keyword; the stream data ends
    // before its trailing EOL.
    for (var pos = from; pos + 9 <= bytes.length; pos++) {
      if (!_keywordAt(pos, 'endstream')) continue;

      var end = pos;
      while (end > from && (bytes[end - 1] == 0x0D || bytes[end - 1] == 0x0A)) {
        end--;
      }

      return end;
    }

    return -1;
  }

  bool _keywordAt(final int offset, final String keyword) {
    if (offset + keyword.length > bytes.length) return false;

    for (var i = 0; i < keyword.length; i++) {
      if (bytes[offset + i] != keyword.codeUnitAt(i)) return false;
    }

    return true;
  }

  int? _hexValue(final int byte) {
    if (byte >= 0x30 && byte <= 0x39) return byte - 0x30;
    if (byte >= 0x41 && byte <= 0x46) return byte - 0x41 + 10;
    if (byte >= 0x61 && byte <= 0x66) return byte - 0x61 + 10;

    return null;
  }
}

bool _isRegularChar(final int byte) {
  const delimiters = 0x28; // (
  return byte != 0 &&
      byte != 0x09 &&
      byte != 0x0A &&
      byte != 0x0C &&
      byte != 0x0D &&
      byte != 0x20 &&
      byte != delimiters &&
      byte != 0x29 && // )
      byte != 0x3C && // <
      byte != 0x3E && // >
      byte != 0x5B && // [
      byte != 0x5D && // ]
      byte != 0x7B && // {
      byte != 0x7D && // }
      byte != 0x2F && // /
      byte != 0x25; // %
}
