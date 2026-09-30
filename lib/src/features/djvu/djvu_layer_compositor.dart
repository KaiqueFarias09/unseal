import 'dart:typed_data';

import '../../foundation/images/bmp_encoder.dart';
import 'djvu_decode_budget.dart';
import 'djvu_exception.dart';
import 'jb2_decoder.dart';

const _maxDjvuInfoDimension = 0xFFFF;

/// A decoded DjVu color layer in top-to-bottom, row-major RGB888 order.
///
/// The raster may be lower resolution than its page. The compositor accepts
/// only dimensions produced by a shared integer sub-sampling factor from 1 to
/// 12, as specified for BG44 and FG44 layers.
final class DjvuRgbRaster {
  /// Creates a view over an already-decoded RGB layer without copying it.
  const DjvuRgbRaster({required this.width, required this.height, required this.rgb});

  /// Raster width in pixels.
  final int width;

  /// Raster height in pixels.
  final int height;

  /// Interleaved red, green, and blue bytes, top row first.
  final Uint8List rgb;
}

/// Composes BG44 and optional FG44/Sjbz layers into a displayable 24-bit BMP.
///
/// Black mask pixels select [foreground]; white pixels select [background].
/// The foreground must always come with its mask; a mask without a foreground
/// is a valid page whose FGbz color layer is ignored, and its ink renders
/// black over the background. A page without mask or foreground is a photo
/// whose BG44 layer is expanded to the INFO dimensions. MRC color layers and
/// reduced photo layers are expanded with deterministic bilinear interpolation
/// on a grid spaced by their validated integer sub-sampling factor. Samples
/// outside the last grid point clamp to the layer edge.
///
/// [budget] reserves the output page before its BMP bytes are allocated.
Uint8List composeDjvuLayersBmp({
  required final DjvuRgbRaster background,
  final DjvuRgbRaster? foreground,
  final DjvuJb2Mask? mask,
  required final int pageWidth,
  required final int pageHeight,
  required final DjvuDecodeBudget budget,
}) {
  final pagePixels = _checkedPixelCount(pageWidth, pageHeight, 'page');
  final backgroundFactor = _validateRaster(background, pageWidth, pageHeight, 'background');

  if (foreground != null && mask == null) {
    throw const DjvuException('DjVu foreground color needs a selection mask.');
  }
  var foregroundFactor = 1;
  if (mask != null) {
    if (mask.width != pageWidth || mask.height != pageHeight || mask.pixels.length != pagePixels) {
      throw const DjvuException('DjVu selection mask dimensions do not match the INFO chunk.');
    }
    if (foreground != null) {
      foregroundFactor = _validateRaster(foreground, pageWidth, pageHeight, 'foreground');
    }
  }

  final rowStride = bmpRowStride(pageWidth);
  final pixelBytes = rowStride * pageHeight;
  final outputBytes = bmpHeaderBytes + pixelBytes;
  budget.reserve(pixels: pagePixels, rasterBytes: outputBytes);

  if (mask != null) {
    for (final pixel in mask.pixels) {
      if (pixel > 1) {
        throw const DjvuException(
          'DjVu selection mask contains a pixel outside the bilevel range.',
        );
      }
    }
  }

  final output = Uint8List(outputBytes);
  writeBmpHeader(output, pageWidth, pageHeight, pixelBytes);
  final backgroundSampler = _RasterSampler(background, backgroundFactor);
  final foregroundSampler = foreground == null
      ? null
      : _RasterSampler(foreground, foregroundFactor);
  final selection = mask?.pixels;
  final bottomUpBase = bmpHeaderBytes;

  for (var y = 0; y < pageHeight; y++) {
    final sourceRow = (pageHeight - 1 - y) * rowStride;
    for (var x = 0; x < pageWidth; x++) {
      final destinationPixel = y * pageWidth + x;
      final selectInk = selection != null && selection[destinationPixel] == 1;
      final byteOffset = bottomUpBase + sourceRow + x * 3;
      if (selectInk && foregroundSampler == null) {
        // The color layer is ignored: mask ink renders black.
        output[byteOffset] = 0;
        output[byteOffset + 1] = 0;
        output[byteOffset + 2] = 0;
        continue;
      }
      final source = selectInk ? foregroundSampler! : backgroundSampler;
      source.writeBgr(output, byteOffset, x, y);
    }
  }
  return output;
}

