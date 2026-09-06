import 'dart:typed_data';

import '../header/pdf_document.dart';
import '../header/pdf_object.dart';
import '../utils/pdf_encodings.dart';
import '../utils/pdf_standard_widths.dart';
import 'pdf_cmap.dart';

/// A resolved text font: how codes decode to Unicode and how wide
/// each code renders.
///
/// *Type0* (composite/CID) fonts decode through their ToUnicode CMap
/// (2-byte codes under `Identity-*`); without one the text is
/// unreadable — codes still advance so surrounding geometry stays
/// correct, but no characters come back. *Simple* fonts (Type1,
/// TrueType, Type3) decode through the named Adobe encoding or a
/// `/Differences` array, falling back to WinAnsi for the symbolic
/// fonts that carry no encoding (the best-effort choice most
/// extractors make).
///
/// Widths come from `/Widths` (simple) or `/W` (CID) in glyph-space
/// units normalized to em (1.0 = font size); standard-14 fonts
/// without widths measure through the per-glyph Adobe AFM metrics,
/// falling back to per-family averages only for unknown names.
class PdfFont {
  PdfFont._(
    this.codeBytes, {
    required this.unicodeOfCode,
    required this.widthOfCode,
    required this.isCid,
    this.averageWidth = 0.5,
  });

  /// Builds the font described by [dictionary] (already resolved).
  factory PdfFont.of(final PdfDocument document, final PdfDictionary dictionary) {
    final subtype = document.resolve(dictionary['Subtype']);
    final baseFont = document.resolve(dictionary['BaseFont']);
    final baseFontName = baseFont is PdfName ? baseFont.value : '';

    if (subtype is PdfName && subtype.value == 'Type0') {
      return _type0(document, dictionary, baseFontName);
    }

    return _simple(document, dictionary, baseFontName);
  }

  /// Bytes one character code occupies (1 for simple fonts, 2 or 4
  /// for composite).
  final int codeBytes;

  /// Decodes one character code to Unicode (null when unmapped).
  final String? Function(int code) unicodeOfCode;

  /// Measures one character code in em units (font-size multiples).
  final double Function(int code) widthOfCode;

  /// Whether this is a composite (CID) font.
  final bool isCid;

  /// The fallback per-character width in em units.
  final double averageWidth;

  /// Decodes and measures one show-text payload: the Unicode text,
  /// the advance width in em units (font-size multiples), the number
  /// of character codes consumed and how many of them were the word
  /// space code (word spacing applies to each of those).
  (String, double, int, int) decode(final Uint8List bytes) {
    final text = StringBuffer();
    var advance = 0.0;
    var codeCount = 0;
    var spaceCount = 0;
    var offset = 0;
    while (offset + codeBytes <= bytes.length) {
      var code = 0;
      for (var i = 0; i < codeBytes; i++) {
        code = code * 256 + bytes[offset + i];
      }
      offset += codeBytes;
      final unicode = unicodeOfCode(code);
      if (unicode != null) text.write(unicode);
      advance += widthOfCode(code);
      codeCount++;
      if (code == 0x20 && !isCid) spaceCount++;
    }

    return (text.toString(), advance, codeCount, spaceCount);
  }

  static PdfFont _type0(
    final PdfDocument document,
    final PdfDictionary dictionary,
    final String name,
  ) {
    // A Type0 `/Encoding` is either a name (`Identity-H`, a
    // predefined CMap) or an embedded CMap stream. The stream carries
    // its own code space (one byte is common) and a `cidrange` block
    // mapping codes onto CIDs — `/W` and `/DW` are keyed by CID, not
    // by code; under `Identity-*` code equals CID.
    final encoding = document.resolve(dictionary['Encoding']);
    final embedded = encoding is PdfStream ? _cMapOf(document, encoding) : null;
    final codeBytes = embedded?.codeBytes ?? 2;

    // A Type0 font without ToUnicode (predefined CMaps such as
    // UniJIS carry no Unicode mapping this extractor can read)
    // decodes to nothing: it still measures, so surrounding geometry
    // stays correct.
    final toUnicode = _toUnicodeCMap(document, dictionary) ?? PdfCMap.parse('');
    final cidWidths = _cidWidths(document, dictionary);
    final cidOfCode = embedded?.cidMap;
    double widthOfCode(final int code) {
      final cid = cidOfCode == null ? code : cidOfCode[code];
      if (cid == null) return cidWidths.$2;

      return cidWidths.$1[cid] ?? cidWidths.$2;
    }

    return PdfFont._(
      codeBytes,
      isCid: true,
      unicodeOfCode: (final code) => toUnicode.map[code],
      widthOfCode: widthOfCode,
      averageWidth: 1.0,
    );
  }

