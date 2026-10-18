import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'jpx_codestream.dart';
import 'jpx_color.dart';
import 'jpx_exception.dart';
import 'jpx_limits.dart';
import 'jpx_tile.dart';

const List<int> _pngSignature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// How the output projection interprets the components
/// (doc/jpeg2000-precision.md, output contract rule 5).
enum JpxColorModel {
  /// One component.
  gray,

  /// Three components already in RGB (after any codestream MCT).
  rgb,

  /// Three components in sYCC, converted to RGB on output.
  sycc,
}

/// One decoded component on its own sample grid: the native-sample
/// contract of doc/jpeg2000-precision.md.
final class JpxComponentPlane {
  /// Wraps the plane geometry and samples.
  const JpxComponentPlane({
    required this.dx,
    required this.dy,
    required this.x0,
    required this.y0,
    required this.width,
    required this.height,
    required this.samples,
  });

  /// XRsiz: horizontal reference-grid step between samples.
  final int dx;

  /// YRsiz: vertical reference-grid step between samples.
  final int dy;

  /// First sample column, `ceil(XOsiz / dx)`.
  final int x0;

  /// First sample row, `ceil(YOsiz / dy)`.
  final int y0;

  /// Sample columns, `ceil(Xsiz / dx) - x0`.
  final int width;

  /// Sample rows, `ceil(Ysiz / dy) - y0`.
  final int height;

  /// Row-major samples: `Uint8List` up to 8 bits, `Uint16List` above,
  /// level-shifted and clipped to `[0, 2^precision - 1]`.
  final TypedDataList<int> samples;
}

/// A fully decoded JPEG 2000 image: native planes per component plus
/// the reference-grid projection the PDF adapter encodes.
final class JpxImage {
  /// Builds the image; [components] are in codestream order.
  JpxImage({
    required this.width,
    required this.height,
    required this.x0,
    required this.y0,
    required this.precision,
    required this.components,
    required this.colorModel,
    required this.isJp2,
    required this.enumcs,
  });

  /// Reference-grid width, `Xsiz - XOsiz`.
  final int width;

  /// Reference-grid height, `Ysiz - YOsiz`.
  final int height;

  /// Image origin on the reference grid (XOsiz).
  final int x0;

  /// Image origin on the reference grid (YOsiz).
  final int y0;

  /// Bits per sample shared by every component, 8 to 16.
  final int precision;

  /// Native planes, one per codestream component.
  final List<JpxComponentPlane> components;

  /// Colour interpretation of the output projection.
  final JpxColorModel colorModel;

  /// Whether the payload came from a JP2 wrapper.
  final bool isJp2;

  /// JP2 `colr` enumerated colourspace when present.
  final int? enumcs;

  List<TypedDataList<int>>? _output;

  /// Codestream component count.
  int get componentCount => components.length;

  /// Bytes one native or output sample occupies.
  int get bytesPerSample => precision <= 8 ? 1 : 2;

  /// Whether every component sits on the reference grid.
  bool get isFullResolution => components.every((final c) => c.dx == 1 && c.dy == 1);

  /// Planes the output projection produces: 1 for gray, 3 otherwise.
  int get outputComponentCount => colorModel == JpxColorModel.gray ? 1 : 3;

  /// Reference-grid planes ([width] x [height] each) following the
  /// output contract: native planes when every component is full
  /// resolution, nearest-neighbour upsampling for subsampled gray/RGB,
  /// the OpenJPEG sYCC conversion for sYCC. Budgeted before allocating
  /// and memoized.
  List<TypedDataList<int>> get outputPlanes => _output ??= _project();

  List<TypedDataList<int>> _project() {
    if (colorModel != JpxColorModel.sycc && isFullResolution) {
      return <TypedDataList<int>>[for (final component in components) component.samples];
    }
    final planeSamples = checkedProduct(width, height);
    if (checkedProduct(planeSamples, outputComponentCount) * bytesPerSample > kJpxMaxImageBytes) {
      throw JpxException(kJpxBudgetMessage);
    }
    if (colorModel == JpxColorModel.sycc) {
      final layout = JpxColor.chromaLayout(<(int, int)>[
        for (final component in components) (component.dx, component.dy),
      ]);
      return JpxColor.syccToRgb(
        layout: layout ?? 'unsupported',
        planes: <TypedDataList<int>>[for (final component in components) component.samples],
        width: width,
        height: height,
        chromaWidth: components[1].width,
        chromaHeight: components[1].height,
        precision: precision,
        x0: x0,
        y0: y0,
      );
    }
    return <TypedDataList<int>>[
      for (final component in components)
        if (component.dx == 1 && component.dy == 1)
          component.samples
        else
          JpxColor.upsample(
            source: component.samples,
            sourceWidth: component.width,
            sourceHeight: component.height,
            dx: component.dx,
            dy: component.dy,
            xoff: component.dx * component.x0 - x0,
            yoff: component.dy * component.y0 - y0,
            width: width,
            height: height,
          ),
    ];
  }

