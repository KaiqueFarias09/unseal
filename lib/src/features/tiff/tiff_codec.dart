import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'tiff_ccitt_decoder.dart';
import 'tiff_exception.dart';

/// The TIFF compression id for uncompressed data.
const tiffCompressionNone = 1;

/// The TIFF compression id for CCITT modified Huffman (Group 3 1D).
const tiffCompressionCcittModifiedHuffman = 2;

/// The TIFF compression id for CCITT Group 3 fax.
const tiffCompressionCcittG3 = 3;

/// The TIFF compression id for CCITT Group 4 fax.
const tiffCompressionCcittG4 = 4;

/// The TIFF compression id for LZW.
const tiffCompressionLzw = 5;

/// The TIFF compression id for the pre-6.0 JPEG scheme (never decoded).
const tiffCompressionOldJpeg = 6;

/// The TIFF compression id for JPEG-in-TIFF.
const tiffCompressionJpeg = 7;

/// The TIFF compression id for Deflate.
const tiffCompressionDeflate = 8;

/// The TIFF compression id for PackBits.
const tiffCompressionPackbits = 32773;

/// The TIFF compression id for Adobe Deflate.
const tiffCompressionAdobeDeflate = 32946;

/// The human-readable codec name for typed failure messages.
String tiffCompressionName(final int compression) => switch (compression) {
  tiffCompressionNone => 'none',
  tiffCompressionCcittModifiedHuffman => 'CCITT modified Huffman (2)',
  tiffCompressionCcittG3 => 'CCITT Group 3 (3)',
  tiffCompressionCcittG4 => 'CCITT Group 4 (4)',
  tiffCompressionLzw => 'LZW (5)',
  tiffCompressionOldJpeg => 'old-style JPEG (6)',
  tiffCompressionJpeg => 'JPEG-in-TIFF (7)',
  tiffCompressionDeflate => 'Deflate (8)',
  tiffCompressionPackbits => 'PackBits (32773)',
  tiffCompressionAdobeDeflate => 'Adobe Deflate (32946)',
  _ => 'compression $compression',
};

/// The strict-decoder layout of one CCITT strip or tile.
///
/// [fallbackPlan] covers the real-world Group 3 producers that omit
/// the end-of-line codes the spec requires.
final class TiffCcittPlan {
  /// Creates the strip layout.
  const TiffCcittPlan({
    required this.mode,
    required this.byteAlignedRows,
    required this.endOfLine,
    this.fallbackPlan,
  });

  /// The T.4/T.6 coding.
  final TiffCcittMode mode;

  /// Whether rows start on byte boundaries.
  final bool byteAlignedRows;

  /// Whether end-of-line codes precede rows.
  final bool endOfLine;

  /// The layout retried when the primary one decodes short (real-world
  /// Group 3 producers that omit the end-of-line codes).
  final TiffCcittPlan? fallbackPlan;
}

/// Decodes one strip or tile of [compression] data to at least
/// [expectedBytes] bytes (row-aligned), returning the decoded buffer.
///
/// [expectedBytes] is the exact row-aligned payload size the page
/// geometry computed; it is also the hard output cap for the decoders
/// that can be bounded mid-stream (LZW, PackBits), so a hostile strip
/// cannot expand past its declared geometry. Zlib streams cannot be
/// pre-sized, so Deflate is validated right after the decode.
Uint8List decodeTiffSegment(
  final Uint8List encoded, {
  required final int compression,
  required final int expectedBytes,
  final TiffCcittPlan? ccittPlan,
  final int ccittColumns = 0,
  final int ccittRowBytes = 1,
}) {
  if (expectedBytes <= 0) {
    throw const TiffException('TIFF strip geometry decodes to no bytes.');
  }
  switch (compression) {
    case tiffCompressionNone:
      if (encoded.length < expectedBytes) {
        throw TiffException(
          'Uncompressed TIFF strip holds ${encoded.length} bytes; '
          'its geometry needs $expectedBytes.',
        );
      }
      return Uint8List.sublistView(encoded, 0, expectedBytes);
    case tiffCompressionCcittModifiedHuffman:
    case tiffCompressionCcittG3:
    case tiffCompressionCcittG4:
      return _decodeTiffCcitt(
        encoded,
        plan: ccittPlan!,
        expectedBytes: expectedBytes,
        columns: ccittColumns,
        rowBytes: ccittRowBytes,
      );
    case tiffCompressionLzw:
      return decodeTiffLzw(encoded, maxOutputBytes: expectedBytes);
    case tiffCompressionDeflate:
    case tiffCompressionAdobeDeflate:
      return _decodeTiffDeflate(encoded, expectedBytes: expectedBytes);
    case tiffCompressionPackbits:
      return decodeTiffPackBits(encoded, maxOutputBytes: expectedBytes);
    default:
      throw TiffUnsupportedCodecException(
        'TIFF page needs the unsupported ${tiffCompressionName(compression)} codec.',
      );
  }
}

