import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Result of decoding a MOBI `FONT` record.
class DecodedFont {
  /// Creates a [DecodedFont].
  const DecodedFont({required this.data, required this.extension});

  /// The decoded font bytes (raw record when decoding failed).
  final Uint8List data;

  /// The font extension: `ttf`, `otf` or `dat`.
  final String extension;
}

/// Decodes a MOBI `FONT` record.
///
/// Layout: `'FONT'` magic, then five u32 fields — uncompressed size,
/// flags (bit 0: zlib compressed, bit 1: XOR obfuscated), data start
/// offset, xor key length and xor key offset. The first ~1040 bytes
/// of the payload are XORed with the repeating key when obfuscated.
DecodedFont decodeFontRecord(final Uint8List data) {
  if (data.length < 24 ||
      data[0] != 0x46 ||
      data[1] != 0x4F ||
      data[2] != 0x4E ||
      data[3] != 0x54) {
    return DecodedFont(data: data, extension: 'dat');
  }
  final view = ByteData.sublistView(data);
  final usize = view.getUint32(4);
  final flags = view.getUint32(8);
  final dstart = view.getUint32(12);
  final xorLen = view.getUint32(16);
  final xorStart = view.getUint32(20);

  if (dstart >= data.length) return DecodedFont(data: data, extension: 'dat');

  var fontData = Uint8List.sublistView(data, dstart);

  if ((flags & 0x2) != 0 && xorLen > 0 && xorStart + xorLen <= data.length) {
    final key = Uint8List.sublistView(data, xorStart, xorStart + xorLen);
    final buffer = Uint8List.fromList(fontData);
    const extent = 1040;
    final limit = buffer.length < extent ? buffer.length : extent;
    for (var i = 0; i < limit; i++) {
      buffer[i] ^= key[i % xorLen];
    }
    fontData = buffer;
  }

  if ((flags & 0x1) != 0) {
    try {
      fontData = const ZLibDecoder().decodeBytes(fontData) as Uint8List;
    } on Object {
      return DecodedFont(data: data, extension: 'dat');
    }
    if (fontData.length != usize) return DecodedFont(data: data, extension: 'dat');
  }

  final signature = fontData.length >= 4 ? fontData.sublist(0, 4) : fontData;
  String extension;
  if (_equals(signature, const [0x00, 0x01, 0x00, 0x00]) ||
      _equalsAscii(signature, 'true') ||
      _equalsAscii(signature, 'ttcf')) {
    extension = 'ttf';
  } else if (_equalsAscii(signature, 'OTTO')) {
    extension = 'otf';
  } else {
    extension = 'dat';
  }

  return DecodedFont(data: fontData, extension: extension);
}

bool _equals(final Uint8List bytes, final List<int> magic) {
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }

  return true;
}

bool _equalsAscii(final Uint8List bytes, final String magic) {
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic.codeUnitAt(i)) return false;
  }

  return true;
}
