/// Structural hostile constructions targeting known parser stresses.
///
/// Every builder is deterministic and sized by explicit parameters so
/// the quick suites use small amplifications while campaign runs can
/// escalate. These prove (or disprove) the memory-boundedness and
/// recursion invariants; a violation becomes a guard + regression
/// test, never a silently tolerated input.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Builds a PDF with a stream object filtered through [filters]
/// (arbitrary chain) whose compressed payload is [streamData], plus a
/// minimal catalog/page spine so detection and parsing proceed to the
/// stream decoder.
Uint8List buildFilteredPdf(final List<String> filters, final List<int> streamData) {
  final out = BytesBuilder(copy: false);
  out.add('%PDF-1.7\n'.codeUnits);

  final offsets = <int, int>{};
  void beginObject(final int number) {
    offsets[number] = out.length;
    out.add('$number 0 obj\n'.codeUnits);
  }

  beginObject(1);
  out.add('<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'.codeUnits);
  beginObject(2);
  out.add('<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n'.codeUnits);
  beginObject(3);
  out.add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>\nendobj\n'.codeUnits);
  beginObject(4);
  final filterText = filters.isEmpty ? '' : ' /Filter [${filters.map((f) => '/$f').join(' ')}]';
  out.add('<< /Length ${streamData.length}$filterText >>\nstream\n'.codeUnits);
  out.add(streamData);
  out.add('\nendstream\nendobj\n'.codeUnits);

  final xrefOffset = out.length;
  out.add('xref\n0 5\n'.codeUnits);
  out.add('0000000000 65535 f \n'.codeUnits);
  for (var number = 1; number <= 4; number++) {
    out.add('${offsets[number]!.toString().padLeft(10, '0')} 00000 n \n'.codeUnits);
  }
  out.add('trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n$xrefOffset\n%%EOF'.codeUnits);

  return out.toBytes();
}

/// PDF whose page-tree object nests [depth] array levels deep —
/// probes the recursion invariants of the object parser.
Uint8List buildDeepNestedPdf(final int depth) {
  final out = BytesBuilder(copy: false);
  out.add('%PDF-1.7\n1 0 obj\n'.codeUnits);
  out.add(Uint8List.fromList(List<int>.filled(depth, 0x5B))); // '['
  out.add(Uint8List.fromList(List<int>.filled(depth, 0x5D))); // ']'
  out.add('\nendobj\ntrailer\n<< /Size 2 /Root 1 0 R >>\n%%EOF'.codeUnits);

  return out.toBytes();
}

/// Chained-FlateDecode amplification: [stages] nested filters, each
/// stage expanding a run of zero bytes, so a few hundred input bytes
/// decompress to roughly [targetBytes] when the parser trusts the
/// filter chain unconditionally.
Uint8List buildChainedFlatePdf({final int stages = 2, final int targetBytes = 8 << 20}) {
  var payload = Uint8List(targetBytes);
  for (var stage = 1; stage < stages; stage++) {
    payload = Uint8List.fromList(const ZLibEncoder().encode(payload));
  }
  final filters = List<String>.filled(stages, 'FlateDecode');

  return buildFilteredPdf(filters, payload);
}

/// LZW amplification: a small `/LZWDecode` stream whose dictionary
/// build-up expands to roughly [targetBytes] of output.
Uint8List buildLzwBombPdf({final int targetBytes = 16 << 20}) {
  return buildFilteredPdf(const <String>['LZWDecode'], encodePdfLzwZeros(targetBytes));
}

/// Encodes enough LZW codes (over a single repeated byte) to expand
/// to approximately [targetBytes] under PDF LZW semantics. The
/// KwKwK chain emits strings of length 1,2,3,… so m codes produce
/// O(m²) output while the input grows linearly.
Uint8List encodePdfLzwZeros(final int targetBytes) {
  const clearCode = 256;
  const eodCode = 257;

  var width = 9;
  var nextEntry = 258;
  var emitted = 1; // The literal below emits one byte.
  var previousLength = 1;
  final codes = <int>[clearCode, 0];

  while (emitted < targetBytes && nextEntry < 4096) {
    // KwKwK code: the entry being defined right now expands to
    // one byte more than the previous entry.
    codes.add(nextEntry);
    previousLength++;
    emitted += previousLength;
    nextEntry++;
    if (nextEntry + 1 == 512) {
      width = 10;
    } else if (nextEntry + 1 == 1024) {
      width = 11;
    } else if (nextEntry + 1 == 2048) {
      width = 12;
    }
  }
  codes.add(eodCode);

  final out = BytesBuilder(copy: false);
  var bitBuffer = 0;
  var bitCount = 0;
  for (final code in codes) {
    bitBuffer = (bitBuffer << width) | code;
    bitCount += width;
    while (bitCount >= 8) {
      bitCount -= 8;
      out.addByte((bitBuffer >> bitCount) & 0xFF);
    }
  }
  if (bitCount > 0) out.addByte((bitBuffer << (8 - bitCount)) & 0xFF);

  return out.toBytes();
}

/// EPUB-shaped zip whose single inflated entry expands to
/// [targetBytes] of zeros — the classic high-ratio archive bomb.
Uint8List buildZipBombEpub({final int targetBytes = 64 << 20}) {
  final zeros = Uint8List(targetBytes);
  final archive = Archive()
    ..addFile(
      ArchiveFile(
        'mimetype',
        'application/epub+zip'.length,
        Uint8List.fromList('application/epub+zip'.codeUnits),
      )..lastModTime = 946684800,
    )
    ..addFile(
      ArchiveFile('bomb.bin', zeros.length, Uint8List.fromList(const ZLibEncoder().encode(zeros)))
        ..lastModTime = 946684800,
    );

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// FB2 document nesting [depth] XML elements deep — probes XML tree
/// recursion limits.
Uint8List buildDeepNestedFb2(final int depth) {
  final body = StringBuffer()
    ..write('<?xml version="1.0" encoding="UTF-8"?>\n')
    ..write('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><body>')
    ..write('<section>' * depth)
    ..write('<p>leaf</p>')
    ..write('</section>' * depth)
    ..write('</body></FictionBook>');

  return Uint8List.fromList(body.toString().codeUnits);
}

/// MOBI PalmDB whose record table claims [recordCount] records while
/// the data section is unchanged — absurd counts probe record-table
/// validation and its allocation behavior.
Uint8List buildMobiLyingRecordCount(final Uint8List seed, final int recordCount) {
  // The PDB header ends with the record count at offset 76 (2 bytes,
  // big endian) followed by the record info list at 78.
  if (seed.length < 78) return seed;
  final out = Uint8List.fromList(seed);
  ByteData.sublistView(out).setUint16(76, recordCount.clamp(0, 0xFFFF));

  return out;
}
