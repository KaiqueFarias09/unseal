import 'dart:typed_data';

import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';
import 'package:e_livre/src/foundation/utils/xml_encoding.dart';

/// Selects a book format from its binary signature.
abstract final class BookFormatDetector {
  /// Detects the format family represented by [bytes].
  static DetectedFormat detect(final Uint8List bytes) => detectFormat(bytes);

  /// Resolves the concrete MOBI-family format represented by [bytes].
  static BookFormat refineMobi(final Uint8List bytes) => refineMobiFormat(bytes);
}

/// The book family detected from magic bytes.
///
/// Each family is handled by one format module which then refines the
/// concrete [BookFormat] (e.g. `mobi` versus `azw3`).
enum DetectedFormat {
  /// Zip container (EPUB, zipped FB2 or CBZ — refined by content).
  epub,

  /// PalmDB / MOBI family (MOBI 6, KF8 / AZW3, joint files).
  mobiFamily,

  /// FictionBook XML (or zipped FB2).
  fb2,

  /// Comic archive (RAR — CBR).
  comic,

  /// PDF document.
  pdf,

  /// Plain text document.
  txt,

  /// Standalone HTML document.
  html,

  /// AZW4 PalmDB wrapper containing a PDF payload.
  azw4,

  /// 7-Zip comic archive.
  comic7,
}

/// Sniffs the book format of [bytes] from its magic bytes.
///
/// Only a bounded prefix of the file is inspected:
///
/// * `PK` zip container → [DetectedFormat.epub]
/// * `BOOKMOBI` / `TEXTREAD` at offset 60 → [DetectedFormat.mobiFamily]
/// * `<?xml` / `<FictionBook` prologue → [DetectedFormat.fb2]
/// * an allowed short preamble followed by `%PDF` → [DetectedFormat.pdf]
/// * 7-Zip signature → [DetectedFormat.comic7]
/// * HTML prologue → [DetectedFormat.html]
/// * printable text → [DetectedFormat.txt]
///
/// Throws [FormatNotSupportedException] for known-but-unsupported formats
/// (Topaz, KFX, RTF) and for unrecognized data.
DetectedFormat detectFormat(final Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const FormatNotSupportedException('Cannot detect format of empty bytes.');
  }
  if (_startsWith(bytes, _tpzMagic)) {
    throw const FormatNotSupportedException('Amazon Topaz books (.azw1/.tpz) are not supported.');
  }
  if (_startsWith(bytes, _kfxMagic)) {
    throw const FormatNotSupportedException('Amazon KFX books are not supported.');
  }
  if (_pdfHeaderOffset(bytes) != null) return DetectedFormat.pdf;
  if (_startsWith(bytes, _rtfMagic)) {
    throw const FormatNotSupportedException('RTF books are not supported.');
  }
  if (bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    // Zip container. EPUB, zipped FB2 and CBZ are the supported zip
    // books; the dispatcher refines by content.
    return DetectedFormat.epub;
  }

  if (_startsWith(bytes, _sevenZipMagic)) return DetectedFormat.comic7;

  // RAR 4 / RAR 5 signature -> comic (CBR).
  if (bytes.length >= 8 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x61 &&
      bytes[2] == 0x72 &&
      bytes[3] == 0x21 &&
      bytes[4] == 0x1A &&
      bytes[5] == 0x07) {
    return DetectedFormat.comic;
  }

  if (bytes.length >= 68) {
    final ident = String.fromCharCodes(bytes.sublist(60, 68));
    final upperIdent = ident.toUpperCase();
    if (upperIdent == 'BOOKMOBI' || upperIdent == 'TEXTREAD') {
      return _looksLikeAzw4(bytes) ? DetectedFormat.azw4 : DetectedFormat.mobiFamily;
    }
  }
  if (_looksLikeFictionBook(bytes)) return DetectedFormat.fb2;
  if (_looksLikeHtml(bytes)) return DetectedFormat.html;
  if (_looksLikeText(bytes)) return DetectedFormat.txt;

  throw const FormatNotSupportedException('Unrecognized book format.');
}

/// Refines the [BookFormat] for MOBI family bytes.
///
/// Reads the PDB record table and the MOBI header to distinguish
/// MOBI 6 from KF8 (AZW3).
BookFormat refineMobiFormat(final Uint8List bytes) {
  final record0Offset = _recordOffset(bytes, 0);
  if (bytes.length < record0Offset + 0x6C + 4) return BookFormat.mobi;

  final byteData = ByteData.sublistView(bytes);
  final mobiVersion = byteData.getUint32(record0Offset + 0x68);

  return mobiVersion == 8 ? BookFormat.azw3 : BookFormat.mobi;
}

int _recordOffset(final Uint8List bytes, final int record) {
  final byteData = ByteData.sublistView(bytes);

  return byteData.getUint32(78 + record * 8);
}

const List<int> _tpzMagic = [0x54, 0x50, 0x5A];

const List<int> _kfxMagic = [0xEA, 0x44, 0x52, 0x4D, 0x49, 0x4F, 0x4E, 0xEE];

const List<int> _pdfMagic = [0x25, 0x50, 0x44, 0x46];

const List<int> _rtfMagic = [0x7B, 0x5C, 0x72, 0x74, 0x66];

const List<int> _sevenZipMagic = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C];

bool _startsWith(final Uint8List bytes, final List<int> magic) {
  if (bytes.length < magic.length) return false;

  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }

  return true;
}

