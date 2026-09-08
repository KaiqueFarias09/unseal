import 'dart:typed_data';

import 'package:e_livre/src/features/detection/entities/detected_format.dart';
import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';
import 'package:e_livre/src/foundation/utils/xml_encoding.dart';

const _pdfMagic = <int>[0x25, 0x50, 0x44, 0x46];

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
/// Throws [FormatNotSupportedException] for known-but-unsupported formats (Topaz, KFX, RTF) and for
/// unrecognized data.
DetectedFormat detectFormat(final Uint8List bytes) {
  const tpzMagic = <int>[0x54, 0x50, 0x5A];
  const kfxMagic = <int>[0xEA, 0x44, 0x52, 0x4D, 0x49, 0x4F, 0x4E, 0xEE];
  const rtfMagic = <int>[0x7B, 0x5C, 0x72, 0x74, 0x66];
  const sevenZipMagic = <int>[0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C];

  if (bytes.isEmpty) {
    throw const FormatNotSupportedException('Cannot detect format of empty bytes.');
  }

  if (_hasPrefix(bytes, tpzMagic)) {
    throw const FormatNotSupportedException('Amazon Topaz books (.azw1/.tpz) are not supported.');
  }

  if (_hasPrefix(bytes, kfxMagic)) {
    throw const FormatNotSupportedException('Amazon KFX books are not supported.');
  }
  if (_pdfHeaderOffset(bytes) != null) return DetectedFormat.pdf;

  if (_hasPrefix(bytes, rtfMagic)) {
    throw const FormatNotSupportedException('RTF books are not supported.');
  }

  // Zip container. EPUB, zipped FB2 and CBZ are the supported zip books; the dispatcher refines by
  // content.
  if (bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) return DetectedFormat.epub;
  if (_hasPrefix(bytes, sevenZipMagic)) return DetectedFormat.comic7;
  if (_isRar(bytes)) return DetectedFormat.comic;

  if (_isMobiFamily(bytes)) {
    return _isAzw4(bytes) ? DetectedFormat.azw4 : DetectedFormat.mobiFamily;
  }
  if (_isFictionBook(bytes)) return DetectedFormat.fb2;
  if (_isHtml(bytes)) return DetectedFormat.html;
  if (_isText(bytes)) return DetectedFormat.txt;

  throw const FormatNotSupportedException('Unrecognized book format.');
}

bool _containsSequence(final Uint8List bytes, final List<int> sequence) {
  for (var offset = 0; offset + sequence.length <= bytes.length; offset++) {
    if (_hasSequenceAt(bytes, offset, sequence)) return true;
  }

  return false;
}

bool _isFictionBook(final Uint8List bytes) {
  // Decode before sniffing so BOM-marked UTF-16 FB2 files use the same path as the parser. The
  // lexical preamble walk is deliberately bounded.
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

int? _pdfHeaderOffset(final Uint8List bytes) {
  const maxPdfPreambleBytes = 1024;
  final lastOffset = bytes.length - _pdfMagic.length;
  if (lastOffset < 0) return null;

  final boundedLastOffset = lastOffset < maxPdfPreambleBytes ? lastOffset : maxPdfPreambleBytes;
  for (var offset = 0; offset <= boundedLastOffset; offset++) {
    if (!_hasSequenceAt(bytes, offset, _pdfMagic)) continue;

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

bool _isHtml(final Uint8List bytes) {
  final limit = bytes.length < 8192 ? bytes.length : 8192;
  final head = decodeXmlText(bytes.sublist(0, limit)).trimLeft().toLowerCase();
  if (head.startsWith('<!doctype html')) return true;
  if (head.startsWith('<html') || head.startsWith('<head') || head.startsWith('<body')) return true;

  return RegExp(r'<html(?:\s|>)').hasMatch(head);
}

bool _isText(final Uint8List bytes) {
  if (_containsSequence(bytes, _pdfMagic)) return false;
  if (_hasTextUnicodeSignature(bytes)) return true;

  final byteLimit = bytes.length < 8192 ? bytes.length : 8192;
  var printableCount = 0;
  var controlCount = 0;

  for (var index = 0; index < byteLimit; index++) {
    final byte = bytes[index];
    if (byte == 0) return false;

    if (byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte >= 0x20) {
      printableCount++;

      continue;
    }

    controlCount++;
  }
  if (byteLimit == 0 || controlCount > byteLimit ~/ 20) return false;

  return printableCount * 100 >= byteLimit * 85;
}

bool _isAzw4(final Uint8List bytes) {
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

bool _hasPrefix(final Uint8List bytes, final List<int> magic) {
  if (bytes.length < magic.length) return false;

  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }

  return true;
}

bool _hasSequenceAt(final Uint8List bytes, final int offset, final List<int> magic) {
  if (offset < 0 || offset + magic.length > bytes.length) return false;

  for (var i = 0; i < magic.length; i++) {
    if (bytes[offset + i] != magic[i]) return false;
  }

  return true;
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

bool _isXmlWhitespace(final int codeUnit) {
  return codeUnit == 0x20 || codeUnit == 0x09 || codeUnit == 0x0A || codeUnit == 0x0D;
}

bool _isPdfWhitespace(final int byte) {
  return byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20;
}

bool _isRar(final Uint8List bytes) {
  return bytes.length >= 8 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x61 &&
      bytes[2] == 0x72 &&
      bytes[3] == 0x21 &&
      bytes[4] == 0x1A &&
      bytes[5] == 0x07;
}

bool _isMobiFamily(final Uint8List bytes) {
  if (bytes.length < 68) return false;

  final ident = String.fromCharCodes(bytes.sublist(60, 68)).toUpperCase();

  return ident == 'BOOKMOBI' || ident == 'TEXTREAD';
}
