import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'zip_builder.dart' show crc32;

// --- PNG ---

const List<int> _pngSignature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// Builds a minimal grayscale PNG, [width] x [height], bit depth 8.
///
/// Pixel rows are filled by [pixelAt] (row-major x, y -> luminance).
Uint8List buildPng(final int width, final int height, final int Function(int x, int y) pixelAt) {
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter type: none
    for (var x = 0; x < width; x++) {
      raw.addByte(pixelAt(x, y) & 0xFF);
    }
  }
  final ihdr = <int>[
    ..._u32(width),
    ..._u32(height),
    8, // bit depth
    0, // color type: grayscale
    0, // compression
    0, // filter
    0, // interlace
  ];
  final idat = Uint8List.fromList(ZLibEncoder(level: 6).convert(raw.toBytes()));
  return _pngFromChunks([
    _pngChunk('IHDR', ihdr),
    _pngChunk('IDAT', idat),
    _pngChunk('IEND', const []),
  ]);
}

/// Builds a 1x1 grayscale PNG ([shade] 0-255).
Uint8List tinyPng([final int shade = 0x80]) => buildPng(1, 1, (final _, final _) => shade);

/// Same as [tinyPng] but with a deliberately wrong IDAT CRC — structure
/// stays parseable for lenient decoders.
Uint8List pngWithBadCrc([final int shade = 0x40]) {
  final png = tinyPng(shade);
  final result = Uint8List.fromList(png);
  // The IDAT CRC is the last 4 bytes before IEND: locate IEND and walk back.
  final iendOffset = result.length - 12; // IEND: length(4) type(4) crc(4)
  result[iendOffset - 1] ^= 0xFF; // corrupt the CRC of the chunk preceding IEND
  return result;
}

/// A PNG truncated mid-IDAT: valid signature, IHDR, then a partial IDAT
/// chunk (declared length intact but bytes cut short) — no IEND.
Uint8List pngTruncatedIdat() {
  final full = buildPng(8, 8, (final x, final y) => (x * 16 + y * 8) & 0xFF);
  // Keep signature + IHDR + half of the IDAT chunk.
  const keep = 8 + 25 + 12; // signature + IHDR chunk + IDAT header
  return Uint8List.sublistView(full, 0, (keep + 8).clamp(0, full.length));
}

Uint8List _pngChunk(final String type, final List<int> data) {
  final out = BytesBuilder(copy: false);
  out.add(_u32(data.length));
  final typeBytes = utf8.encode(type);
  out.add(typeBytes);
  out.add(data);
  final crcInput = <int>[...typeBytes, ...data];
  out.add(_u32(crc32(crcInput)));
  return out.toBytes();
}

Uint8List _pngFromChunks(final List<Uint8List> chunks) {
  final out = BytesBuilder(copy: false);
  out.add(_pngSignature);
  for (final chunk in chunks) {
    out.add(chunk);
  }
  return out.toBytes();
}

// --- JPEG ---

/// Minimal baseline grayscale JPEG: 8x8, all-one quantization, one-symbol
/// Huffman tables (DC category 0, AC EOB share the single 1-bit code).
Uint8List tinyJpeg() {
  final out = BytesBuilder(copy: false);
  out.add(const [0xFF, 0xD8]); // SOI

  // DQT: table 0, all values 1.
  out.add(_marker(0xDB, [0x00, ...List<int>.filled(64, 1)]));

  // SOF0: 8-bit, 8x8, 1 component (Y), no subsampling.
  out.add(_marker(0xC0, [0x08, 0x00, 0x08, 0x00, 0x08, 0x01, 0x01, 0x11, 0x00]));

  // DHT segments carry SIXTEEN count bytes (codes per length 1..16).
  // DC (class 0, id 0): one code of length 1 -> symbol 0x00 (category 0).
  out.add(_marker(0xC4, [0x00, 0x01, ...List<int>.filled(15, 0), 0x00]));
  // AC (class 1, id 0): one code of length 1 -> symbol 0x00 (EOB).
  out.add(_marker(0xC4, [0x10, 0x01, ...List<int>.filled(15, 0), 0x00]));

  // SOS: 1 component, table ids 0/0.
  out.add(_marker(0xDA, [0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]));

  // Entropy data: DC 0 (bit 0), AC EOB (bit 0), pad with 1s.
  out.add(const [0x3F]);
  out.add(const [0xFF, 0xD9]); // EOI
  return out.toBytes();
}

/// JPEG cut inside the scan data: headers intact, no EOI — the classic
/// "progressive/lenient decoder salvage" shape.
Uint8List jpegTruncatedScan() {
  final full = tinyJpeg();
  return Uint8List.sublistView(full, 0, full.length - 2);
}

Uint8List _marker(final int type, final List<int> payload) {
  final length = payload.length + 2;
  return Uint8List.fromList([0xFF, type, (length >> 8) & 0xFF, length & 0xFF, ...payload]);
}

// --- GIF ---

/// Minimal GIF89a: logical screen 1x1 with a 2-color global color table
/// and a single-pixel image.
Uint8List tinyGif({final int variant = 0}) {
  final out = BytesBuilder(copy: false);
  out.add(utf8.encode(variant.isEven ? 'GIF89a' : 'GIF87a'));
  // Logical screen descriptor: width, height, packed (GCT, 2 colors), bg, aspect.
  out.add(const [0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00]);
  // Global color table: black, white.
  out.add(const [0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF]);
  // Image descriptor: separator, left/top/w/h, packed (no LCT).
  out.add(const [0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]);
  // LZW minimum code size for a 2-color table.
  out.addByte(0x02);
  // Image data: clear (100), pixel index 1 (001), EOD (101) — 9 bits,
  // MSB-first packed into 0x86, 0x80; then the zero-length block terminator.
  out.add(const [0x02, 0x86, 0x80, 0x00]);
  out.addByte(0x3B); // trailer
  return out.toBytes();
}

Uint8List _u32(final int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);
