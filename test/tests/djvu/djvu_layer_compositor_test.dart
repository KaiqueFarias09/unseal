import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/djvu/djvu_decode_budget.dart';
import 'package:unseal/src/features/djvu/djvu_exception.dart';
import 'package:unseal/src/features/djvu/djvu_layer_compositor.dart';
import 'package:unseal/src/features/djvu/jb2_decoder.dart';

void main() {
  test('selects foreground for black mask pixels and writes a bottom-up BMP', () {
    final image = composeDjvuLayersBmp(
      background: _raster(2, 2, <int>[
        255, 0, 0, 0, 255, 0, // top row: red, green
        0, 0, 255, 255, 255, 255, // bottom row: blue, white
      ]),
      foreground: _raster(2, 2, <int>[
        255, 255, 0, 0, 255, 255, // top row: yellow, cyan
        255, 0, 255, 0, 0, 0, // bottom row: magenta, black
      ]),
      mask: _mask(2, 2, <int>[0, 1, 1, 0]),
      pageWidth: 2,
      pageHeight: 2,
      budget: DjvuDecodeBudget(),
    );

    final header = ByteData.sublistView(image);
    expect(image.take(2), <int>[0x42, 0x4D]);
    expect(header.getUint32(2, Endian.little), image.length);
    expect(header.getUint32(10, Endian.little), 54);
    expect(header.getUint32(14, Endian.little), 40);
    expect(header.getInt32(18, Endian.little), 2);
    expect(header.getInt32(22, Endian.little), 2);
    expect(header.getUint16(26, Endian.little), 1);
    expect(header.getUint16(28, Endian.little), 24);
    expect(_bmpPixel(image, 2, 2, 0, 0), <int>[255, 0, 0]);
    expect(_bmpPixel(image, 2, 2, 1, 0), <int>[0, 255, 255]);
    expect(_bmpPixel(image, 2, 2, 0, 1), <int>[255, 0, 255]);
    expect(_bmpPixel(image, 2, 2, 1, 1), <int>[255, 255, 255]);
  });

  test('bilinearly expands an allowed three-times sub-sampled layer', () {
    final image = composeDjvuLayersBmp(
      background: _raster(2, 1, <int>[0, 0, 0, 255, 0, 0]),
      foreground: _raster(2, 1, List<int>.filled(2 * 3, 255)),
      mask: _mask(6, 1, List<int>.filled(6, 0)),
      pageWidth: 6,
      pageHeight: 1,
      budget: DjvuDecodeBudget(),
    );

    expect(_bmpPixel(image, 6, 1, 0, 0), <int>[0, 0, 0]);
    expect(_bmpPixel(image, 6, 1, 1, 0), <int>[85, 0, 0]);
    expect(_bmpPixel(image, 6, 1, 2, 0), <int>[170, 0, 0]);
    expect(_bmpPixel(image, 6, 1, 3, 0), <int>[255, 0, 0]);
    expect(_bmpPixel(image, 6, 1, 5, 0), <int>[255, 0, 0]);
  });

  test('accepts the specification maximum twelve-times sub-sampling factor', () {
    final image = composeDjvuLayersBmp(
      background: _raster(2, 2, <int>[0, 0, 0, 255, 0, 0, 0, 255, 0, 255, 255, 255]),
      foreground: _raster(2, 2, List<int>.filled(2 * 2 * 3, 255)),
      mask: _mask(24, 24, List<int>.filled(24 * 24, 0)),
      pageWidth: 24,
      pageHeight: 24,
      budget: DjvuDecodeBudget(),
    );

    expect(_bmpPixel(image, 24, 24, 12, 12), <int>[255, 255, 255]);
  });

  test('bilinear sampling blends both axes and clamps the partial edge cell', () {
    final image = composeDjvuLayersBmp(
      background: _raster(2, 2, <int>[0, 0, 0, 255, 0, 0, 0, 255, 0, 255, 255, 255]),
      foreground: _raster(2, 2, List<int>.filled(2 * 2 * 3, 255)),
      mask: _mask(6, 6, List<int>.filled(6 * 6, 0)),
      pageWidth: 6,
      pageHeight: 6,
      budget: DjvuDecodeBudget(),
    );

    expect(_bmpPixel(image, 6, 6, 1, 1), <int>[85, 85, 28]);
    expect(_bmpPixel(image, 6, 6, 5, 5), <int>[255, 255, 255]);
  });

  test('accepts a full-resolution BG44-only photo page', () {
    final image = composeDjvuLayersBmp(
      background: _raster(1, 1, <int>[12, 34, 56]),
      pageWidth: 1,
      pageHeight: 1,
      budget: DjvuDecodeBudget(),
    );

    expect(_bmpPixel(image, 1, 1, 0, 0), <int>[12, 34, 56]);
  });

  test('rejects a foreground without its selection mask', () {
    expect(
      () => composeDjvuLayersBmp(
        background: _raster(1, 1, <int>[0, 0, 0]),
        foreground: _raster(1, 1, <int>[255, 255, 255]),
        pageWidth: 1,
        pageHeight: 1,
        budget: DjvuDecodeBudget(),
      ),
      throwsA(isA<DjvuException>()),
    );
  });

  test('renders a mask without a foreground as black ink over the background', () {
    // An FGbz page whose color layer is ignored keeps its mask: ink pixels
    // render black over the expanded background instead of pairing with a
    // foreground layer.
    final image = composeDjvuLayersBmp(
      background: _raster(1, 1, <int>[200, 210, 220]),
      mask: _mask(1, 1, <int>[1]),
      pageWidth: 1,
      pageHeight: 1,
      budget: DjvuDecodeBudget(),
    );
    expect(_bmpPixel(image, 1, 1, 0, 0), <int>[0, 0, 0]);
    final background = composeDjvuLayersBmp(
      background: _raster(1, 1, <int>[200, 210, 220]),
      mask: _mask(1, 1, <int>[0]),
      pageWidth: 1,
      pageHeight: 1,
      budget: DjvuDecodeBudget(),
    );
    expect(_bmpPixel(background, 1, 1, 0, 0), <int>[200, 210, 220]);
  });

  test('rejects dimensions that cannot share a permitted sub-sampling factor', () {
    expect(
      () => composeDjvuLayersBmp(
        background: _raster(3, 2, List<int>.filled(3 * 2 * 3, 0)),
        pageWidth: 5,
        pageHeight: 5,
        budget: DjvuDecodeBudget(),
      ),
      throwsA(isA<DjvuException>()),
    );
    expect(
      () => composeDjvuLayersBmp(
        background: _raster(1, 1, <int>[0, 0, 0]),
        foreground: _raster(1, 1, <int>[1, 1, 1]),
        mask: _mask(13, 13, List<int>.filled(13 * 13, 0)),
        pageWidth: 13,
        pageHeight: 13,
        budget: DjvuDecodeBudget(),
      ),
      throwsA(isA<DjvuException>()),
    );
    expect(
      () => composeDjvuLayersBmp(
        background: _raster(3, 2, List<int>.filled(3 * 2 * 3, 0)),
        foreground: _raster(3, 3, List<int>.filled(3 * 3 * 3, 0)),
        mask: _mask(5, 5, List<int>.filled(5 * 5, 0)),
        pageWidth: 5,
        pageHeight: 5,
        budget: DjvuDecodeBudget(),
      ),
      throwsA(isA<DjvuException>()),
    );
  });

  test('rejects inconsistent layer buffers, masks, and page dimensions', () {
    expect(
      () => composeDjvuLayersBmp(
        background: DjvuRgbRaster(width: 1, height: 1, rgb: Uint8List(2)),
        pageWidth: 1,
        pageHeight: 1,
        budget: DjvuDecodeBudget(),
      ),
      throwsA(isA<DjvuException>()),
    );
    expect(
      () => composeDjvuLayersBmp(
        background: _raster(1, 1, <int>[0, 0, 0]),
        foreground: _raster(1, 1, <int>[1, 1, 1]),
        mask: _mask(1, 1, <int>[2]),
        pageWidth: 1,
        pageHeight: 1,
        budget: DjvuDecodeBudget(),
      ),
      throwsA(isA<DjvuException>()),
    );
    expect(
      () => composeDjvuLayersBmp(
        background: _raster(1, 1, <int>[0, 0, 0]),
        foreground: _raster(1, 1, <int>[1, 1, 1]),
        mask: _mask(1, 1, <int>[0]),
        pageWidth: 2,
        pageHeight: 1,
        budget: DjvuDecodeBudget(),
      ),
      throwsA(isA<DjvuException>()),
    );
  });

  test('checks cumulative output budget before allocating a BMP page', () {
    final budget = DjvuDecodeBudget()
      ..reserve(pixels: 0, rasterBytes: djvuMaxDecodedRasterBytesPerBook - 61);

    expect(
      () => composeDjvuLayersBmp(
        background: _raster(2, 1, List<int>.filled(2 * 3, 0)),
        pageWidth: 2,
        pageHeight: 1,
        budget: budget,
      ),
      throwsA(isA<DjvuException>()),
    );
  });

  test('rejects a page above the cumulative pixel limit before inspecting layers', () {
    expect(
      () => composeDjvuLayersBmp(
        background: _raster(1, 1, <int>[0, 0, 0]),
        pageWidth: 20000,
        pageHeight: 14000,
        budget: DjvuDecodeBudget(),
      ),
      throwsA(isA<DjvuException>()),
    );
  });
}

DjvuRgbRaster _raster(final int width, final int height, final List<int> rgb) =>
    DjvuRgbRaster(width: width, height: height, rgb: Uint8List.fromList(rgb));

DjvuJb2Mask _mask(final int width, final int height, final List<int> pixels) =>
    DjvuJb2Mask(width: width, height: height, pixels: Uint8List.fromList(pixels));

List<int> _bmpPixel(
  final Uint8List bmp,
  final int width,
  final int height,
  final int x,
  final int y,
) {
  final rowStride = ((width * 3 + 3) ~/ 4) * 4;
  final offset = 54 + (height - 1 - y) * rowStride + x * 3;
  return <int>[bmp[offset + 2], bmp[offset + 1], bmp[offset]];
}