  static PdfFont _simple(
    final PdfDocument document,
    final PdfDictionary dictionary,
    final String name,
  ) {
    var base = pdfWinAnsiEncoding;
    var differences = <int, String>{};
    final encoding = document.resolve(dictionary['Encoding']);
    if (encoding is PdfName) {
      switch (encoding.value) {
        case 'StandardEncoding':
          base = pdfStandardEncoding;
        case 'MacRomanEncoding':
          base = pdfMacRomanEncoding;
        case 'WinAnsiEncoding':
          base = pdfWinAnsiEncoding;
        case 'PDFDocEncoding':
          base = pdfWinAnsiEncoding;
      }
    } else if (encoding is PdfDictionary) {
      final baseEncoding = document.resolve(encoding['BaseEncoding']);
      if (baseEncoding is PdfName) {
        switch (baseEncoding.value) {
          case 'StandardEncoding':
            base = pdfStandardEncoding;
          case 'MacRomanEncoding':
            base = pdfMacRomanEncoding;
          case 'PDFDocEncoding':
            base = pdfWinAnsiEncoding;
          default:
            base = pdfWinAnsiEncoding;
        }
      }
      differences = _differencesOf(document, encoding);
    } else {
      final lower = name.toLowerCase();
      if (lower.contains('symbol') || lower.contains('zapf')) {
        base = pdfStandardEncoding;
      }
    }
    final table = applyEncodingDifferences(base, differences);

    final firstChar = _intValue(document, dictionary['FirstChar']) ?? 32;
    final widths = <int, double>{};
    final widthsObject = document.resolve(dictionary['Widths']);
    if (widthsObject is PdfArray) {
      for (var i = 0; i < widthsObject.items.length; i++) {
        final item = widthsObject.items[i];
        if (item is PdfNumber) widths[firstChar + i] = item.value / 1000;
      }
    }
    final standard = _standard14Row(name);
    final fallback = _standard14Average(name);
    double widthOfCode(final int code) {
      final explicit = widths[code];
      if (explicit != null) return explicit;
      if (standard != null && code >= 0 && code < standard.length) {
        final glyph = standard[code];
        if (glyph != null) return glyph / 1000;
      }

      return fallback;
    }

    return PdfFont._(
      1,
      isCid: false,
      unicodeOfCode: (final code) => code >= 0 && code < 256 ? table[code] : null,
      widthOfCode: widthOfCode,
      averageWidth: fallback,
    );
  }

  /// Decodes a CMap [stream] into a [PdfCMap]; null when undecodable.
  static PdfCMap? _cMapOf(final PdfDocument document, final PdfStream stream) {
    try {
      final text = String.fromCharCodes(document.decodeStream(stream));

      return PdfCMap.parse(text);
    } on Exception {
      return null;
    }
  }

  static PdfCMap? _toUnicodeCMap(final PdfDocument document, final PdfDictionary dictionary) {
    final stream = document.resolve(dictionary['ToUnicode']);
    if (stream is! PdfStream) return null;
    try {
      final text = String.fromCharCodes(document.decodeStream(stream));

      return PdfCMap.parse(text);
    } on Exception {
      return null;
    }
  }