  /// Encodes the output projection as a PNG: 8-bit grayscale or
  /// truecolor for 8-bit images (byte-identical to the previous
  /// subset), 16-bit otherwise with samples scaled by bit replication
  /// and an `sBIT` chunk declaring the native precision when it is below
  /// 16. Filter type 0 on every scanline.
  Uint8List toPngBytes() {
    final planes = outputPlanes;
    final channels = planes.length;
    final bytesPerPixel = channels * bytesPerSample;
    final rawLength = checkedProduct(height, 1 + checkedProduct(width, bytesPerPixel));
    if (rawLength > kJpxMaxPngBytes || rawLength > kJpxMaxImageBytes) {
      throw JpxException(kJpxBudgetMessage);
    }
    final raw = Uint8List(rawLength);
    var cursor = 0;
    if (bytesPerSample == 1) {
      for (var row = 0; row < height; row++) {
        raw[cursor++] = 0;
        final base = row * width;
        for (var column = 0; column < width; column++) {
          for (var channel = 0; channel < channels; channel++) {
            raw[cursor++] = planes[channel][base + column];
          }
        }
      }
    } else {
      final shift = 16 - precision;
      final replicate = precision - shift;
      for (var row = 0; row < height; row++) {
        raw[cursor++] = 0;
        final base = row * width;
        for (var column = 0; column < width; column++) {
          for (var channel = 0; channel < channels; channel++) {
            final native = planes[channel][base + column];
            final scaled = shift == 0 ? native : (native << shift) | (native >> replicate);
            raw[cursor++] = scaled >> 8;
            raw[cursor++] = scaled & 0xFF;
          }
        }
      }
    }

    final ihdr = Uint8List(13);
    _writeUint32(ihdr, 0, width);
    _writeUint32(ihdr, 4, height);
    ihdr[8] = bytesPerSample == 1 ? 8 : 16;
    ihdr[9] = channels == 3 ? 2 : 0;

    final out = BytesBuilder(copy: false);
    out.add(_pngSignature);
    out.add(_chunk('IHDR', ihdr));
    if (bytesPerSample == 2 && precision < 16) {
      out.add(_chunk('sBIT', Uint8List.fromList(List<int>.filled(channels, precision))));
    }
    out.add(_chunk('IDAT', Uint8List.fromList(ZLibEncoder().encode(raw))));
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
    if (payload.wrapperWidth != image.gridWidth ||
        payload.wrapperHeight != image.gridHeight ||
        payload.wrapperComponents != componentCount) {
      throw const JpxException('JP2 wrapper header disagrees with the codestream geometry.');
    }
  }
  final colorModel = _resolveColorModel(image, payload.isJp2 ? payload.enumcs : null);

  var nativeBytes = 0;
  for (var component = 0; component < componentCount; component++) {
    final samples = checkedProduct(
      image.componentWidth(component),
      image.componentHeight(component),
    );
    if (samples > kJpxMaxRasterSamples) {
      throw JpxException(kJpxBudgetMessage);
    }
    nativeBytes += samples * (image.precision <= 8 ? 1 : 2);
    if (nativeBytes > kJpxMaxImageBytes) {
      throw JpxException(kJpxBudgetMessage);
    }
  }
  final planes = <JpxComponentPlane>[
    for (var component = 0; component < componentCount; component++)
      JpxComponentPlane(
        dx: image.components[component].dx,
        dy: image.components[component].dy,
        x0: image.componentX0(component),
        y0: image.componentY0(component),
        width: image.componentWidth(component),
        height: image.componentHeight(component),
        samples: image.precision <= 8
            ? Uint8List(image.componentWidth(component) * image.componentHeight(component))
            : Uint16List(image.componentWidth(component) * image.componentHeight(component)),
      ),
  ];

  final tileTotal = image.tileCountX * image.tileCountY;
  for (var tileIndex = 0; tileIndex < tileTotal; tileIndex++) {
    final decoded = JpxTileDecoder(
      info: info,
      codestream: payload.codestream,
      tileIndex: tileIndex,
    ).decode();
    for (var component = 0; component < componentCount; component++) {
      final tile = decoded[component];
      if (tile.width <= 0 || tile.height <= 0) {
        continue;
      }
      final plane = planes[component];
      final source = tile.samples;
      for (var row = tile.y0; row < tile.y1; row++) {
        final targetBase = (row - plane.y0) * plane.width + (tile.x0 - plane.x0);
        final sourceBase = (row - tile.y0) * tile.width;
        plane.samples.setRange(targetBase, targetBase + tile.width, source, sourceBase);
      }
    }
  }

  return JpxImage(
    width: image.gridWidth,
    height: image.gridHeight,
    x0: image.x0,
    y0: image.y0,
    precision: image.precision,
    components: planes,
    colorModel: colorModel,
    isJp2: payload.isJp2,
    enumcs: payload.isJp2 ? payload.enumcs : null,
  );
}

/// Output contract rule 5: `colr` 17 is grayscale, 18 is sYCC (with a
/// supported chroma layout), 16 is sRGB; a three-component image with
/// the 4:2:2 or 4:2:0 layout is sYCC whatever the wrapper says, as
/// `opj_decompress` decides.
JpxColorModel _resolveColorModel(final JpxImageInfo image, final int? enumcs) {
  if (image.componentCount == 1) {
    if (enumcs != null && enumcs != 17) {
      throw JpxUnsupportedException('JP2 colorspace $enumcs does not match a grayscale image.');
    }
    return JpxColorModel.gray;
  }
  final layout = JpxColor.chromaLayout(<(int, int)>[
    for (final component in image.components) (component.dx, component.dy),
  ]);
  if (enumcs == 18) {
    if (layout == null) {
      throw const JpxUnsupportedException(
        'JP2 sYCC with a chroma layout other than 4:4:4, 4:2:2 or 4:2:0 is not supported.',
      );
    }
    return JpxColorModel.sycc;
  }
  if (enumcs == 17) {
    throw const JpxUnsupportedException(
      'JP2 colorspace 17 (greyscale) does not match a three-component image.',
    );
  }
  if (enumcs != null && enumcs != 16) {
    throw JpxUnsupportedException('JP2 colorspace $enumcs is outside the sRGB/sYCC subset.');
  }
  if (layout == '422' || layout == '420') {
    return JpxColorModel.sycc;
  }
  return JpxColorModel.rgb;
}
