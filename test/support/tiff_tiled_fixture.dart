import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Hand-built classic and BigTIFF documents for the tiled-page boundary
/// tests: any tag set, any byte order, several pages, and segment data
/// placed at known offsets so offsets and counts can be forged.
final class SyntheticTiffTag {
  /// Creates one IFD entry; [values] holds `count` integers (pairs for
  /// RATIONAL).
  const SyntheticTiffTag(this.tag, this.type, this.values);

  /// Convenience for a single SHORT.
  SyntheticTiffTag.short(this.tag, final int value) : type = 3, values = [value];

  /// Convenience for a single LONG.
  SyntheticTiffTag.long(this.tag, final int value) : type = 4, values = [value];

  /// The TIFF tag id.
  final int tag;

  /// The TIFF field type (1 BYTE, 2 ASCII, 3 SHORT, 4 LONG, 5 RATIONAL,
  /// 16 LONG8).
  final int type;

  /// The field values.
  final List<int> values;
}

const _typeSizes = <int, int>{1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 16: 8};

/// Serializes [pages] (one tag list per IFD, each built from the offset
/// where [data] will start) followed by [data].
///
/// The header, every IFD with its out-of-line values, and finally [data]
/// are laid out in that order, so a page's segment offsets can be
/// computed as `dataOffset + <position inside data>`.
Uint8List buildSyntheticTiff({
  required final List<List<SyntheticTiffTag>> Function(int dataOffset) pages,
  required final Uint8List data,
  final bool bigTiff = false,
  final Endian endian = Endian.little,
}) {
  final headerBytes = bigTiff ? 16 : 8;
  final countBytes = bigTiff ? 8 : 2;
  final entryBytes = bigTiff ? 20 : 12;
  final pointerBytes = bigTiff ? 8 : 4;
  final inlineBytes = bigTiff ? 8 : 4;

  int ifdBytes(final List<SyntheticTiffTag> tags) {
    var size = countBytes + tags.length * entryBytes + pointerBytes;
    for (final tag in tags) {
      final length = _typeSizes[tag.type]! * _count(tag);
      if (length > inlineBytes) size += length + (length & 1);
    }
    return size;
  }

  final draft = pages(0);
  var dataOffset = headerBytes;
  for (final tags in draft) {
    dataOffset += ifdBytes(tags);
  }
  final finalPages = pages(dataOffset);
  final output = Uint8List(dataOffset + data.length);
  final view = ByteData.sublistView(output);
  output[0] = endian == Endian.little ? 0x49 : 0x4D;
  output[1] = output[0];
  view.setUint16(2, bigTiff ? 43 : 42, endian);
  if (bigTiff) {
    view.setUint16(4, 8, endian);
    view.setUint16(6, 0, endian);
    _setOffset(view, 8, headerBytes, endian, bigTiff);
  } else {
    view.setUint32(4, headerBytes, endian);
  }

  var cursor = headerBytes;
  for (var pageIndex = 0; pageIndex < finalPages.length; pageIndex++) {
    final tags = [...finalPages[pageIndex]]..sort((final a, final b) => a.tag.compareTo(b.tag));
    final ifdStart = cursor;
    if (bigTiff) {
      _setOffset(view, ifdStart, tags.length, endian, true);
    } else {
      view.setUint16(ifdStart, tags.length, endian);
    }
    var entry = ifdStart + countBytes;
    var outOfLine = ifdStart + countBytes + tags.length * entryBytes + pointerBytes;
    for (final tag in tags) {
      final count = _count(tag);
      final length = _typeSizes[tag.type]! * count;
      view.setUint16(entry, tag.tag, endian);
      view.setUint16(entry + 2, tag.type, endian);
      if (bigTiff) {
        _setOffset(view, entry + 4, count, endian, true);
      } else {
        view.setUint32(entry + 4, count, endian);
      }
      final valueField = entry + 4 + (bigTiff ? 8 : 4);
      if (length <= inlineBytes) {
        _writeValues(view, valueField, tag, endian);
      } else {
        _setOffset(view, valueField, outOfLine, endian, bigTiff);
        _writeValues(view, outOfLine, tag, endian);
        outOfLine += length + (length & 1);
      }
      entry += entryBytes;
    }
    final next = pageIndex + 1 < finalPages.length ? outOfLine : 0;
    _setOffset(view, entry, next, endian, bigTiff);
    cursor = outOfLine;
  }
  output.setRange(dataOffset, dataOffset + data.length, data);
  return output;
}

