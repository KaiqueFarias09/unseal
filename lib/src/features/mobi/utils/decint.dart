import 'dart:convert' as convert;
import 'dart:typed_data';

/// Reads a forward-encoded variable width integer from [raw].
///
/// MOBI var-width integers are big-endian with 7 bits per byte; the
/// first byte carries the continuation (high) bit for forward-encoded
/// values. Returns the value and the number of bytes consumed.
(int, int) decint(final Uint8List raw, [final int start = 0]) {
  var value = 0;
  var consumed = 0;
  for (var i = start; i < raw.length; i++) {
    final byte = raw[i];
    value = (value << 7) | (byte & 0x7F);
    consumed++;
    if (byte & 0x80 != 0) {
      break;
    }
  }
  return (value, consumed);
}

/// Decodes a length-prefixed string as used by INDX records.
///
/// The first byte holds the length, followed by that many bytes
/// decoded with [codec]. Returns the string and bytes consumed.
(String, int) decodeIndexString(
  final Uint8List raw,
  final String codec, [
  final int start = 0,
]) {
  if (start >= raw.length) {
    return ('', 0);
  }
  final length = raw[start];
  final end = start + 1 + length;
  final bytes = raw.sublist(start + 1, end > raw.length ? raw.length : end);
  final consumed = 1 + length;
  final ordtDecoded = codec == 'ordt';
  if (ordtDecoded) {
    // ORDT entries map through the '?' fallback table; every byte
    // becomes '?' when unknown — approximate with '?' per byte pair
    // semantics by returning a printable-char projection.
    return (
      String.fromCharCodes(bytes.where((final b) => b > 0x20 && b < 0x7F)),
      consumed,
    );
  }
  return (decodeBytes(bytes, codec), consumed);
}

/// Decodes [bytes] with the given MOBI text codec
/// (`utf-8` or `cp1252`), replacing invalid sequences.
String decodeBytes(final Uint8List bytes, final String codec) {
  if (codec == 'utf-8') {
    return convert.utf8.decode(bytes, allowMalformed: true);
  }
  return _cp1252(bytes);
}

/// cp1252 code unit for each byte value; the 0x80..0x9F range maps to
/// its Windows punctuation, everything else is Latin-1 identity.
final List<int> _cp1252CodeUnits = List<int>.generate(256, (final byte) {
  const high = <int, String>{
    0x80: '\u20AC',
    0x82: '\u201A',
    0x83: '\u0192',
    0x84: '\u201E',
    0x85: '\u2026',
    0x86: '\u2020',
    0x87: '\u2021',
    0x88: '\u02C6',
    0x89: '\u2030',
    0x8A: '\u0160',
    0x8B: '\u2039',
    0x8C: '\u0152',
    0x8E: '\u017D',
    0x91: '\u2018',
    0x92: '\u2019',
    0x93: '\u201C',
    0x94: '\u201D',
    0x95: '\u2022',
    0x96: '\u2013',
    0x97: '\u2014',
    0x98: '\u02DC',
    0x99: '\u2122',
    0x9A: '\u0161',
    0x9B: '\u203A',
    0x9C: '\u0153',
    0x9E: '\u017E',
    0x9F: '\u0178',
  };
  final mapped = high[byte];
  if (mapped != null) {
    return mapped.codeUnitAt(0);
  }
  // 0x81, 0x8D, 0x8F, 0x90 and 0x9D are undefined in cp1252.
  return byte >= 0x80 && byte <= 0x9F ? 0x3F : byte;
});

String _cp1252(final Uint8List bytes) {
  final codeUnits = List<int>.generate(
    bytes.length,
    (final i) => _cp1252CodeUnits[bytes[i]],
  );
  return String.fromCharCodes(codeUnits);
}

/// Counts the number of set bits in [value].
int countSetBits(int value) {
  var count = 0;
  while (value > 0) {
    count += value & 1;
    value >>= 1;
  }
  return count;
}

/// Converts a base-32 (Kindle digit set `0-9 A-V`) string to an integer.
int parseBase32(final String raw) => int.parse(raw, radix: 32);
