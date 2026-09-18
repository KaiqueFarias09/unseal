/// XML/HTML text-encoding detection and lenient byte decoding.
///
/// The policy for detecting and decoding XML/HTML text is:
///
/// 1. a byte order mark wins over anything else;
/// 2. a declared encoding in the first 50 KiB (`<?xml ... ?>` or an HTML `<meta charset>`/`<meta
///    content>` hint) is honored as written, even when the declaration is wrong;
/// 3. with no supported declaration, the bytes are tried as strict UTF-8 first;
/// 4. otherwise a lightweight byte-scored detection picks between the legacy single-byte families
///    that matter for ebooks: windows-1251 (Cyrillic), windows-1256 (Arabic) and the
///    windows-1252/latin-1 Western default.
///
/// Decoding never throws: undecodable bytes become U+FFFD replacement characters.
///
/// Full detection for CJK and other multibyte encodings, KOI8-R, ISO-8859-5, and similar formats is
/// out of scope. Unsupported input follows the undeclared-encoding policy.
library;

import 'dart:convert' as convert;
import 'dart:math' as math;
import 'dart:typed_data';

part 'xml_encoding_tables.dart';

/// Declarations this decoder can honour, keyed by the normalized encoding name. Unsupported
/// declarations fall back to the undeclared policy.
const _declaredEncodings = <String, XmlEncoding>{
  'utf8': XmlEncoding.utf8,
  'utf16': XmlEncoding.utf16le,
  'utf16le': XmlEncoding.utf16le,
  'utf16be': XmlEncoding.utf16be,
  'utf32': XmlEncoding.utf32le,
  'utf32le': XmlEncoding.utf32le,
  'utf32be': XmlEncoding.utf32be,
  'ascii': XmlEncoding.ascii,
  'usascii': XmlEncoding.ascii,
  'ansix341968': XmlEncoding.ascii,
  'ansix341986': XmlEncoding.ascii,
  'iso646us': XmlEncoding.ascii,
  'csascii': XmlEncoding.ascii,
  'cp367': XmlEncoding.ascii,
  'latin1': XmlEncoding.latin1,
  'l1': XmlEncoding.latin1,
  'iso88591': XmlEncoding.latin1,
  'iso885911987': XmlEncoding.latin1,
  'cp819': XmlEncoding.latin1,
  'ibm819': XmlEncoding.latin1,
  'csisolatin1': XmlEncoding.latin1,
  'isoir100': XmlEncoding.latin1,
  'windows1252': XmlEncoding.cp1252,
  'cp1252': XmlEncoding.cp1252,
  'xcp1252': XmlEncoding.cp1252,
  'windows1251': XmlEncoding.cp1251,
  'cp1251': XmlEncoding.cp1251,
  'xcp1251': XmlEncoding.cp1251,
  'windows1256': XmlEncoding.cp1256,
  'cp1256': XmlEncoding.cp1256,
  'xcp1256': XmlEncoding.cp1256,
};

/// How many bytes feed the legacy single-byte detection. Language identification needs far less
/// than this; the cap only bounds the cost on very large documents.
const _detectionWindowBytes = 256 * 1024;

/// U+FFFD, the replacement character emitted for undecodable bytes.
const _replacementRune = 0xFFFD;

/// The text encodings this library can decode XML/HTML bytes with.
///
/// `utf16le`/`utf16be`/`utf32le`/`utf32be` only arise from byte order marks (or a declaration
/// naming them); the single-byte Windows codepages additionally back the legacy detection
/// heuristics.
enum XmlEncoding {
  /// US-ASCII; bytes above 0x7F decode to U+FFFD.
  ascii,

  /// ISO-8859-1; every byte value maps to the same code point.
  latin1,

  /// Windows-1252 (Western European), the Western fallback.
  cp1252,

  /// Windows-1251 (Cyrillic).
  cp1251,

  /// Windows-1256 (Arabic).
  cp1256,

  /// UTF-8; malformed sequences decode to U+FFFD.
  utf8,

  /// UTF-16 little-endian.
  utf16le,

  /// UTF-16 big-endian.
  utf16be,

  /// UTF-32 little-endian.
  utf32le,

  /// UTF-32 big-endian.
  utf32be,
}

/// Detects the text encoding of an XML (or HTML) document.
///
/// See the library documentation for the policy. Never throws; the returned encoding always
/// produces a replacement-decoded string via [decodeXmlTextAs].
XmlEncoding sniffXmlEncoding(final List<int> bytes) {
  final typed = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final bom = _bomEncoding(typed);
  if (bom != null) return bom;

  final declared = _declaredEncodingName(typed);
  if (declared == null) return _sniffUndeclared(typed);

  final known = _declaredEncodings[_normalizeEncodingName(declared)];
  if (known != null) return known;

  // An unsupported declaration degrades to the undeclared policy instead of raising an error.

  return _sniffUndeclared(typed);
}

