import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../foundation/exceptions/unseal_exception.dart';

/// Converts a bounded, uncompressed Palm monochrome bitmap to PNG.
///
/// The common version-0, one-bit Palm bitmap is enough for the PyPlucker
/// monochrome image path. Other bit depths and internal compression are kept
/// explicit so a reader never receives an apparently valid but blank image.
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
  if (width == 0 ||
      height == 0 ||
      width * height > 480000 ||
      rowBytes < (width + 7) ~/ 8 ||
      rowBytes * height > 60000) {
    throw const InvalidBookException('Invalid Plucker Palm bitmap dimensions.');
  }
  if (version != 0 || depth != 1 || flags != 0 || (compression != 0 && compression != 0xff)) {
    throw const FormatNotSupportedException('Unsupported Plucker Palm bitmap variant.');
  }
  if (16 + rowBytes * height > bitmap.length) {
    throw const InvalidBookException('Truncated Plucker Palm bitmap pixels.');
  }

  final raw = Uint8List(height * (width + 1));
  for (var y = 0; y < height; y++) {
    final row = y * (width + 1);
    for (var x = 0; x < width; x++) {
      final source = bitmap[16 + y * rowBytes + x ~/ 8];
      raw[row + 1 + x] = (source & (0x80 >> (x % 8))) == 0 ? 255 : 0;
    }
  }
  final compressed = Uint8List.fromList(const ZLibEncoder().encode(raw));
  final output = BytesBuilder(copy: false)..add(<int>[137, 80, 78, 71, 13, 10, 26, 10]);
  final ihdr = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 0);
  _writeChunk(output, 'IHDR', ihdr.buffer.asUint8List());
  _writeChunk(output, 'IDAT', compressed);
  _writeChunk(output, 'IEND', Uint8List(0));
  return output.takeBytes();
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
