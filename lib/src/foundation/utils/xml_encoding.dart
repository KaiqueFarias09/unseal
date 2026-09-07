/// XML/HTML text-encoding detection and lenient byte decoding.
///
/// The policy mirrors Calibre's `detect_xml_encoding`/`xml_to_unicode`
/// behaviour (re-expressed from its documented semantics, not copied):
///
/// 1. a byte order mark wins over anything else;
/// 2. a declared encoding in the first 50 KiB (`<?xml ... ?>` or an
///    HTML `<meta charset>`/`<meta content>` hint) is honoured as-is —
///    a *wrong* declaration is not corrected, exactly like Calibre;
/// 3. with no supported declaration, the bytes are tried as strict
///    UTF-8 first (Calibre's `assume_utf8` path);
/// 4. otherwise a lightweight byte-scored detection picks between the
///    legacy single-byte families that matter for ebooks:
///    windows-1251 (Cyrillic), windows-1256 (Arabic) and the
///    windows-1252/latin-1 Western default.
///
/// Decoding never throws: undecodable bytes become U+FFFD replacement
/// characters, matching Calibre's `decode(..., 'replace')`.
///
/// Scope note: full uchardet support (CJK and other multibyte legacy
/// encodings, KOI8-R, ISO-8859-5, ...) is out of scope — a document in
/// those encodings degrades to the windows-1252/Western default the
/// same way Calibre degrades without uchardet installed.
library;

import 'dart:convert' as convert;
import 'dart:math' as math;
import 'dart:typed_data';

/// The text encodings this library can decode XML/HTML bytes with.
///
/// `utf16le`/`utf16be`/`utf32le`/`utf32be` only arise from byte order
/// marks (or a declaration naming them); the single-byte Windows
/// codepages additionally back the legacy detection heuristics.
enum XmlEncoding {
  /// US-ASCII; bytes above 0x7F decode to U+FFFD.
  ascii,

  /// ISO-8859-1; every byte value maps to the same code point.
  latin1,