/// Decodes a Deflate/AdobeDeflate strip and validates the size.
Uint8List _decodeTiffDeflate(final Uint8List encoded, {required final int expectedBytes}) {
  final Uint8List decoded;
  try {
    decoded = Uint8List.fromList(const ZLibDecoder().decodeBytes(encoded));
  } on FormatException catch (error) {
    throw TiffException('TIFF Deflate strip failed to decompress: ${error.message}.');
  }
  if (decoded.length < expectedBytes) {
    throw TiffException(
      'TIFF Deflate strip decompressed to ${decoded.length} bytes; '
      'its geometry needs $expectedBytes.',
    );
  }
  return Uint8List.sublistView(decoded, 0, expectedBytes);
}

/// Decodes one CCITT strip through the strict decoder and validates
/// the row-aligned payload; on a short decode, the fallback layout
/// (Group 3 without end-of-line codes) is tried once.
Uint8List _decodeTiffCcitt(
  final Uint8List encoded, {
  required final TiffCcittPlan plan,
  required final int expectedBytes,
  required final int columns,
  required final int rowBytes,
}) {
  Uint8List attempt(final TiffCcittPlan attemptPlan) {
    final decoded = decodeTiffCcittStrip(
      encoded,
      mode: attemptPlan.mode,
      columns: columns,
      rows: expectedBytes ~/ rowBytes,
      byteAlignedRows: attemptPlan.byteAlignedRows,
      endOfLine: attemptPlan.endOfLine,
    );
    if (decoded.length < expectedBytes) {
      throw TiffException(
        'TIFF CCITT strip decoded ${decoded.length} bytes; '
        'its geometry needs $expectedBytes.',
      );
    }
    return decoded;
  }

  try {
    return attempt(plan);
  } on TiffException {
    final fallback = plan.fallbackPlan;
    if (fallback == null) rethrow;
    return attempt(fallback);
  }
}

/// Expands a PackBits (Apple RLE, TIFF compression 32773) segment.
///
/// Signed run counts: 0..127 copies the next n+1 bytes, -1..-127
/// repeats the following byte 1-n times, -128 is a no-op. The decoder
/// stops at [maxOutputBytes], so a hostile run cannot grow past the
/// geometry the page computed.
Uint8List decodeTiffPackBits(final Uint8List encoded, {required final int maxOutputBytes}) {
  final out = BytesBuilder(copy: false);
  var position = 0;
  while (position < encoded.length) {
    final control = encoded[position++];
    final remaining = maxOutputBytes - out.length;
    if (remaining == 0) break; // Trailing rows past the geometry are ignored.
    if (control & 0x80 == 0) {
      final count = control + 1;
      if (position + count > encoded.length) {
        throw const TiffException('TIFF PackBits strip overruns its bounds.');
      }
      final take = count < remaining ? count : remaining;
      out.add(Uint8List.sublistView(encoded, position, position + take));
      position += count;
    } else if (control != 0x80) {
      // Signed count: 0x81..0xFF means repeat the next byte 257-control times.
      if (position >= encoded.length) {
        throw const TiffException('TIFF PackBits strip overruns its bounds.');
      }
      final repeat0 = 257 - control;
      final repeat = repeat0 < remaining ? repeat0 : remaining;
      out.add(Uint8List(repeat)..fillRange(0, repeat, encoded[position]));
      position++;
    }
  }
  final decoded = out.toBytes();
  if (decoded.length < maxOutputBytes) {
    throw TiffException(
      'TIFF PackBits strip decompressed to ${decoded.length} bytes; '
      'its geometry needs $maxOutputBytes.',
    );
  }
  return decoded;
}