int _count(final SyntheticTiffTag tag) =>
    tag.type == 5 ? tag.values.length ~/ 2 : tag.values.length;

void _setOffset(
  final ByteData view,
  final int at,
  final int value,
  final Endian endian,
  final bool bigTiff,
) {
  if (bigTiff) {
    final high = value >> 32;
    final low = value & 0xFFFFFFFF;
    view.setUint32(at + (endian == Endian.little ? 0 : 4), low, endian);
    view.setUint32(at + (endian == Endian.little ? 4 : 0), high, endian);
  } else {
    view.setUint32(at, value, endian);
  }
}

void _writeValues(
  final ByteData view,
  final int at,
  final SyntheticTiffTag tag,
  final Endian endian,
) {
  final size = _typeSizes[tag.type]!;
  for (var index = 0; index < tag.values.length; index++) {
    final value = tag.values[index];
    switch (tag.type) {
      case 1 || 2:
        view.setUint8(at + index, value);
      case 3:
        view.setUint16(at + index * 2, value, endian);
      case 4 || 5:
        view.setUint32(at + index * 4, value, endian);
      case 16:
        _setOffset(view, at + index * size, value, endian, true);
    }
  }
}

/// A deterministic gray-8 pattern: `(x * 7 + y * 13) & 0xFF`.
int grayPattern(final int x, final int y) => (x * 7 + y * 13) & 0xFF;

/// Packs the tile data of a tiled gray page: every tile at its full
/// footprint, edge tiles padded with zero, row-major tile order.
Uint8List tiledGrayData({
  required final int width,
  required final int height,
  required final int tileWidth,
  required final int tileLength,
  final int bits = 8,
  final int Function(int x, int y) sample = grayPattern,
}) {
  final across = (width + tileWidth - 1) ~/ tileWidth;
  final down = (height + tileLength - 1) ~/ tileLength;
  final tileRowBytes = (tileWidth * bits + 7) ~/ 8;
  final tileBytes = tileRowBytes * tileLength;
  final out = Uint8List(tileBytes * across * down);
  for (var tileRow = 0; tileRow < down; tileRow++) {
    for (var tileColumn = 0; tileColumn < across; tileColumn++) {
      final base = (tileRow * across + tileColumn) * tileBytes;
      for (var row = 0; row < tileLength; row++) {
        final y = tileRow * tileLength + row;
        for (var column = 0; column < tileWidth; column++) {
          final x = tileColumn * tileWidth + column;
          if (x >= width || y >= height) continue;
          final value = sample(x, y) & ((1 << bits) - 1);
          if (bits == 8) {
            out[base + row * tileRowBytes + column] = value;
          } else if (bits == 16) {
            out[base + row * tileRowBytes + column * 2] = value & 0xFF;
            out[base + row * tileRowBytes + column * 2 + 1] = value >> 8;
          } else {
            final bitOffset = column * bits;
            out[base + row * tileRowBytes + (bitOffset >> 3)] |=
                value << (8 - bits - (bitOffset & 7));
          }
        }
      }
    }
  }
  return out;
}

