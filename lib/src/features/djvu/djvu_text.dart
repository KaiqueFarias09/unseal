import 'dart:convert';
import 'dart:typed_data';

import 'bzz_decoder.dart';
import 'djvu_exception.dart';

/// Maximum decompressed size of one TXTz chunk, matching the uncompressed
/// OCR text bound applied to TXTa chunks.
const int _maxTextChunkBytes = 8 * 1024 * 1024;

/// Maximum number of zone records in one TXTz chunk.
const int _maxTextZones = 65536;

/// One TXTz hidden-text chunk: the page text plus its validated zone grammar.
final class DjvuTextChunk {
  const DjvuTextChunk._({required this.text, required this.zoneCount});

  /// Page text in reading order, with the zone separators rendered the way
  /// positional text extraction renders them: a page-zone NUL separator
  /// becomes LF followed by a form feed.
  final String text;

  /// Number of decoded zone records (page, column, region, paragraph, line,
  /// word, or character zones).
  final int zoneCount;
}

/// Decodes a BZZ-compressed TXTz chunk (DjVu 3 spec, §8.3.5).
///
/// The decompressed grammar is a 24-bit text length, the UTF-8 page text, a
/// version byte, and zero or more 17-byte zone records. Zone records are
/// validated (bounds, alignment, and record count) but only the text is
/// materialized. The version must be the specified value 1.
DjvuTextChunk decodeDjvuTextChunk(final Uint8List encoded) {
  final raw = decodeDjvuBzz(
    encoded,
    truncatedMessage: 'Truncated DjVu TXTz chunk.',
    maxOutputBytes: _maxTextChunkBytes,
  );
  if (raw.length < 4) {
    throw const DjvuException('Truncated DjVu TXTz text.');
  }
  final textLength = (raw[0] << 16) | (raw[1] << 8) | raw[2];
  if (textLength > raw.length - 4) {
    throw const DjvuException('Truncated DjVu TXTz text.');
  }
  if (raw[3 + textLength] != 1) {
    throw const DjvuException('Unsupported DjVu TXTz version.');
  }
  final zoneBytes = raw.length - 4 - textLength;
  if (zoneBytes % 17 != 0) {
    throw const DjvuException('DjVu TXTz zone records are misaligned.');
  }
  final zoneCount = zoneBytes ~/ 17;
  if (zoneCount > _maxTextZones) {
    throw const DjvuException('DjVu TXTz chunk exceeds the 65536-zone limit.');
  }

  final String text;
  try {
    text = utf8.decode(Uint8List.sublistView(raw, 3, 3 + textLength));
  } on FormatException {
    throw const DjvuException('DjVu TXTz text is not valid UTF-8.');
  }
  return DjvuTextChunk._(text: _renderPositional(text), zoneCount: zoneCount);
}

/// Renders the stored text with the separator convention of positional text
/// extraction: the NUL that separates page zones becomes LF + form feed.
String _renderPositional(final String text) {
  if (!text.contains('\x00')) return text;
  return text.replaceAll('\x00', '\n\x0C');
}
