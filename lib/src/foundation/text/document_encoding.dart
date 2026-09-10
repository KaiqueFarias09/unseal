import 'dart:convert' as convert;
import 'dart:typed_data';

/// Escapes untrusted document text before placing it in generated XHTML.
String escapeHtml(final String value) => const convert.HtmlEscape().convert(value);

/// Decodes a text document using the BOM and common Unicode signatures.
///
/// The parser is deliberately conservative: UTF-8 is the default and malformed sequences are
/// replaced rather than making a readable book disappear because of one bad byte.
String decodeDocumentText(final List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  if (_startsWith(data, const [0xff, 0xfe, 0x00, 0x00]) ||
      _startsWith(data, const [0x00, 0x00, 0xfe, 0xff])) {
    throw const FormatException('UTF-32 document resources are not supported.');
  }
  if (_startsWith(data, const [0xff, 0xfe])) return _decodeUtf16(data, 2, true);
  if (_startsWith(data, const [0xfe, 0xff])) return _decodeUtf16(data, 2, false);

  if (_startsWith(data, const [0x3c, 0x00, 0x3f, 0x00]) ||
      _startsWith(data, const [0x3c, 0x00, 0x68, 0x00])) {
    return _decodeUtf16(data, 0, true);
  }

  if (_startsWith(data, const [0x00, 0x3c, 0x00, 0x3f]) ||
      _startsWith(data, const [0x00, 0x3c, 0x00, 0x68])) {
    return _decodeUtf16(data, 0, false);
  }

  final offset = _startsWith(data, const [0xef, 0xbb, 0xbf]) ? 3 : 0;
  return convert.utf8.decode(data.sublist(offset), allowMalformed: true);
}

String _decodeUtf16(final Uint8List data, final int offset, final bool littleEndian) {
  final length = data.length - offset;
  if (length.isOdd) throw const FormatException('Truncated UTF-16 document resource.');

  final units = <int>[];
  for (var index = offset; index < data.length; index += 2) {
    final first = data[index];
    final second = data[index + 1];
    units.add(littleEndian ? first | second << 8 : first << 8 | second);
  }

  return String.fromCharCodes(units);
}

bool _startsWith(final Uint8List data, final List<int> prefix) {
  if (data.length < prefix.length) return false;

  for (var index = 0; index < prefix.length; index++) {
    if (data[index] != prefix[index]) return false;
  }

  return true;
}
