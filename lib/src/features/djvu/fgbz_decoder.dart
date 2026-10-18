import 'dart:typed_data';

import 'bzz_decoder.dart';
import 'djvu_decode_budget.dart';
import 'djvu_exception.dart';

/// The DjVu 3 spec (§8.3.10) stores the palette size in an INT16 field.
const _maxFgbzPaletteEntries = 0xFFFF;

/// Color indices arrive as one INT16 per Sjbz blit. The JB2 record budget
/// already caps the blit count a page can carry, so a longer sequence could
/// never be consumed by any page.
const _maxFgbzColorEntries = 65536;

/// The decoded FGbz foreground palette of one page.
///
/// [rgb] holds three bytes (red, green, blue) per palette entry; the bytes
/// on disk are B,G,R (spec §8.3.10) and are converted here. [colorIndices]
/// carries one palette index per Sjbz blit in decode order, or null when the
/// chunk's version byte declares palette data only — the format's black-ink
/// default, identical to a page without an FGbz chunk.
final class DjvuFgbzPalette {
  /// Creates a palette around its converted entries and optional indices.
  const DjvuFgbzPalette({required this.rgb, required this.colorIndices});

  /// Interleaved red, green, blue palette entries.
  final Uint8List rgb;

  /// Per-blit palette indices, or null without color data.
  final List<int>? colorIndices;

  /// Whether the chunk declares the per-blit color sequence.
  ///
  /// A false value means the format's black-ink default: the palette exists
  /// but no blit is colored.
  bool get hasColorData => colorIndices != null;
}

/// Decodes an FGbz chunk (DjVu 3 spec §8.3.10, native reference
/// `DjVuPalette::decode`).
///
/// The version byte's low seven bits must be zero; bit 7 selects the
/// per-blit color sequence. Every declaration is validated against the
/// chunk's real bytes before its buffers are allocated, so truncated
/// palettes, truncated color streams, and out-of-range indices fail with
/// [DjvuException] without materializing output.
DjvuFgbzPalette decodeDjvuFgbz(final Uint8List encoded, {final DjvuDecodeBudget? budget}) {
  if (encoded.isEmpty) {
    throw const DjvuException('Truncated DjVu FGbz chunk.');
  }
  final version = encoded[0];
  if (version & 0x7F != 0) {
    throw DjvuException('DjVu FGbz version ${version & 0x7F} is outside the supported set.');
  }
  if (encoded.length < 3) {
    throw const DjvuException('Truncated DjVu FGbz palette header.');
  }
  final paletteSize = ByteData.sublistView(encoded).getUint16(1);
  final paletteBytes = paletteSize * 3;
  if (paletteSize > _maxFgbzPaletteEntries || encoded.length < 3 + paletteBytes) {
    throw const DjvuException('DjVu FGbz palette is truncated or oversized.');
  }
  budget?.reserve(pixels: 0, rasterBytes: paletteBytes);
  final rgb = Uint8List(paletteBytes);
  for (var entry = 0; entry < paletteSize; entry++) {
    final source = 3 + entry * 3;
    rgb[source - 3] = encoded[source + 2];
    rgb[source - 2] = encoded[source + 1];
    rgb[source - 1] = encoded[source];
  }
  if (version & 0x80 == 0) {
    return DjvuFgbzPalette(rgb: rgb, colorIndices: null);
  }

  final colorDataHeader = 3 + paletteBytes;
  if (encoded.length < colorDataHeader + 3) {
    throw const DjvuException('Truncated DjVu FGbz color data header.');
  }
  final dataSize =
      (encoded[colorDataHeader] << 16) |
      (encoded[colorDataHeader + 1] << 8) |
      encoded[colorDataHeader + 2];
  if (dataSize > _maxFgbzColorEntries) {
    throw const DjvuException('DjVu FGbz exceeds the 65536-color-index limit.');
  }
  // BZZ keeps decoded blocks, its concatenation and BWT work arrays.
  // Reserve their worst case plus typed indices and fixed contexts first.
  budget?.reserve(pixels: 0, rasterBytes: dataSize * 2 * 9 + 8192);
  final indicesBytes = decodeDjvuBzz(
    Uint8List.sublistView(encoded, colorDataHeader + 3),
    truncatedMessage: 'Truncated DjVu FGbz color index stream.',
    maxOutputBytes: dataSize * 2,
  );
  if (indicesBytes.length != dataSize * 2) {
    throw const DjvuException('DjVu FGbz color indices are truncated.');
  }
  final indices = Uint16List(dataSize);
  for (var entry = 0; entry < dataSize; entry++) {
    final index = (indicesBytes[entry * 2] << 8) | indicesBytes[entry * 2 + 1];
    if (index >= paletteSize) {
      throw const DjvuException('DjVu FGbz color index exceeds the palette.');
    }
    indices[entry] = index;
  }
  return DjvuFgbzPalette(rgb: rgb, colorIndices: indices);
}