/// Decodes [bytes] with the encoding [sniffXmlEncoding] picks.
///
/// Never throws; malformed bytes become U+FFFD. A leading U+FEFF (byte order mark) is stripped from
/// the result.
String decodeXmlText(final List<int> bytes) => decodeXmlTextAs(bytes, sniffXmlEncoding(bytes));

/// Decodes [bytes] as [encoding], never throwing.
///
/// Malformed bytes become U+FFFD (lenient UTF-8, replacement for undefined codepage positions,
/// unpaired surrogates and out-of-range code units). A leading U+FEFF byte order mark is stripped.
/// Use this when the encoding was detected once for the whole document and then applied to slices
/// of it.
String decodeXmlTextAs(final List<int> bytes, final XmlEncoding encoding) {
  final typed = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final text = switch (encoding) {
    XmlEncoding.ascii => _decodeAscii(typed),
    XmlEncoding.latin1 => String.fromCharCodes(typed),
    XmlEncoding.cp1251 => _decodeSingleByte(typed, _XmlEncodingTables.cp1251Runes),
    XmlEncoding.cp1252 => _decodeSingleByte(typed, _XmlEncodingTables.cp1252Runes),
    XmlEncoding.cp1256 => _decodeSingleByte(typed, _XmlEncodingTables.cp1256Runes),
    XmlEncoding.utf8 => convert.utf8.decode(typed, allowMalformed: true),
    XmlEncoding.utf16le => _decodeUtf16(typed, littleEndian: true),
    XmlEncoding.utf16be => _decodeUtf16(typed, littleEndian: false),
    XmlEncoding.utf32le => _decodeUtf32(typed, littleEndian: true),
    XmlEncoding.utf32be => _decodeUtf32(typed, littleEndian: false),
  };

  return text.startsWith('\uFEFF') ? text.substring(1) : text;
}

XmlEncoding? _bomEncoding(final Uint8List bytes) {
  if (bytes.length >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xFE && bytes[3] == 0xFF) {
    return XmlEncoding.utf32be;
  }

  if (bytes.length >= 4 && bytes[0] == 0xFF && bytes[1] == 0xFE && bytes[2] == 0 && bytes[3] == 0) {
    return XmlEncoding.utf32le;
  }

  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return XmlEncoding.utf8;
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return XmlEncoding.utf16be;
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return XmlEncoding.utf16le;

  return null;
}

/// Extracts the declared encoding name over the first 50 KiB, or null. The head is decoded as
/// latin-1 for scanning: XML/HTML declarations are ASCII, and latin-1 is a lossless byte mapping.
String? _declaredEncodingName(final Uint8List bytes) {
  // Declaration patterns are limited to the first 50 KiB.
  const declarationWindowBytes = 50 * 1024;
  final head = String.fromCharCodes(
    Uint8List.sublistView(bytes, 0, math.min(bytes.length, declarationWindowBytes)),
  );
  for (final pattern in _encodingPatterns) {
    final match = pattern.firstMatch(head);
    if (match != null) return match.group(1);
  }

  return null;
}

/// Declaration patterns in priority order: the XML declaration, then the HTML5 `<meta charset>`
/// hint, then the HTML4 content-type hint.
final List<RegExp> _encodingPatterns = <RegExp>[
  RegExp(r'''<\?xml[^>]*?encoding\s*=\s*["']([-\w.]+)["']''', caseSensitive: false),
  RegExp(r'''<meta\s[^>]*?charset\s*=\s*["']?([-\w.]+)''', caseSensitive: false),
  RegExp(r'''<meta\s[^>]*?content\s*=\s*["'][^>]*?charset\s*=\s*([-\w.]+)''', caseSensitive: false),
];

/// Lowercases and drops `-`/`_`/spaces so `windows-1251`, `WINDOWS_1251` and `windows1251` share a
/// lookup key.
String _normalizeEncodingName(final String name) {
  return name.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');
}

/// Without a supported declaration, the bytes are first tried as strict UTF-8, then a NUL-parity
/// check rescues declaration-less UTF-16 (defensive; BOM-less UTF-16 is not XML-conformant), and
/// legacy single-byte detection decides.
XmlEncoding _sniffUndeclared(final Uint8List bytes) {
  try {
    convert.utf8.decode(bytes);

    return XmlEncoding.utf8;
  } on FormatException {
    // Not valid UTF-8; keep sniffing.
  }

  final utf16 = _utf16ByNullParity(bytes);
  if (utf16 != null) return utf16;

  return _detectLegacySingleByte(bytes);
}