int _checkedPixelCount(final int width, final int height, final String label) {
  if (width < 1 || height < 1 || width > _maxDjvuInfoDimension || height > _maxDjvuInfoDimension) {
    throw DjvuException('Invalid DjVu $label dimensions.');
  }
  final pixels = width * height;
  if (pixels > djvuMaxDecodedPixelsPerBook) {
    throw const DjvuException('DjVu raster exceeds the cumulative decoded-pixel limit.');
  }
  return pixels;
}

int _validateRaster(
  final DjvuRgbRaster raster,
  final int pageWidth,
  final int pageHeight,
  final String label,
) {
  if (raster.width < 1 ||
      raster.height < 1 ||
      raster.width > pageWidth ||
      raster.height > pageHeight) {
    throw DjvuException('Invalid DjVu $label raster dimensions.');
  }

  final factor = _subsamplingFactor(pageWidth, pageHeight, raster.width, raster.height);
  if (factor == null) {
    throw DjvuException(
      'DjVu $label dimensions do not match an allowed 1-to-12 sub-sampling factor.',
    );
  }

  final expectedBytes = raster.width * raster.height * 3;
  if (raster.rgb.length != expectedBytes) {
    throw DjvuException('DjVu $label RGB byte length does not match its dimensions.');
  }
  return factor;
}

int? _subsamplingFactor(
  final int pageWidth,
  final int pageHeight,
  final int layerWidth,
  final int layerHeight,
) {
  for (var factor = 1; factor <= 12; factor++) {
    if ((pageWidth + factor - 1) ~/ factor == layerWidth &&
        (pageHeight + factor - 1) ~/ factor == layerHeight) {
      return factor;
    }
  }
  return null;
}

final class _RasterSampler {
  const _RasterSampler(this.raster, this.factor);

  final DjvuRgbRaster raster;
  final int factor;

  void writeBgr(final Uint8List output, final int outputOffset, final int x, final int y) {
    final left = x ~/ factor;
    final top = y ~/ factor;
    final right = left + 1 < raster.width ? left + 1 : left;
    final bottom = top + 1 < raster.height ? top + 1 : top;
    final xWeight = x % factor;
    final yWeight = y % factor;
    final inverseX = factor - xWeight;
    final inverseY = factor - yWeight;
    final divisor = factor * factor;
    final topLeftOffset = (top * raster.width + left) * 3;
    final topRightOffset = (top * raster.width + right) * 3;
    final bottomLeftOffset = (bottom * raster.width + left) * 3;
    final bottomRightOffset = (bottom * raster.width + right) * 3;
    final halfDivisor = divisor ~/ 2;
    final red =
        (raster.rgb[topLeftOffset] * inverseX * inverseY +
            raster.rgb[topRightOffset] * xWeight * inverseY +
            raster.rgb[bottomLeftOffset] * inverseX * yWeight +
            raster.rgb[bottomRightOffset] * xWeight * yWeight +
            halfDivisor) ~/
        divisor;
    final green =
        (raster.rgb[topLeftOffset + 1] * inverseX * inverseY +
            raster.rgb[topRightOffset + 1] * xWeight * inverseY +
            raster.rgb[bottomLeftOffset + 1] * inverseX * yWeight +
            raster.rgb[bottomRightOffset + 1] * xWeight * yWeight +
            halfDivisor) ~/
        divisor;
    final blue =
        (raster.rgb[topLeftOffset + 2] * inverseX * inverseY +
            raster.rgb[topRightOffset + 2] * xWeight * inverseY +
            raster.rgb[bottomLeftOffset + 2] * inverseX * yWeight +
            raster.rgb[bottomRightOffset + 2] * xWeight * yWeight +
            halfDivisor) ~/
        divisor;
    output[outputOffset] = blue;
    output[outputOffset + 1] = green;
    output[outputOffset + 2] = red;
  }
}