/// Expands a TIFF LZW segment (compression 5).
///
/// Standard TIFF packs codes most-significant-bit first (the same
/// packing as the PDF LZWDecode filter) and uses mandatory early
/// change: the code width grows from 9 to 12 bits when the dictionary
/// reaches 511/1023/2047 entries. Pre-6.0 producers wrote bit-reversed
/// codes; libtiff's detection heuristic (`first byte 0x00, second byte
/// odd`, satisfied for example by libtiff's `quad-lzw-compat`
/// regression file) selects the least-significant-bit reader for
/// those. The output is capped at [maxOutputBytes] while decoding, so
/// a hostile strip cannot expand past the page geometry.
Uint8List decodeTiffLzw(final Uint8List encoded, {required final int maxOutputBytes}) {
  final bitReversed = encoded.length >= 2 && encoded[0] == 0 && encoded[1] & 0x1 != 0;
  final table = List<Uint8List?>.filled(4096, null);
  for (var i = 0; i < 256; i++) {
    table[i] = Uint8List(1)..[0] = i;
  }
  var nextEntry = 258;
  var width = 9;
  Uint8List? previous;

  final out = BytesBuilder(copy: false);
  var bitBuffer = 0;
  var bitCount = 0;
  var cursor = 0;
  while (true) {
    while (bitCount < width) {
      if (cursor >= encoded.length) {
        // A missing end-of-information code ends the segment; the
        // caller validates the decoded size against the geometry.
        return _finishTiffLzw(out, maxOutputBytes);
      }
      if (bitReversed) {
        bitBuffer |= encoded[cursor++] << bitCount;
        bitCount += 8;
      } else {
        bitBuffer = (bitBuffer << 8) | encoded[cursor++];
        bitCount += 8;
      }
    }
    final int code;
    if (bitReversed) {
      code = bitBuffer & ((1 << width) - 1);
      bitBuffer >>= width;
      bitCount -= width;
    } else {
      bitCount -= width;
      code = (bitBuffer >> bitCount) & ((1 << width) - 1);
      bitBuffer &= (1 << bitCount) - 1;
    }

    if (code == 257) break; // EndOfInformation
    if (code == 256) {
      // ClearCode: reset the dictionary and the code width.
      nextEntry = 258;
      width = 9;
      previous = null;

      continue;
    }

    Uint8List entry;
    if (code < nextEntry) {
      entry = table[code]!;
    } else if (code == nextEntry && previous != null) {
      // The KwKwK case: the entry being defined right now.
      entry = Uint8List(previous.length + 1)
        ..setRange(0, previous.length, previous)
        ..[previous.length] = previous[0];
    } else {
      throw const TiffException('TIFF LZW strip hit a code outside the dictionary.');
    }
    final remaining = maxOutputBytes - out.length;
    if (remaining == 0) break; // Trailing rows past the geometry are ignored.
    if (entry.length > remaining) {
      out.add(Uint8List.sublistView(entry, 0, remaining));
      break;
    }
    out.add(entry);

    if (previous != null && nextEntry < 4096) {
      table[nextEntry++] = Uint8List(previous.length + 1)
        ..setRange(0, previous.length, previous)
        ..[previous.length] = entry[0];
      // TIFF early change: the width flips one code early.
      // Standard TIFF grows the width one code early; the bit-reversed
      // old-style format grows it exactly at the boundary.
      final flipAt = bitReversed ? nextEntry : nextEntry + 1;
      if (flipAt == 512) {
        width = 10;
      } else if (flipAt == 1024) {
        width = 11;
      } else if (flipAt == 2048) {
        width = 12;
      }
    }
    previous = entry;
  }

  return _finishTiffLzw(out, maxOutputBytes);
}

