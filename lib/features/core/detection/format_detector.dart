import 'dart:typed_data';

import 'package:e_livre/features/core/entities/book_format.dart';
import 'package:e_livre/features/core/exceptions/elivre_exception.dart';

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
}

/// Sniffs the book format of [bytes] from its magic bytes.
///
/// Only the first bytes of the file are inspected:
///
/// * `PK` zip container → [DetectedFormat.epub]
/// * `BOOKMOBI` / `TEXTREAD` at offset 60 → [DetectedFormat.mobiFamily]
/// * `<?xml` / `<FictionBook` prologue → [DetectedFormat.fb2]
///
/// Throws [FormatNotSupportedException] for known-but-unsupported formats
/// (Topaz, KFX, PDF) and for unrecognized data.
DetectedFormat detectFormat(final Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const FormatNotSupportedException(
      'Cannot detect format of empty bytes.',
    );
  }

  if (_startsWith(bytes, _tpzMagic)) {
    throw const FormatNotSupportedException(
      'Amazon Topaz books (.azw1/.tpz) are not supported.',
    );
  }
  if (_startsWith(bytes, _kfxMagic)) {
    throw const FormatNotSupportedException(
      'Amazon KFX books are not supported.',
    );
  }
  if (_startsWith(bytes, _pdfMagic)) {
    throw const FormatNotSupportedException(
      'PDF books are not supported.',
    );
  }
  if (_startsWith(bytes, _rtfMagic)) {
    throw const FormatNotSupportedException(
      'RTF books are not supported.',
    );
  }

  if (bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
    // Zip container. EPUB, zipped FB2 and CBZ are the supported zip
    // books; the dispatcher refines by content.
    return DetectedFormat.epub;
  }

  // RAR 4 / RAR 5 signature -> comic (CBR).
  if (bytes.length >= 8 &&
      bytes[0] == 0x52 && bytes[1] == 0x61 && bytes[2] == 0x72 &&
      bytes[3] == 0x21 && bytes[4] == 0x1A && bytes[5] == 0x07) {
    return DetectedFormat.comic;
  }

  if (bytes.length >= 68) {
    final ident = String.fromCharCodes(bytes.sublist(60, 68));
    final upperIdent = ident.toUpperCase();
    if (upperIdent == 'BOOKMOBI' || upperIdent == 'TEXTREAD') {
      return DetectedFormat.mobiFamily;
    }
  }

  if (_looksLikeFictionBook(bytes)) {
    return DetectedFormat.fb2;
  }

  throw const FormatNotSupportedException(
    'Unrecognized book format.',
  );
}

/// Refines the [BookFormat] for MOBI family bytes.
///
/// Reads the PDB record table and the MOBI header to distinguish
/// MOBI 6 from KF8 (AZW3).
BookFormat refineMobiFormat(final Uint8List bytes) {
  final record0Offset = _recordOffset(bytes, 0);
  if (bytes.length < record0Offset + 0x6C + 4) {
    return BookFormat.mobi;
  }
  final byteData = ByteData.sublistView(bytes);
  final mobiVersion =
      byteData.getUint32(record0Offset + 0x68);
  return mobiVersion == 8 ? BookFormat.azw3 : BookFormat.mobi;
}

int _recordOffset(final Uint8List bytes, final int record) {
  final byteData = ByteData.sublistView(bytes);
  return byteData.getUint32(78 + record * 8);
}

const List<int> _tpzMagic = [0x54, 0x50, 0x5A]; // 'TPZ'
const List<int> _kfxMagic = [0xEA, 0x44, 0x52, 0x4D, 0x49, 0x4F, 0x4E, 0xEE];
const List<int> _pdfMagic = [0x25, 0x50, 0x44, 0x46]; // '%PDF'
const List<int> _rtfMagic = [0x7B, 0x5C, 0x72, 0x74, 0x66]; // '{\rtf'

bool _startsWith(final Uint8List bytes, final List<int> magic) {
  if (bytes.length < magic.length) {
    return false;
  }
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) {
      return false;
    }
  }
  return true;
}

bool _looksLikeFictionBook(final Uint8List bytes) {
  // Skip UTF-8 BOM and leading whitespace, then accept either a raw
  // <FictionBook root or an <?xml prologue followed by <FictionBook
  // within the first bytes of the document.
  var start = 0;
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    start = 3;
  }
  while (start < bytes.length &&
      (bytes[start] == 0x20 || bytes[start] == 0x0A || bytes[start] == 0x0D || bytes[start] == 0x09)) {
    start++;
  }
  final window = bytes.sublist(
    start,
    bytes.length < start + 1024 ? bytes.length : start + 1024,
  );
  if (window.isEmpty) {
    return false;
  }
  final head = String.fromCharCodes(window);
  if (head.startsWith('<FictionBook')) {
    return true;
  }
  return head.startsWith('<?xml') && head.contains('<FictionBook');
}