bool _looksLikeFictionBook(final Uint8List bytes) {
  // Decode before sniffing so BOM-marked UTF-16 FB2 files use the same
  // path as the parser. The lexical preamble walk is deliberately bounded
  // and only skips XML constructs that are valid before the root element.
  final window = bytes.sublist(0, bytes.length < 4096 ? bytes.length : 4096);
  final head = decodeXmlText(window);
  var cursor = 0;
  while (cursor < head.length) {
    while (cursor < head.length && _isXmlWhitespace(head.codeUnitAt(cursor))) {
      cursor++;
    }
    if (head.startsWith('<?', cursor)) {
      final end = head.indexOf('?>', cursor + 2);
      if (end < 0) return false;
      cursor = end + 2;
      continue;
    }
    if (head.startsWith('<!--', cursor)) {
      final end = head.indexOf('-->', cursor + 4);
      if (end < 0) return false;
      cursor = end + 3;
      continue;
    }
    if (head.startsWith('<!DOCTYPE', cursor)) {
      final end = head.indexOf('>', cursor + 9);
      if (end < 0) return false;
      cursor = end + 1;
      continue;
    }
    break;
  }

  return RegExp(
        r'<(?:[A-Za-z_][\w.-]*:)?FictionBook(?:\s|>)',
        caseSensitive: false,
      ).matchAsPrefix(head, cursor) !=
      null;
}

bool _isXmlWhitespace(final int codeUnit) =>
    codeUnit == 0x20 || codeUnit == 0x09 || codeUnit == 0x0A || codeUnit == 0x0D;

int? _pdfHeaderOffset(final Uint8List bytes) {
  final lastOffset = bytes.length - _pdfMagic.length;
  if (lastOffset < 0) return null;

  final boundedLastOffset = lastOffset < _maxPdfPreambleBytes ? lastOffset : _maxPdfPreambleBytes;
  for (var offset = 0; offset <= boundedLastOffset; offset++) {
    if (!_startsAt(bytes, offset, _pdfMagic)) continue;

    var preambleEnd = 0;
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      preambleEnd = 3;
    }
    while (preambleEnd < offset && _isPdfWhitespace(bytes[preambleEnd])) {
      preambleEnd++;
    }
    if (preambleEnd == offset) return offset;
  }

  return null;
}

bool _startsAt(final Uint8List bytes, final int offset, final List<int> magic) {
  if (offset < 0 || offset + magic.length > bytes.length) return false;

  for (var i = 0; i < magic.length; i++) {
    if (bytes[offset + i] != magic[i]) return false;
  }

  return true;
}

bool _isPdfWhitespace(final int byte) =>
    byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20;

const int _maxPdfPreambleBytes = 1024;

bool _looksLikeHtml(final Uint8List bytes) {
  final limit = bytes.length < 8192 ? bytes.length : 8192;
  final head = decodeXmlText(bytes.sublist(0, limit)).trimLeft().toLowerCase();
  if (head.startsWith('<!doctype html')) return true;
  if (head.startsWith('<html') || head.startsWith('<head') || head.startsWith('<body')) return true;

  return RegExp(r'<html(?:\s|>)').hasMatch(head);
}

bool _looksLikeText(final Uint8List bytes) {
  if (_containsSequence(bytes, _pdfMagic)) return false;
  final bomText = _hasTextUnicodeSignature(bytes);
  if (bomText) return true;

  final limit = bytes.length < 8192 ? bytes.length : 8192;
  var printable = 0;
  var control = 0;
  for (var index = 0; index < limit; index++) {
    final value = bytes[index];
    if (value == 0) return false;
    if (value == 0x09 || value == 0x0A || value == 0x0C || value == 0x0D || value >= 0x20) {
      printable++;
    } else {
      control++;
    }
  }
  if (limit == 0 || control > limit ~/ 20) return false;

  return printable * 100 >= limit * 85;
}

bool _containsSequence(final Uint8List bytes, final List<int> sequence) {
  for (var offset = 0; offset + sequence.length <= bytes.length; offset++) {
    if (_startsAt(bytes, offset, sequence)) return true;
  }

  return false;
}

bool _hasTextUnicodeSignature(final Uint8List bytes) {
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    return true;
  }
  if (bytes.length >= 4 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE && bytes[2] == 0 && bytes[3] == 0) ||
          (bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xFE && bytes[3] == 0xFF))) {
    return true;
  }

  return false;
}

bool _looksLikeAzw4(final Uint8List bytes) {
  if (bytes.length < 86) return false;
  final view = ByteData.sublistView(bytes);
  final count = view.getUint16(76);
  if (count == 0 || 78 + count * 8 > bytes.length) return false;

  var previous = <int>[];
  for (var index = 0; index < count; index++) {
    final offset = view.getUint32(78 + index * 8);
    final next = index + 1 < count ? view.getUint32(78 + (index + 1) * 8) : bytes.length;
    if (offset >= next || next > bytes.length) continue;
    final record = bytes.sublist(offset, next);
    final stitched = <int>[...previous, ...record];
    if (_containsPdfSignature(stitched)) return true;
    previous = record.length < 3 ? record : record.sublist(record.length - 3);
  }

  return false;
}

bool _containsPdfSignature(final List<int> bytes) {
  for (var index = 0; index + 4 <= bytes.length; index++) {
    if (bytes[index] != 0x25 ||
        bytes[index + 1] != 0x50 ||
        bytes[index + 2] != 0x44 ||
        bytes[index + 3] != 0x46) {
      continue;
    }
    return true;
  }

  return false;
}
