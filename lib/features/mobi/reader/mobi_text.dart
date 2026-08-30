import 'dart:typed_data';

import 'package:e_livre/features/mobi/compression/huff_cdic.dart';
import 'package:e_livre/features/mobi/compression/palmdoc.dart';
import 'package:e_livre/features/mobi/exceptions/mobi_exception.dart';
import 'package:e_livre/features/mobi/header/mobi_header.dart';
import 'package:e_livre/features/mobi/utils/trailing_bytes.dart';

/// Extracts and decompresses the raw text stream of a MOBI book.
///
/// [recordAt] provides PDB record access, [textOffset] is the first
/// text record index (1 for standalone files, the KF8 boundary + 2
/// for joint files) and [huffOffsetOverride] rebases the HUFF section
/// for joint files.
Uint8List extractMobiText({
  required final Uint8List Function(int) recordAt,
  required final int recordCount,
  required final int textOffset,
  required final MobiHeader header,
  final int? huffOffsetOverride,
}) {
  final end = header.textRecordCount + textOffset < recordCount
      ? header.textRecordCount + textOffset
      : recordCount;

  Uint8List Function(Uint8List) unpack;
  if (header.compressionType == 0x4448) {
    final huffOffset = huffOffsetOverride ?? header.huffOffset;
    final sections = <Uint8List>[];
    for (var i = huffOffset; i < huffOffset + header.huffRecordCount; i++) {
      if (i >= recordCount) break;
      sections.add(recordAt(i));
    }
    final huff = HuffReader(sections);
    unpack = huff.unpack;
  } else if (header.compressionType == 2) {
    unpack = decompressPalmdoc;
  } else if (header.compressionType == 1) {
    unpack = (final data) => data;
  } else {
    throw MobiException(
      'Unknown compression algorithm: ${header.compressionType}',
    );
  }

  final builder = BytesBuilder(copy: false);
  for (var i = textOffset; i < end; i++) {
    final stripped = stripTrailingEntries(recordAt(i), header.extraFlags);
    builder.add(unpack(stripped));
  }
  var html = builder.takeBytes();

  if (html.isNotEmpty && html[html.length - 1] == 0x23) {
    html = Uint8List.sublistView(html, 0, html.length - 1);
  }

  // Strip control bytes that survive in some encodings, copying the
  // intact spans in bulk instead of byte by byte.
  final isCp1252 = header.codec == 'cp1252';
  final output = BytesBuilder(copy: false);
  var spanStart = 0;
  for (var i = 0; i < html.length; i++) {
    final byte = html[i];
    final bad = byte == 0x00 || (isCp1252 && (byte == 0x1E || byte == 0x02));
    if (!bad) {
      continue;
    }
    output.add(Uint8List.sublistView(html, spanStart, i));
    spanStart = i + 1;
  }
  output.add(Uint8List.sublistView(html, spanStart));
  return output.takeBytes();
}
