import 'dart:typed_data';

/// Synthetic TIFF structures for parser boundary tests.
///
/// These builders exercise the container grammar (byte orders, BigTIFF,
/// hostile offsets and counts) with hand-built bytes; the codec parity
/// lives in the tracked real-world fixtures.
const _tiffTypes = <int, int>{1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 16: 8};

/// Builds a classic TIFF header + one IFD with [entries].
///
/// Values longer than four bytes are appended out-of-line after the
/// IFD; short values are stored inline.
Uint8List buildClassicTiff(
  final List<int> byteOrderMark, {
  required final Map<int, (int, int, Object)> entries,
  final int firstIfdOffset = 8,
  final List<int> extra = const <int>[],
}) {
  final tags = entries.keys.toList()..sort();
  final ifdSize = 2 + tags.length * 12 + 4;
  final extraStart = firstIfdOffset + ifdSize;
  final extraBytes = BytesBuilder(copy: false);
  final inlineExtra = <int, int>{};
  var cursor = extraStart;
  // Pre-layout out-of-line values.
  for (final tag in tags) {
    final (type, count, value) = entries[tag]!;
    final typeSize = _tiffTypes[type] ?? 1;
    if (typeSize * count > 4) {
      inlineExtra[tag] = cursor;
      cursor += typeSize * count;
    }
  }
  for (final byte in extra) {
    extraBytes.addByte(byte);
  }

  final total = cursor + extraBytes.length;
  final out = Uint8List(total);
  final view = ByteData.sublistView(out);
  out[0] = byteOrderMark[0];
  out[1] = byteOrderMark[1];
  view.setUint16(2, 42, _endianOf(byteOrderMark));
  view.setUint32(4, firstIfdOffset, _endianOf(byteOrderMark));

  final ifd = firstIfdOffset;
  view.setUint16(ifd, tags.length, _endianOf(byteOrderMark));
  var entry = ifd + 2;
  for (final tag in tags) {
    final (type, count, value) = entries[tag]!;
    final typeSize = _tiffTypes[type] ?? 1;
    view.setUint16(entry, tag, _endianOf(byteOrderMark));
    view.setUint16(entry + 2, type, _endianOf(byteOrderMark));
    view.setUint32(entry + 4, count, _endianOf(byteOrderMark));
    final byteLength = typeSize * count;
    if (byteLength > 4) {
      view.setUint32(entry + 8, inlineExtra[tag]!, _endianOf(byteOrderMark));
    } else if (value is int) {
      if (type == 3) {
        view.setUint16(entry + 8, value, _endianOf(byteOrderMark));
      } else {
        view.setUint32(entry + 8, value, _endianOf(byteOrderMark));
      }
    }
    entry += 12;
  }
  view.setUint32(entry, 0, _endianOf(byteOrderMark)); // next IFD

  // Write out-of-line values.
  for (final tag in tags) {
    final (type, count, value) = entries[tag]!;
    final typeSize = _tiffTypes[type] ?? 1;
    if (typeSize * count <= 4) continue;
    final at = inlineExtra[tag]!;
    if (value is List<int>) {
      for (var index = 0; index < count; index++) {
        if (type == 3) {
          view.setUint16(at + index * 2, value[index], _endianOf(byteOrderMark));
        } else {
          view.setUint32(at + index * 4, value[index], _endianOf(byteOrderMark));
        }
      }
    }
  }
  return out;
}

Endian _endianOf(final List<int> mark) => mark[0] == 0x49 ? Endian.little : Endian.big;

/// A minimal single-page gray 8-bit uncompressed image [width]×[height]
/// whose pixels ramp deterministically.
Uint8List buildGrayTiff({
  required final int width,
  required final int height,
  final List<int> mark = const <int>[0x49, 0x49],
  final int stripByteCountOverride = -1,
}) {
  final pixels = Uint8List(width * height);
  for (var index = 0; index < pixels.length; index++) {
    pixels[index] = index & 0xFF;
  }
  final stripOffset = 8 + 2 + 9 * 12 + 4;
  final out = Uint8List(stripOffset + pixels.length);
  out.setRange(stripOffset, stripOffset + pixels.length, pixels);
  final view = ByteData.sublistView(out);
  out[0] = mark[0];
  out[1] = mark[1];
  view.setUint16(2, 42, _endianOf(mark));
  view.setUint32(4, 8, _endianOf(mark));
  view.setUint16(8, 9, _endianOf(mark));
  var entry = 10;
  void tag(final int id, final int type, final int count, final int value) {
    view.setUint16(entry, id, _endianOf(mark));
    view.setUint16(entry + 2, type, _endianOf(mark));
    view.setUint32(entry + 4, count, _endianOf(mark));
    if (type == 3) {
      view.setUint16(entry + 8, value, _endianOf(mark));
    } else {
      view.setUint32(entry + 8, value, _endianOf(mark));
    }
    entry += 12;
  }

  tag(256, 4, 1, width); // ImageWidth
  tag(257, 4, 1, height); // ImageLength
  tag(258, 3, 1, 8); // BitsPerSample
  tag(259, 3, 1, 1); // Compression: none
  tag(262, 3, 1, 1); // Photometric: BlackIsZero
  tag(273, 4, 1, stripOffset); // StripOffsets
  tag(277, 3, 1, 1); // SamplesPerPixel
  tag(278, 4, 1, height); // RowsPerStrip
  tag(279, 4, 1, stripByteCountOverride < 0 ? pixels.length : stripByteCountOverride);
  view.setUint32(entry, 0, _endianOf(mark));
  return out;
}
