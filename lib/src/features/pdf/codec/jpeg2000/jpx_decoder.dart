import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'jpx_codestream.dart';
import 'jpx_exception.dart';
import 'jpx_limits.dart';
import 'jpx_tile.dart';

const List<int> _pngSignature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// A fully decoded JPEG 2000 image: 8-bit unsigned planar samples in
/// one or three components, ready for PNG encoding or PDF placement.
final class JpxImage {
  /// Builds an image of [width] x [height] from planar [samples].
  const JpxImage({
    required this.width,
    required this.height,
    required this.samples,
    required this.isJp2,
  });

  /// Image width in samples.
  final int width;

  /// Image height in samples.
  final int height;

  /// One 8-bit plane per component: 1 = grayscale, 3 = RGB after any
  /// codestream MCT. JP2 sYCC is outside the supported subset.
  final List<Uint8List> samples;

  /// Whether the payload came from a JP2 wrapper.
  final bool isJp2;

  /// Component count, matching [samples] length.
  int get componentCount => samples.length;

  /// Encodes the image as an 8-bit grayscale (1 component) or truecolor
  /// (3 components) PNG with filter type 0 per scanline.
  Uint8List toPngBytes() {
    final bytesPerPixel = componentCount == 3 ? 3 : 1;
    final rawLength = checkedProduct(height, 1 + width * bytesPerPixel);
    if (rawLength > kJpxMaxPngBytes) {
      throw JpxException(kJpxBudgetMessage);
    }
    final raw = BytesBuilder(copy: false);
    final gray = samples[0];
    final green = componentCount == 3 ? samples[1] : gray;
    final blue = componentCount == 3 ? samples[2] : gray;
    for (var row = 0; row < height; row++) {
      raw.addByte(0);
      final base = row * width;
      for (var column = 0; column < width; column++) {
        final index = base + column;
        raw.addByte(gray[index]);
        if (bytesPerPixel == 3) {
          raw.addByte(green[index]);
          raw.addByte(blue[index]);
        }
      }
    }

    final ihdr = Uint8List(13);
    _writeUint32(ihdr, 0, width);
    _writeUint32(ihdr, 4, height);
    ihdr[8] = 8; // bit depth
    ihdr[9] = componentCount == 3 ? 2 : 0; // color type

    final out = BytesBuilder(copy: false);
    out.add(_pngSignature);
    out.add(_chunk('IHDR', ihdr));
    out.add(_chunk('IDAT', Uint8List.fromList(ZLibEncoder().encode(raw.toBytes()))));
    out.add(_chunk('IEND', Uint8List(0)));
    return out.toBytes();
  }
}

Uint8List _chunk(final String type, final Uint8List data) {
  final typeBytes = type.codeUnits;
  final out = BytesBuilder(copy: false);
  final header = Uint8List(8);
  _writeUint32(header, 0, data.length);
  header.setRange(4, 8, typeBytes);
  out.add(header);
  out.add(data);
  final trailer = Uint8List(4);
  _writeUint32(trailer, 0, _crc32(typeBytes, data));
  out.add(trailer);
  return out.toBytes();
}

void _writeUint32(final Uint8List target, final int offset, final int value) {
  target[offset] = (value >> 24) & 0xFF;
  target[offset + 1] = (value >> 16) & 0xFF;
  target[offset + 2] = (value >> 8) & 0xFF;
  target[offset + 3] = value & 0xFF;
}

List<int>? _crcTable;

int _crc32(final List<int> typeBytes, final Uint8List data) {
  _crcTable ??= List<int>.generate(256, (final n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c & 0xFFFFFFFF;
  });
  var crc = 0xFFFFFFFF;
  for (final byte in typeBytes) {
    crc = _crcTable![(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  for (final byte in data) {
    crc = _crcTable![(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Decodes a JPEG 2000 payload (bare J2K codestream or JP2 wrapper)
/// into a [JpxImage], enforcing the Part 1 subset and the codec
/// budgets before any large allocation.
JpxImage decodeJpxImage(final Uint8List bytes) {
  if (bytes.length > kJpxMaxInputBytes) {
    throw JpxException(kJpxBudgetMessage);
  }
  final payload = openJpxPayload(bytes);
  final info = parseCodestream(payload.codestream);
  final image = info.image;
  final componentCount = image.componentCount;
  if (componentCount != 1 && componentCount != 3) {
    throw JpxUnsupportedException(
      'JPEG 2000 images with $componentCount components (CMYK or exotic '
      'layouts) are not supported.',
    );
  }
  if (payload.isJp2 && payload.wrapperWidth != null) {
    if (payload.wrapperWidth != image.width ||
        payload.wrapperHeight != image.height ||
        payload.wrapperComponents != componentCount) {
      throw const JpxException('JP2 wrapper header disagrees with the codestream geometry.');
    }
  }
  if (payload.isJp2 && payload.enumcs != null) {
    final enumcs = payload.enumcs!;
    if (componentCount == 1 && enumcs != 17) {
      throw JpxUnsupportedException('JP2 colorspace $enumcs does not match a grayscale image.');
    }
    if (componentCount == 3 && enumcs != 16) {
      throw JpxUnsupportedException('JP2 colorspace $enumcs is outside the sRGB subset.');
    }
  }
  final rasterSamples = checkedProduct(image.width, image.height);
  if (rasterSamples > kJpxMaxRasterSamples) {
    throw JpxException(kJpxBudgetMessage);
  }
  final planes = List<Uint8List>.generate(componentCount, (final _) => Uint8List(rasterSamples));

  final tileTotal = image.tileCountX * image.tileCountY;
  for (var tileIndex = 0; tileIndex < tileTotal; tileIndex++) {
    final decoder = JpxTileDecoder(
      info: info,
      codestream: payload.codestream,
      tileIndex: tileIndex,
      imagePrecision: 8,
    );
    final tilePlanes = decoder.decode();
    final tilesX = image.tileCountX;
    final tileX0 = image.tileX0 + (tileIndex % tilesX) * image.tileWidth;
    final tileY0 = image.tileY0 + (tileIndex ~/ tilesX) * image.tileHeight;
    final tileX1 = (image.tileX0 + (tileIndex % tilesX + 1) * image.tileWidth).clamp(
      image.x0,
      image.width,
    );
    final tileY1 = (image.tileY0 + (tileIndex ~/ tilesX + 1) * image.tileHeight).clamp(
      image.y0,
      image.height,
    );
    final tileWidth = tileX1 - tileX0;
    for (var component = 0; component < componentCount; component++) {
      final plane = planes[component];
      final tile = tilePlanes[component];
      for (var row = tileY0; row < tileY1; row++) {
        final targetBase = row * image.width + tileX0 - image.x0;
        final sourceBase = (row - tileY0) * tileWidth;
        plane.setRange(targetBase, targetBase + tileWidth, tile, sourceBase);
      }
    }
  }

  return JpxImage(width: image.width, height: image.height, samples: planes, isJp2: payload.isJp2);
}