Uint8List _finishTiffLzw(final BytesBuilder out, final int maxOutputBytes) {
  final decoded = out.toBytes();
  if (decoded.length < maxOutputBytes) {
    throw TiffException(
      'TIFF LZW strip decompressed to ${decoded.length} bytes; '
      'its geometry needs $maxOutputBytes.',
    );
  }
  return decoded;
}

/// Builds the strict-decoder layout for one TIFF CCITT segment, or
/// throws [TiffUnsupportedCodecException] for layouts that are
/// deliberately not attempted (uncompressed-mode extensions, reversed
/// bit fill order).
TiffCcittPlan tiffCcittPlan({
  required final int compression,
  required final int t4Options,
  required final int t6Options,
  required final int fillOrder,
}) {
  if (fillOrder == 2) {
    throw const TiffUnsupportedCodecException(
      'TIFF page uses reversed bit fill order (FillOrder 2), not decoded.',
    );
  }
  switch (compression) {
    case tiffCompressionCcittModifiedHuffman:
      // Compression 2 rows each start on a byte boundary and carry no
      // end-of-line codes.
      return TiffCcittPlan(mode: TiffCcittMode.g3_1d, byteAlignedRows: true, endOfLine: false);
    case tiffCompressionCcittG3:
      if (t4Options & 0x2 != 0) {
        throw const TiffUnsupportedCodecException(
          'TIFF Group 3 page declares the uncompressed-mode extension (T4Options bit 1).',
        );
      }
      return TiffCcittPlan(
        mode: t4Options & 0x1 != 0 ? TiffCcittMode.g3_2d : TiffCcittMode.g3_1d,
        byteAlignedRows: t4Options & 0x4 != 0,
        endOfLine: true,
        // Real-world Group 3 producers exist that omit the end-of-line
        // codes the spec requires (libtiff's testfax3_bug54_1dnoEOL
        // regression file): retry with the rows decoded as a continuous
        // bit stream.
        fallbackPlan: TiffCcittPlan(
          mode: t4Options & 0x1 != 0 ? TiffCcittMode.g3_2d : TiffCcittMode.g3_1d,
          byteAlignedRows: false,
          endOfLine: false,
        ),
      );
    case tiffCompressionCcittG4:
      if (t6Options & 0x1 != 0) {
        throw const TiffUnsupportedCodecException(
          'TIFF Group 4 page declares the uncompressed-mode extension (T6Options bit 0).',
        );
      }
      return TiffCcittPlan(
        mode: TiffCcittMode.g4,
        byteAlignedRows: t6Options & 0x2 != 0,
        endOfLine: false,
      );
    default:
      throw TiffUnsupportedCodecException(
        'TIFF page needs the unsupported ${tiffCompressionName(compression)} codec.',
      );
  }
}

/// Throws [TiffUnsupportedCodecException] when [encoded] does not hold
/// one self-contained JPEG stream (SOI .. EOI) — the only JPEG-in-TIFF
/// layout Unseal passes through.
void requireSelfContainedTiffJpeg(final Uint8List encoded, {required final int strips}) {
  if (strips > 1 || encoded.length < 4 || encoded[0] != 0xFF || encoded[1] != 0xD8) {
    throw TiffUnsupportedCodecException(
      'TIFF JPEG page is not a single self-contained JPEG strip '
      '($strips strips; JPEGTables tiling is not decoded).',
    );
  }
  if (encoded[encoded.length - 2] != 0xFF || encoded[encoded.length - 1] != 0xD9) {
    throw const TiffException('TIFF JPEG strip does not end with an EOI marker.');
  }
}

/// Applies TIFF horizontal differencing (Predictor 2) over a decoded
/// segment in place.
///
/// Byte-wise accumulation with the already-accumulated left neighbor
/// is carry-correct for every byte-aligned sample size (8 and 16 bit),
/// in both byte orders. Non-byte-aligned depths never reach here; the
/// page decoder rejects them typed.
void applyTiffPredictor(
  final Uint8List data, {
  required final int rows,
  required final int rowBytes,
  required final int sampleBytes,
}) {
  for (var row = 0; row < rows; row++) {
    final base = row * rowBytes;
    for (var index = base + sampleBytes; index < base + rowBytes; index++) {
      data[index] = (data[index] + data[index - sampleBytes]) & 0xFF;
    }
  }
}