/// Builds one tiled gray page as a whole document, with every address
/// field open to forgery.
///
/// [tileOffsets]/[tileByteCounts] replace the computed arrays; [omit]
/// drops tags; [useStripTags] stores the tile addresses under
/// StripOffsets/StripByteCounts the way SGI files do; [extra] adds or
/// overrides tags; [compression] 8 (Deflate) compresses every tile with
/// zlib, anything else is written raw under the given id.
Uint8List buildTiledGrayTiff({
  required final int width,
  required final int height,
  required final int tileWidth,
  required final int tileLength,
  final int bits = 8,
  final int compression = 1,
  final bool bigTiff = false,
  final Endian endian = Endian.little,
  final bool useStripTags = false,
  final bool long8Addresses = false,
  final List<int>? tileOffsets,
  final List<int>? tileByteCounts,
  final Set<int> omit = const <int>{},
  final List<SyntheticTiffTag> extra = const <SyntheticTiffTag>[],
  final Uint8List? data,
  final int Function(int x, int y) sample = grayPattern,
}) {
  final across = (width + tileWidth - 1) ~/ tileWidth;
  final down = (height + tileLength - 1) ~/ tileLength;
  final tileRowBytes = (tileWidth * bits + 7) ~/ 8;
  final tileBytes = tileRowBytes * tileLength;
  final raw =
      data ??
      tiledGrayData(
        width: width,
        height: height,
        tileWidth: tileWidth,
        tileLength: tileLength,
        bits: bits,
        sample: sample,
      );
  final Uint8List payload;
  final List<int> computedOffsets = [];
  final List<int> computedCounts = [];
  if (compression == 8 && data == null) {
    final builder = BytesBuilder(copy: false);
    for (var tile = 0; tile < across * down; tile++) {
      final encoded = const ZLibEncoder().encodeBytes(
        Uint8List.sublistView(raw, tile * tileBytes, (tile + 1) * tileBytes),
      );
      computedOffsets.add(builder.length);
      computedCounts.add(encoded.length);
      builder.add(encoded);
    }
    payload = builder.toBytes();
  } else {
    payload = raw;
    final count = data == null ? across * down : 1;
    for (var tile = 0; tile < count; tile++) {
      computedOffsets.add(tile * tileBytes);
      computedCounts.add(data == null ? tileBytes : data.length);
    }
  }
  final addressType = long8Addresses ? 16 : 4;
  return buildSyntheticTiff(
    bigTiff: bigTiff,
    endian: endian,
    data: payload,
    pages: (final dataOffset) {
      final offsets = tileOffsets ?? [for (final offset in computedOffsets) dataOffset + offset];
      final counts = tileByteCounts ?? computedCounts;
      final tags = <int, SyntheticTiffTag>{
        256: SyntheticTiffTag.long(256, width),
        257: SyntheticTiffTag.long(257, height),
        258: SyntheticTiffTag.short(258, bits),
        259: SyntheticTiffTag.short(259, compression),
        262: SyntheticTiffTag.short(262, 1),
        277: SyntheticTiffTag.short(277, 1),
        322: SyntheticTiffTag.long(322, tileWidth),
        323: SyntheticTiffTag.long(323, tileLength),
        useStripTags ? 273 : 324: SyntheticTiffTag(useStripTags ? 273 : 324, addressType, offsets),
        useStripTags ? 279 : 325: SyntheticTiffTag(useStripTags ? 279 : 325, addressType, counts),
      };
      for (final tag in extra) {
        tags[tag.tag] = tag;
      }
      for (final tag in omit) {
        tags.remove(tag);
      }
      return [tags.values.toList()];
    },
  );
}

/// Builds a multi-page document whose pages are tiled gray images that
/// all point at the same Deflate-compressed zero tile, so the declared
/// decode work grows with the page count while the file stays small.
Uint8List buildSharedTileDocument({
  required final int pages,
  required final int width,
  required final int height,
  required final int tileWidth,
  required final int tileLength,
}) {
  final tileBytes = tileWidth * tileLength;
  final encoded = Uint8List.fromList(const ZLibEncoder().encodeBytes(Uint8List(tileBytes)));
  return buildSyntheticTiff(
    data: encoded,
    pages: (final dataOffset) => [
      for (var page = 0; page < pages; page++)
        [
          SyntheticTiffTag.long(256, width),
          SyntheticTiffTag.long(257, height),
          SyntheticTiffTag.short(258, 8),
          SyntheticTiffTag.short(259, 8),
          SyntheticTiffTag.short(262, 1),
          SyntheticTiffTag.short(277, 1),
          SyntheticTiffTag.long(322, tileWidth),
          SyntheticTiffTag.long(323, tileLength),
          SyntheticTiffTag.long(324, dataOffset),
          SyntheticTiffTag.long(325, encoded.length),
        ],
    ],
  );
}
