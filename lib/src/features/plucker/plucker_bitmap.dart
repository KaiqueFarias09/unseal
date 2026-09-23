import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../foundation/exceptions/unseal_exception.dart';

/// Converts bounded Palm monochrome, grayscale, and standard-palette bitmaps
/// to PNG.
///
/// Custom color tables and internal compression are kept explicit so a reader
/// never receives an apparently valid but incorrectly colored image.
Uint8List decodePluckerBitmap(final Uint8List bitmap) {
  if (bitmap.length < 16) {
    throw const InvalidBookException('Truncated Plucker Palm bitmap.');
  }
  final header = ByteData.sublistView(bitmap);
  final width = header.getUint16(0);
  final height = header.getUint16(2);
  final rowBytes = header.getUint16(4);
  final flags = header.getUint16(6);
  final depth = bitmap[8];
  final version = bitmap[9];
  final compression = bitmap[13];
  final channels = depth == 8 ? 3 : 1;
  final minRowBytes = (width * depth + 7) ~/ 8;
  if (width == 0 ||
      height == 0 ||
      width * height * depth > 480000 ||
      rowBytes < minRowBytes ||
      rowBytes * height > 60000) {
    throw const InvalidBookException('Invalid Plucker Palm bitmap dimensions.');
  }
  if (!((depth == 1 && version == 0) ||
          ((depth == 2 || depth == 4 || depth == 8) && version == 1)) ||
      flags != 0 ||
      (compression != 0 && compression != 0xff)) {
    throw const FormatNotSupportedException('Unsupported Plucker Palm bitmap variant.');
  }
  if (16 + rowBytes * height > bitmap.length) {
    throw const InvalidBookException('Truncated Plucker Palm bitmap pixels.');
  }

  final raw = Uint8List(height * (width * channels + 1));
  final indexMask = (1 << depth) - 1;
  for (var y = 0; y < height; y++) {
    final row = y * (width * channels + 1);
    for (var x = 0; x < width; x++) {
      final bitOffset = x * depth;
      final source = bitmap[16 + y * rowBytes + bitOffset ~/ 8];
      final shift = 8 - depth - bitOffset % 8;
      final paletteIndex = (source >> shift) & indexMask;
      if (depth == 8) {
        final color = _palmSystemColor(paletteIndex);
        raw[row + 1 + x * 3] = color.$1;
        raw[row + 2 + x * 3] = color.$2;
        raw[row + 3 + x * 3] = color.$3;
      } else {
        raw[row + 1 + x] = 255 - paletteIndex * 255 ~/ indexMask;
      }
    }
  }
  final compressed = Uint8List.fromList(const ZLibEncoder().encode(raw));
  final output = BytesBuilder(copy: false)..add(<int>[137, 80, 78, 71, 13, 10, 26, 10]);
  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, depth == 8 ? 2 : 0);
  _writeChunk(output, 'IHDR', ihdr.buffer.asUint8List());
  _writeChunk(output, 'IDAT', compressed);
  _writeChunk(output, 'IEND', Uint8List(0));
  return output.takeBytes();
}

(int, int, int) _palmSystemColor(final int index) {
  const levels = <int>[255, 204, 153, 102, 51, 0];
  if (index < 216) {
    final band = index ~/ 108;
    final withinBand = index % 108;
    final red = levels[withinBand ~/ 18];
    final blue = levels[band * 3 + (withinBand % 18) ~/ 6];
    final green = levels[withinBand % 6];
    return (red, green, blue);
  }
  const extras = <(int, int, int)>[
    (17, 17, 17),
    (34, 34, 34),
    (68, 68, 68),
    (85, 85, 85),
    (119, 119, 119),
    (136, 136, 136),
    (170, 170, 170),
    (187, 187, 187),
    (221, 221, 221),
    (238, 238, 238),
    (192, 192, 192),
    (128, 128, 128),
    (128, 0, 0),
    (128, 0, 128),
    (0, 128, 0),
    (0, 128, 128),
  ];
  return index < 232 ? extras[index - 216] : (0, 0, 0);
}

void _writeChunk(final BytesBuilder output, final String type, final Uint8List data) {
  final header = ByteData(4)..setUint32(0, data.length);
  final name = type.codeUnits;
  var crc = 0xffffffff;
  for (final byte in <int>[...name, ...data]) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  final checksum = ByteData(4)..setUint32(0, (crc ^ 0xffffffff) & 0xffffffff);
  output
    ..add(header.buffer.asUint8List())
    ..add(name)
    ..add(data)
    ..add(checksum.buffer.asUint8List());
}