  /// Windows-1252 (Western European), Calibre's Western default.
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

/// How many leading bytes are scanned for a declared encoding —
/// Calibre applies its declaration patterns to the first 50 KiB.
const int _declarationWindowBytes = 50 * 1024;

/// How many bytes feed the legacy single-byte detection. Language
/// identification needs far less than this; the cap only bounds the
/// cost on very large documents.
const int _detectionWindowBytes = 256 * 1024;

/// A document whose sampled bytes are less than 10% high bytes is
/// treated as predominantly Western/ASCII: single-byte Cyrillic or
/// Arabic prose is 25-50% high bytes, while accented Latin text
/// rarely exceeds a few percent.
const int _westernHighShareDenominator = 10;

/// A non-Western candidate must beat the windows-1252 score by this
/// ratio to override the Western default (integer form: x10 > 11).
const int _westernPriority = 11;

/// U+FFFD, the replacement character emitted for undecodable bytes.
const int _replacementRune = 0xFFFD;

/// Detects the text encoding of an XML (or HTML) document.
///
/// See the library documentation for the policy. Never throws; the
/// returned encoding always produces a replacement-decoded string via
/// [decodeXmlTextAs].
XmlEncoding sniffXmlEncoding(final List<int> bytes) {
  final typed = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

  final bom = _bomEncoding(typed);
  if (bom != null) return bom;

  final declared = _declaredEncodingName(typed);
  if (declared != null) {
    final known = _declaredEncodings[_normalizeEncodingName(declared)];
    if (known != null) return known;
    // An unsupported declaration degrades to the undeclared policy,
    // like Calibre's unlookupable-codec fallback.
  }

  return _sniffUndeclared(typed);
}

/// Decodes [bytes] with the encoding [sniffXmlEncoding] picks.
///
/// Never throws; malformed bytes become U+FFFD. A leading U+FEFF
/// (byte order mark) is stripped from the result.
String decodeXmlText(final List<int> bytes) => decodeXmlTextAs(bytes, sniffXmlEncoding(bytes));

/// Decodes [bytes] as [encoding], never throwing.
///
/// Malformed bytes become U+FFFD (lenient UTF-8, replacement for
/// undefined codepage positions, unpaired surrogates and out-of-range
/// code units). A leading U+FEFF byte order mark is stripped. Use
/// this when the encoding was detected once for the whole document
/// and then applied to slices of it.
String decodeXmlTextAs(final List<int> bytes, final XmlEncoding encoding) {
  final typed = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final text = switch (encoding) {
    XmlEncoding.ascii => _decodeAscii(typed),
    XmlEncoding.latin1 => String.fromCharCodes(typed),
    XmlEncoding.cp1251 => _decodeSingleByte(typed, _cp1251Runes),
    XmlEncoding.cp1252 => _decodeSingleByte(typed, _cp1252Runes),
    XmlEncoding.cp1256 => _decodeSingleByte(typed, _cp1256Runes),
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
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return XmlEncoding.utf16be;
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return XmlEncoding.utf16le;
  }

  return null;
}

/// Extracts the declared encoding name over the first 50 KiB, or
/// null. The head is decoded as latin-1 for scanning: XML/HTML
/// declarations are ASCII, and latin-1 is a lossless byte mapping.
String? _declaredEncodingName(final Uint8List bytes) {
  final head = String.fromCharCodes(
    Uint8List.sublistView(bytes, 0, math.min(bytes.length, _declarationWindowBytes)),
  );

  for (final pattern in _encodingPatterns) {
    final match = pattern.firstMatch(head);
    if (match != null) return match.group(1);
  }

  return null;
}

/// Declaration patterns in priority order: the XML declaration, then
/// the HTML5 `<meta charset>` hint, then the HTML4 content-type hint.
final List<RegExp> _encodingPatterns = <RegExp>[
  RegExp(r'''<\?xml[^>]*?encoding\s*=\s*["']([-\w.]+)["']''', caseSensitive: false),
  RegExp(r'''<meta\s[^>]*?charset\s*=\s*["']?([-\w.]+)''', caseSensitive: false),
  RegExp(r'''<meta\s[^>]*?content\s*=\s*["'][^>]*?charset\s*=\s*([-\w.]+)''', caseSensitive: false),
];

/// Lowercases and drops `-`/`_`/spaces so `windows-1251`, `WINDOWS_1251`
/// and `windows1251` share a lookup key.
String _normalizeEncodingName(final String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[\s_-]'), '');

/// Declarations this decoder can honour, keyed by
/// [_normalizeEncodingName]. Everything else (koi8-r, shift-jis,
/// iso-8859-5, ...) falls back to the undeclared policy.
const Map<String, XmlEncoding> _declaredEncodings = <String, XmlEncoding>{
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

/// Calibre's `assume_utf8` policy: without a supported declaration the
/// bytes are first tried as strict UTF-8, then a NUL-parity check
/// rescues declaration-less UTF-16 (defensive; BOM-less UTF-16 is not
/// XML-conformant), then the legacy single-byte detection decides.
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

/// Detects BOM-less UTF-16 by NUL-byte position: Latin/Cyrillic/Arabic
/// BMP text has a 0x00 high byte on every other byte — odd offsets for
/// little-endian, even for big-endian. Single-byte encodings never
/// contain NULs.
XmlEncoding? _utf16ByNullParity(final Uint8List bytes) {
  var evenNuls = 0;
  var oddNuls = 0;
  final end = math.min(bytes.length, _detectionWindowBytes);
  for (var i = 0; i < end; i++) {
    if (bytes[i] != 0) continue;
    if (i.isEven) {
      evenNuls++;
    } else {
      oddNuls++;
    }
  }
  final nuls = evenNuls + oddNuls;
  if (nuls == 0 || nuls * 8 < end) return null;

  return evenNuls > oddNuls ? XmlEncoding.utf16be : XmlEncoding.utf16le;
}

/// Scores windows-1251, windows-1256 and windows-1252 against the
/// sampled byte distribution and picks the best script family.
///
/// Each codepage carries weights in 0..5 per high byte (5 = a very
/// frequent script letter, 2 = other letters, 1 = typographic
/// punctuation prose uses, 0 = everything else). The scores are
/// averaged over the sampled high bytes; windows-1252 wins unless a
/// Cyrillic/Arabic candidate beats it by a clear margin on a document
/// that is not predominantly ASCII.
XmlEncoding _detectLegacySingleByte(final Uint8List bytes) {
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
    score1251 += _cp1251Weights[index];
    score1252 += _cp1252Weights[index];
    score1256 += _cp1256Weights[index];
  }

  if (high == 0) return XmlEncoding.utf8;
  if (high * _westernHighShareDenominator < end) return XmlEncoding.cp1252;
  if (score1251 >= score1256 && score1251 * 10 > score1252 * _westernPriority) {
    return XmlEncoding.cp1251;
  }
  if (score1256 > score1251 && score1256 * 10 > score1252 * _westernPriority) {
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

/// windows-1251 byte values (0x80-0xFF) to code points. Only 0x98 is
/// unassigned in the codepage and maps to U+FFFD; bytes 0xC0-0xFF are
/// the contiguous А-Яа-я block (U+0410-U+044F), 0xA8/0xB8 are Ё/ё.
/// Verified against Python's cp1251 codec ground truth.
const List<int> _cp1251Runes = <int>[
  0x0402,
  0x0403,
  0x201A,
  0x0453,
  0x201E,
  0x2026,
  0x2020,
  0x2021,
  0x20AC,
  0x2030,
  0x0409,
  0x2039,
  0x040A,
  0x040C,
  0x040B,
  0x040F,
  0x0452,
  0x2018,
  0x2019,
  0x201C,
  0x201D,
  0x2022,
  0x2013,
  0x2014,
  0xFFFD,
  0x2122,
  0x0459,
  0x203A,
  0x045A,
  0x045C,
  0x045B,
  0x045F,
  0x00A0,
  0x040E,
  0x045E,
  0x0408,
  0x00A4,
  0x0490,
  0x00A6,
  0x00A7,
  0x0401,
  0x00A9,
  0x0404,
  0x00AB,
  0x00AC,
  0x00AD,
  0x00AE,
  0x0407,
  0x00B0,
  0x00B1,
  0x0406,
  0x0456,
  0x0491,
  0x00B5,
  0x00B6,
  0x00B7,
  0x0451,
  0x2116,
  0x0454,
  0x00BB,
  0x0458,
  0x0405,
  0x0455,
  0x0457,
  0x0410,
  0x0411,
  0x0412,
  0x0413,
  0x0414,
  0x0415,
  0x0416,
  0x0417,
  0x0418,
  0x0419,
  0x041A,
  0x041B,
  0x041C,
  0x041D,
  0x041E,
  0x041F,
  0x0420,
  0x0421,
  0x0422,
  0x0423,
  0x0424,
  0x0425,
  0x0426,
  0x0427,
  0x0428,
  0x0429,
  0x042A,
  0x042B,
  0x042C,
  0x042D,
  0x042E,
  0x042F,
  0x0430,
  0x0431,
  0x0432,
  0x0433,
  0x0434,
  0x0435,
  0x0436,
  0x0437,
  0x0438,
  0x0439,
  0x043A,
  0x043B,
  0x043C,
  0x043D,
  0x043E,
  0x043F,
  0x0440,
  0x0441,
  0x0442,
  0x0443,
  0x0444,
  0x0445,
  0x0446,
  0x0447,
  0x0448,
  0x0449,
  0x044A,
  0x044B,
  0x044C,
  0x044D,
  0x044E,
  0x044F,
];

/// windows-1252 byte values (0x80-0xFF) to code points. The five
/// unassigned bytes 0x81 0x8D 0x8F 0x90 0x9D map to U+FFFD; 0xA0-0xFF
/// are the latin-1 identity. Verified against Python's cp1252 codec.
const List<int> _cp1252Runes = <int>[
  0x20AC,
  0xFFFD,
  0x201A,
  0x0192,
  0x201E,
  0x2026,
  0x2020,
  0x2021,
  0x02C6,
  0x2030,
  0x0160,
  0x2039,
  0x0152,
  0xFFFD,
  0x017D,
  0xFFFD,
  0xFFFD,
  0x2018,
  0x2019,
  0x201C,
  0x201D,
  0x2022,
  0x2013,
  0x2014,
  0x02DC,
  0x2122,
  0x0161,
  0x203A,
  0x0153,
  0xFFFD,
  0x017E,
  0x0178,
  0x00A0,
  0x00A1,
  0x00A2,
  0x00A3,
  0x00A4,
  0x00A5,
  0x00A6,
  0x00A7,
  0x00A8,
  0x00A9,
  0x00AA,
  0x00AB,
  0x00AC,
  0x00AD,
  0x00AE,
  0x00AF,
  0x00B0,
  0x00B1,
  0x00B2,
  0x00B3,
  0x00B4,
  0x00B5,
  0x00B6,
  0x00B7,
  0x00B8,
  0x00B9,
  0x00BA,
  0x00BB,
  0x00BC,
  0x00BD,
  0x00BE,
  0x00BF,
  0x00C0,
  0x00C1,
  0x00C2,
  0x00C3,
  0x00C4,
  0x00C5,
  0x00C6,
  0x00C7,
  0x00C8,
  0x00C9,
  0x00CA,
  0x00CB,
  0x00CC,
  0x00CD,
  0x00CE,
  0x00CF,
  0x00D0,
  0x00D1,
  0x00D2,
  0x00D3,
  0x00D4,
  0x00D5,
  0x00D6,
  0x00D7,
  0x00D8,
  0x00D9,
  0x00DA,
  0x00DB,
  0x00DC,
  0x00DD,
  0x00DE,
  0x00DF,
  0x00E0,
  0x00E1,
  0x00E2,
  0x00E3,
  0x00E4,
  0x00E5,
  0x00E6,
  0x00E7,
  0x00E8,
  0x00E9,
  0x00EA,
  0x00EB,
  0x00EC,
  0x00ED,
  0x00EE,
  0x00EF,
  0x00F0,
  0x00F1,
  0x00F2,
  0x00F3,
  0x00F4,
  0x00F5,
  0x00F6,
  0x00F7,
  0x00F8,
  0x00F9,
  0x00FA,
  0x00FB,
  0x00FC,
  0x00FD,
  0x00FE,
  0x00FF,
];

/// windows-1256 byte values (0x80-0xFF) to code points. Every byte is
/// assigned in this codepage; 0xC1-0xD6 are the contiguous
/// U+0621-U+0636 Arabic block, with the remaining Arabic/Persian
/// letters and French slots (à é è ...) scattered across the rest.
/// Verified against Python's cp1256 codec.
const List<int> _cp1256Runes = <int>[
  0x20AC,
  0x067E,
  0x201A,
  0x0192,
  0x201E,
  0x2026,
  0x2020,
  0x2021,
  0x02C6,
  0x2030,
  0x0679,
  0x2039,
  0x0152,
  0x0686,
  0x0698,
  0x0688,
  0x06AF,
  0x2018,
  0x2019,
  0x201C,
  0x201D,
  0x2022,
  0x2013,
  0x2014,
  0x06A9,
  0x2122,
  0x0691,
  0x203A,
  0x0153,
  0x200C,
  0x200D,
  0x06BA,
  0x00A0,
  0x060C,
  0x00A2,
  0x00A3,
  0x00A4,
  0x00A5,
  0x00A6,
  0x00A7,
  0x00A8,
  0x00A9,
  0x06BE,
  0x00AB,
  0x00AC,
  0x00AD,
  0x00AE,
  0x00AF,
  0x00B0,
  0x00B1,
  0x00B2,
  0x00B3,
  0x00B4,
  0x00B5,
  0x00B6,
  0x00B7,
  0x00B8,
  0x00B9,
  0x061B,
  0x00BB,
  0x00BC,
  0x00BD,
  0x00BE,
  0x061F,
  0x06C1,
  0x0621,
  0x0622,
  0x0623,
  0x0624,
  0x0625,
  0x0626,
  0x0627,
  0x0628,
  0x0629,
  0x062A,
  0x062B,
  0x062C,
  0x062D,
  0x062E,
  0x062F,
  0x0630,
  0x0631,
  0x0632,
  0x0633,
  0x0634,
  0x0635,
  0x0636,
  0x00D7,
  0x0637,
  0x0638,
  0x0639,
  0x063A,
  0x0640,
  0x0641,
  0x0642,
  0x0643,
  0x00E0,
  0x0644,
  0x00E2,
  0x0645,
  0x0646,
  0x0647,
  0x0648,
  0x00E7,
  0x00E8,
  0x00E9,
  0x00EA,
  0x00EB,
  0x0649,
  0x064A,
  0x00EE,
  0x00EF,
  0x064B,
  0x064C,
  0x064D,
  0x064E,
  0x00F4,
  0x064F,
  0x0650,
  0x00F7,
  0x0651,
  0x00F9,
  0x0652,
  0x00FB,
  0x00FC,
  0x200E,
  0x200F,
  0x06D2,
];

/// Detection weights for windows-1251 high bytes (0x80-0xFF): 5 for
/// the eight most frequent Russian letters (о е а и н т с р, upper-
/// and lowercase), 2 for other Cyrillic letters (incl. Ё/ё and the
/// Serbian/Ukrainian national letters), 1 for the typographic
/// punctuation Russian prose uses (‚ „ … ‘ ’ “ ” – — nbsp « » №),
/// 0 for the rest.
const List<int> _cp1251Weights = <int>[
  2,
  2,
  1,
  2,
  1,
  1,
  0,
  0,
  0,
  0,
  2,
  0,
  2,
  2,
  2,
  2,
  2,
  1,
  1,
  1,
  1,
  0,
  1,
  1,
  0,
  0,
  2,
  0,
  2,
  2,
  2,
  2,
  1,
  2,
  2,
  2,
  0,
  2,
  0,
  0,
  2,
  0,
  2,
  1,
  0,
  0,
  0,
  2,
  0,
  0,
  2,
  2,
  2,
  2,
  0,
  0,
  2,
  1,
  2,
  1,
  2,
  2,
  2,
  2,
  5,
  2,
  2,
  2,
  2,
  5,
  2,
  2,
  5,
  2,
  2,
  2,
  2,
  5,
  5,
  2,
  5,
  5,
  5,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  5,
  2,
  2,
  2,
  2,
  5,
  2,
  2,
  5,
  2,
  2,
  2,
  2,
  5,
  5,
  2,
  5,
  5,
  5,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
];

/// Detection weights for windows-1252 high bytes (0x80-0xFF): 4 for
/// the common West-European accents (à á ä ç è é í ñ ó ö ú ü ß, upper-
/// and lowercase), 2 for other accented letters and Œ œ Š š Ž ž Ÿ,
/// 1 for the typographic punctuation and symbols prose uses (curly
/// quotes, dashes, ellipsis, «», ¡¿, superscripts, currency), 0 for
/// the five unassigned bytes and × ÷.
const List<int> _cp1252Weights = <int>[
  1,
  0,
  1,
  0,
  1,
  1,
  1,
  1,
  0,
  1,
  2,
  1,
  2,
  0,
  2,
  0,
  0,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  2,
  1,
  2,
  0,
  2,
  2,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  0,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  1,
  0,
  1,
  1,
  1,
  1,
  0,
  1,
  1,
  1,
  1,
  1,
  4,
  4,
  2,
  2,
  4,
  2,
  2,
  4,
  4,
  4,
  2,
  2,
  2,
  4,
  2,
  2,
  2,
  4,
  2,
  4,
  2,
  2,
  4,
  0,
  2,
  2,
  4,
  2,
  4,
  2,
  2,
  2,
  4,
  4,
  2,
  2,
  4,
  2,
  2,
  4,
  4,
  4,
  2,
  2,
  2,
  4,
  2,
  2,
  2,
  4,
  2,
  4,
  2,
  2,
  4,
  0,
  2,
  2,
  4,
  2,
  4,
  2,
  2,
  2,
];

/// Detection weights for windows-1256 high bytes (0x80-0xFF): 5 for
/// the nine most frequent Arabic letters (ا ل ي م و ن ر ت ب), 2 for
/// other Arabic/Persian letters, 1 for the punctuation Arabic prose
/// uses (، ؛ ؟ nbsp « » quotes dashes tatweel marks), 0 for the
/// harakat vowels (rare outside vocalized texts) and the French
/// leftover slots real Arabic text never produces.
const List<int> _cp1256Weights = <int>[
  0,
  2,
  1,
  0,
  1,
  1,
  0,
  0,
  0,
  0,
  2,
  1,
  0,
  2,
  2,
  2,
  2,
  1,
  1,
  1,
  1,
  0,
  1,
  1,
  2,
  0,
  2,
  1,
  0,
  1,
  1,
  2,
  1,
  1,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  2,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  1,
  0,
  0,
  0,
  1,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  5,
  5,
  5,
  2,
  2,
  2,
  2,
  2,
  2,
  2,
  5,
  2,
  2,
  2,
  2,
  2,
  0,
  2,
  2,
  2,
  2,
  1,
  2,
  2,
  2,
  2,
  5,
  2,
  5,
  5,
  2,
  5,
  2,
  2,
  2,
  2,
  2,
  2,
  5,
  2,
  2,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  0,
  1,
  1,
  2,
];
