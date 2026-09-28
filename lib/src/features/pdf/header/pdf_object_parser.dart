import 'dart:typed_data';

import '../exceptions/pdf_exception.dart';
import '../reader/pdf_byte_source.dart';
import 'pdf_object.dart';

/// Maximum PDF object nesting (arrays inside dictionaries inside
/// arrays…) the parser tolerates. Real documents nest a handful of
/// levels; anything beyond this cap is hostile by construction.
const int maxPdfObjectNestingDepth = 64;

/// Read-window size for file-backed sources: one bounded read per
/// refill, never a syscall per byte. Memory-backed sources hand out
/// views, so their single upfront window costs nothing.
const int _pdfParseWindowBytes = 64 * 1024;

/// Parses single PDF objects out of a document's random-access byte
/// source.
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
///
/// Reads go through a sliding window ([PdfByteSource.read] per
/// refill), so a file-backed source never gets read byte-by-byte and
/// never lands in memory whole; a memory-backed source is read once
/// as a zero-copy view and every access stays a direct index.
class PdfObjectParser {
  /// Creates a parser over [source].
  ///
  /// [streamLengthOf] resolves a stream dictionary's `/Length` —
  /// including indirect lengths — to a byte count, or returns null
  /// when it cannot.
  PdfObjectParser(this.source, {final int? Function(PdfDictionary dictionary)? streamLengthOf})
    : _streamLengthOf = streamLengthOf {
    final memory = source is MemoryPdfByteSource ? source as MemoryPdfByteSource : null;
    if (memory != null) {
      _window = memory.read(0, memory.length);
      _windowEnd = _window.length;
    }
  }

  /// The document source.
  final PdfByteSource source;

  final int? Function(PdfDictionary dictionary)? _streamLengthOf;

  /// Total source length in bytes.
  int get byteLength => source.length;

  Uint8List _window = Uint8List(0);

  /// Absolute offset of `_window[0]`; the window covers
  /// `[_windowStart, _windowEnd)`.
  int _windowStart = 0;

  int _windowEnd = 0;

  int _pos = 0;

  int _nestingDepth = 0;

  /// Makes the bytes `[pos, pos + count)` — clamped to the source
  /// end — resident in the read window. File-backed sources pay one
  /// bounded read per refill; memory-backed sources never refill.
  void _ensure(final int pos, final int count) {
    if (pos >= _windowStart && pos + count <= _windowEnd) return;
    if (pos < 0 || pos >= byteLength) return;

    var size = byteLength - pos;
    if (size > _pdfParseWindowBytes) size = _pdfParseWindowBytes;
    if (size < count) size = count;
    _window = source.read(pos, size);
    _windowStart = pos;
    _windowEnd = pos + size;
  }

  /// Makes an already-scanned `[start, end)` token range resident so
  /// it can be materialized as a string; a token that crossed a
  /// window boundary is re-read once, whole.
  void _ensureRange(final int start, final int end) {
    _ensure(start, end - start);
  }

  /// The byte at absolute [offset], refilling the window when needed.
  int byteAt(final int offset) {
    _ensure(offset, 1);

    return _window[offset - _windowStart];
  }

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

  /// Whether the keyword sits at absolute [offset].
  bool keywordAt(final int offset, final String keyword) {
    if (offset < 0 || offset + keyword.length > byteLength) return false;

    _ensure(offset, keyword.length);
    final base = offset - _windowStart;
    for (var i = 0; i < keyword.length; i++) {
      if (_window[base + i] != keyword.codeUnitAt(i)) return false;
    }

    return true;
  }

  /// The first position of [keyword] at or after [from], or -1.
  int findKeyword(final String keyword, final int from) {
    for (var pos = from; pos + keyword.length <= byteLength; pos++) {
      if (keywordAt(pos, keyword)) return pos;
    }

    return -1;
  }

  /// Skips the PDF whitespace bytes at and after [pos] — comment
  /// lines stay untouched (unlike [_skipSpace], which the object
  /// grammar uses).
  int skipWhitespaceAt(int pos) {
    while (pos < byteLength) {
      final byte = byteAt(pos);
      if (byte == 0 ||
          byte == 0x09 ||
          byte == 0x0A ||
          byte == 0x0C ||
          byte == 0x0D ||
          byte == 0x20) {
        pos++;

        continue;
      }

      break;
    }

    return pos;
  }

  /// The decimal integer at [pos], or null when no digits start
  /// there (or the run overflows a 64-bit int).
  int? readIntAt(final int pos) {
    final end = intEndAt(pos);
    if (end == pos) return null;

    _ensureRange(pos, end);

    return int.tryParse(String.fromCharCodes(_window, pos - _windowStart, end - _windowStart));
  }

  /// The end of the digit run starting at [pos].
  int intEndAt(final int pos) {
    var end = pos;
    while (end < byteLength) {
      final byte = byteAt(end);
      if (byte < 0x30 || byte > 0x39) break;
      end++;
    }

    return end;
  }

  bool _atEnd() => _pos >= byteLength;