/// Detects BOM-less UTF-16 by NUL-byte position: Latin/Cyrillic/Arabic BMP text has a 0x00 high
/// byte on every other byte — odd offsets for little-endian, even for big-endian. Single-byte
/// encodings never contain NULs.
XmlEncoding? _utf16ByNullParity(final Uint8List bytes) {
  var evenNuls = 0;
  var oddNuls = 0;
  final end = math.min(bytes.length, _detectionWindowBytes);
  for (var i = 0; i < end; i++) {
    if (bytes[i] != 0) continue;

    i.isEven ? evenNuls++ : oddNuls++;
  }

  final nuls = evenNuls + oddNuls;
  if (nuls == 0 || nuls * 8 < end) return null;

  return evenNuls > oddNuls ? XmlEncoding.utf16be : XmlEncoding.utf16le;
}

/// Scores windows-1251, windows-1256 and windows-1252 against the sampled byte distribution and
/// picks the best script family.
///
/// Each codepage carries weights in 0..5 per high byte (5 = a very frequent script letter, 2 =
/// other letters, 1 = typographic punctuation prose uses, 0 = everything else). The scores are
/// averaged over the sampled high bytes; windows-1252 wins unless a Cyrillic/Arabic candidate beats
/// it by a clear margin on a document that is not predominantly ASCII.
XmlEncoding _detectLegacySingleByte(final Uint8List bytes) {
  // A document whose sampled bytes are less than 10% high bytes is treated as predominantly
  // Western/ASCII. Single-byte Cyrillic or Arabic prose is 25-50% high bytes, while accented Latin
  // text rarely exceeds a few percent.
  const westernHighShareDenominator = 10;
  // A non-Western candidate must beat the windows-1252 score by this ratio (integer form: x10 >
  // 11).
  const westernPriority = 11;

  final end = math.min(bytes.length, _detectionWindowBytes);

  var high = 0;
  var score1251 = 0;
  var score1252 = 0;
  var score1256 = 0;
  for (var i = 0; i < end; i++) {
    final byte = bytes[i];
    if (byte < 0x80) continue;

    final index = byte - 0x80;
    high++;
    score1251 += _XmlEncodingTables.cp1251Weights[index];
    score1252 += _XmlEncodingTables.cp1252Weights[index];
    score1256 += _XmlEncodingTables.cp1256Weights[index];
  }

  if (high == 0) return XmlEncoding.utf8;
  if (high * westernHighShareDenominator < end) return XmlEncoding.cp1252;

  if (score1251 >= score1256 && score1251 * 10 > score1252 * westernPriority) {
    return XmlEncoding.cp1251;
  }

  if (score1256 > score1251 && score1256 * 10 > score1252 * westernPriority) {
    return XmlEncoding.cp1256;
  }

  return XmlEncoding.cp1252;
}

String _decodeAscii(final Uint8List bytes) {
  final out = StringBuffer(bytes.length);
  for (final byte in bytes) {
    out.writeCharCode(byte <= 0x7F ? byte : _replacementRune);
  }

  return out.toString();
}

String _decodeSingleByte(final Uint8List bytes, final List<int> runes) {
  final out = StringBuffer(bytes.length);
  for (final byte in bytes) {
    out.writeCharCode(byte < 0x80 ? byte : runes[byte - 0x80]);
  }

  return out.toString();
}

String _decodeUtf16(final Uint8List bytes, {required final bool littleEndian}) {
  final out = StringBuffer();
  var i = 0;
  while (i + 1 < bytes.length) {
    final unit = littleEndian ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1];
    i += 2;

    if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < bytes.length) {
      final low = littleEndian ? bytes[i] | (bytes[i + 1] << 8) : (bytes[i] << 8) | bytes[i + 1];
      if (low >= 0xDC00 && low <= 0xDFFF) {
        out.writeCharCode(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00));
        i += 2;
        continue;
      }
    }
    if (unit >= 0xD800 && unit <= 0xDFFF) {
      out.writeCharCode(_replacementRune);

      continue;
    }

    out.writeCharCode(unit);
  }

  return out.toString();
}

String _decodeUtf32(final Uint8List bytes, {required final bool littleEndian}) {
  final out = StringBuffer();
  var i = 0;
  while (i + 3 < bytes.length) {
    final value = littleEndian
        ? bytes[i] | (bytes[i + 1] << 8) | (bytes[i + 2] << 16) | (bytes[i + 3] << 24)
        : (bytes[i] << 24) | (bytes[i + 1] << 16) | (bytes[i + 2] << 8) | bytes[i + 3];
    i += 4;
    final isSurrogate = value >= 0xD800 && value <= 0xDFFF;
    if (value < 0 || value > 0x10FFFF || isSurrogate) {
      out.writeCharCode(_replacementRune);

      continue;
    }

    out.writeCharCode(value);
  }

  return out.toString();
}