  /// The `/W` widths keyed by CID plus the `/DW` default (1.0 when
  /// the dictionary carries none).
  static (Map<int, double>, double) _cidWidths(
    final PdfDocument document,
    final PdfDictionary dictionary,
  ) {
    var defaultWidth = 1.0;
    final widths = <int, double>{};
    final descendants = document.resolve(dictionary['DescendantFonts']);
    final descendant = descendants is PdfArray && descendants.items.isNotEmpty
        ? document.resolve(descendants.items.first)
        : null;
    if (descendant is PdfDictionary) {
      final wArray = document.resolve(descendant['W']);
      if (wArray is PdfArray) {
        var i = 0;
        while (i < wArray.items.length) {
          final start = wArray.items[i];
          if (start is! PdfNumber) {
            i++;
            continue;
          }
          final second = i + 1 < wArray.items.length ? wArray.items[i + 1] : null;
          final third = i + 2 < wArray.items.length ? wArray.items[i + 2] : null;
          if (second is PdfArray) {
            // Array form: c [w1 w2 ...].
            for (var j = 0; j < second.items.length; j++) {
              final width = second.items[j];
              if (width is PdfNumber) widths[start.intValue + j] = width.value / 1000;
            }
            i += 2;
          } else if (second is PdfNumber && third is PdfArray) {
            // Range-array form: cfirst clast [w1 w2 ...] — one width
            // per CID across the span.
            for (var j = 0; j < third.items.length; j++) {
              final width = third.items[j];
              if (width is PdfNumber) widths[start.intValue + j] = width.value / 1000;
            }
            i += 3;
          } else if (second is PdfNumber && third is PdfNumber) {
            // Range form: cfirst clast w — one width across the span.
            for (
              var code = start.intValue;
              code <= second.intValue && code - start.intValue < 65536;
              code++
            ) {
              widths[code] = third.value / 1000;
            }
            i += 3;
          } else {
            i++;
          }
        }
      }
      final dw = document.resolve(descendant['DW']);
      if (dw is PdfNumber) defaultWidth = dw.value / 1000;
    }

    return (widths, defaultWidth);
  }

  static Map<int, String> _differencesOf(final PdfDocument document, final PdfDictionary encoding) {
    final differences = <int, String>{};
    final array = document.resolve(encoding['Differences']);
    if (array is! PdfArray) return differences;
    var code = 0;
    for (final item in array.items) {
      if (item is PdfNumber) {
        code = item.intValue;
      } else if (item is PdfName) {
        differences[code++] = item.value;
      }
    }

    return differences;
  }

  static int? _intValue(final PdfDocument document, final PdfObject? object) {
    final resolved = document.resolve(object);
    if (resolved is PdfNumber) return resolved.intValue;

    return null;
  }

  /// Per-family averages for the standard-14 fonts when the
  /// dictionary carries no `/Widths` (glyph-space units / 1000).
  static double _standard14Average(final String name) {
    final lower = name.toLowerCase();
    if (lower.contains('courier')) return 0.6;
    if (lower.contains('times')) return 0.512;
    if (lower.contains('helvetica') || lower.contains('arial')) return 0.556;

    return 0.5;
  }

  /// The standard-14 width row for a [name] (BaseFont): the exact
  /// entry first (case-insensitive), then family plus
  /// bold/oblique-italic suffix heuristics for look-alike names
  /// (`Arial-BoldMT` measures as Helvetica-Bold).
  static List<int?>? _standard14Row(final String name) {
    if (name.isEmpty) return null;
    final exact = pdfStandard14Widths['/$name'];
    if (exact != null) return exact;
    final lower = name.toLowerCase();
    for (final entry in pdfStandard14Widths.entries) {
      if (entry.key.substring(1).toLowerCase() == lower) return entry.value;
    }
    final bold = lower.contains('bold');
    final italic = lower.contains('italic') || lower.contains('oblique');
    String family;
    if (lower.contains('symbol')) {
      family = 'Symbol';
    } else if (lower.contains('zapf')) {
      family = 'ZapfDingbats';
    } else if (lower.contains('courier') || lower.contains('mono')) {
      family = 'Courier';
    } else if (lower.contains('times') || lower.contains('serif')) {
      family = 'Times';
    } else if (lower.contains('helvetica') || lower.contains('arial') || lower.contains('sans')) {
      family = 'Helvetica';
    } else {
      return null;
    }
    if (family == 'Symbol' || family == 'ZapfDingbats') {
      return pdfStandard14Widths['/$family'];
    }
    final oblique = family == 'Times' ? 'Italic' : 'Oblique';
    final base = family == 'Times' ? '-Roman' : '';
    String suffix;
    if (bold && italic) {
      suffix = '-Bold$oblique';
    } else if (bold) {
      suffix = '-Bold';
    } else if (italic) {
      suffix = '-$oblique';
    } else {
      suffix = base;
    }

    return pdfStandard14Widths['/$family$suffix'];
  }
}