  void _skipSpace() {
    while (!_atEnd()) {
      final byte = byteAt(_pos);
      if (byte == 0x25) {
        // Comment: % to end of line.
        while (!_atEnd() && byteAt(_pos) != 0x0A && byteAt(_pos) != 0x0D) {
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
    while (!_atEnd() && _isRegularChar(byteAt(_pos))) {
      _pos++;
    }

    if (_pos == start) return null;

    _ensureRange(start, _pos);

    return String.fromCharCodes(_window, start - _windowStart, _pos - _windowStart);
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

    final byte = byteAt(_pos);
    if (byte == 0x2F) return _parseName();
    if (byte == 0x28) return _parseLiteralString();
    if (byte == 0x3C) {
      if (_pos + 1 < byteLength && byteAt(_pos + 1) == 0x3C) return _parseDictionary();

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
      final byte = byteAt(_pos);
      final isNumeric =
          (byte >= 0x30 && byte <= 0x39) || byte == 0x2B || byte == 0x2D || byte == 0x2E;
      if (!isNumeric) break;
      _pos++;
    }

    _ensureRange(start, _pos);
    var literal = String.fromCharCodes(_window, start - _windowStart, _pos - _windowStart);
    // PDF tolerates `4.` and `-.5`; Dart's double parser does not
    // accept a trailing dot.
    if (literal.endsWith('.')) literal = '${literal}0';
    final value = double.tryParse(literal) ?? 0;

    return PdfNumber(value);
  }

  PdfName _parseName() {
    _pos++; // leading /
    final codes = <int>[];
    while (!_atEnd() && _isRegularChar(byteAt(_pos))) {
      if (byteAt(_pos) == 0x23) {
        // #xx hex escape.
        final hi = _hexValue(_pos + 1 < byteLength ? byteAt(_pos + 1) : 0x30);
        final lo = _hexValue(_pos + 2 < byteLength ? byteAt(_pos + 2) : 0x30);
        if (hi != null && lo != null) {
          codes.add(hi * 16 + lo);
          _pos += 3;
          continue;
        }
      }
      codes.add(byteAt(_pos));
      _pos++;
    }

    return PdfName(String.fromCharCodes(codes));
  }

  PdfString _parseLiteralString() {
    _pos++; // (
    final out = BytesBuilder(copy: false);
    var depth = 1;
    while (!_atEnd() && depth > 0) {
      final byte = byteAt(_pos);
      if (byte == 0x5C) {
        _pos++;
        if (_atEnd()) break;

        final escape = byteAt(_pos);
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
            if (!_atEnd() && byteAt(_pos) == 0x0A) _pos++;
          case 0x0A:
            _pos++;
          default:
            if (escape >= 0x30 && escape <= 0x37) {
              var octal = escape - 0x30;
              _pos++;
              for (var digit = 0; digit < 2 && !_atEnd(); digit++) {
                final next = byteAt(_pos);
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
      final byte = byteAt(_pos);
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
      if (byteAt(_pos) == 0x5D) {
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
      if (byteAt(_pos) == 0x3E && _pos + 1 < byteLength && byteAt(_pos + 1) == 0x3E) {
        _pos += 2;
        break;
      }
      if (byteAt(_pos) != 0x2F) {
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
      final byte = byteAt(_pos);
      if (byte < 0x30 || byte > 0x39) break;
      _pos++;
    }

    if (_pos == start) return null;

    _ensureRange(start, _pos);

    return int.tryParse(String.fromCharCodes(_window, start - _windowStart, _pos - _windowStart));
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
    if (!_atEnd() && byteAt(_pos) == 0x0D) _pos++;
    if (!_atEnd() && byteAt(_pos) == 0x0A) _pos++;

    final declared = _streamLengthOf?.call(dictionary);
    var end = -1;
    if (declared != null && declared >= 0 && _pos + declared <= byteLength) {
      // Trust the declared length when the bytes just past it lead
      // into `endstream` (tolerating stray EOLs); otherwise scan.
      var probe = _pos + declared;
      while (probe < byteLength && (byteAt(probe) == 0x0D || byteAt(probe) == 0x0A)) {
        probe++;
      }
      if (_keywordAt(probe, 'endstream')) end = _pos + declared;
    }
    if (end < 0) end = _scanEndstream(_pos);

    // One bounded read for the whole body — a view for memory-backed
    // sources, a single slice for file-backed ones.
    final body = end < 0 ? source.read(_pos, byteLength - _pos) : source.read(_pos, end - _pos);

    return PdfStream(dictionary, body);
  }

  int _scanEndstream(final int from) {
    // Search for the next `endstream` keyword; the stream data ends
    // before its trailing EOL.
    for (var pos = from; pos + 9 <= byteLength; pos++) {
      if (!_keywordAt(pos, 'endstream')) continue;

      var end = pos;
      while (end > from && (byteAt(end - 1) == 0x0D || byteAt(end - 1) == 0x0A)) {
        end--;
      }

      return end;
    }

    return -1;
  }

  bool _keywordAt(final int offset, final String keyword) => keywordAt(offset, keyword);

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
