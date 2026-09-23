import 'dart:typed_data';

import 'djvu_exception.dart';

/// Maximum padded samples reconstructed for one IW44 component plane.
///
/// The limit bounds both the working copy (32 MiB) and the returned byte
/// plane (at most 16 MiB). The caller must reserve its document-wide raster
/// budget before calling this function.
const djvuMaxIw44PlaneSamples = 16 * 1000 * 1000;

/// Reconstructs one DjVu IW44 component plane from its scattered coefficients.
///
/// [coefficients] is a row-major, signed-Q6 plane padded to a multiple of 32
/// in each dimension. Its first row is the bottom row, as required by the
/// DjVu block order. The returned byte plane covers only [width] × [height],
/// is top-down, and maps normalized signed samples `[-128, 127]` to bytes
/// `[0, 255]` with an offset of 128.
///
/// The inverse DDL(4,4) lifting steps follow the public DjVu v3 specification
/// and are cross-checked against the independently written MIT-licensed
/// `djvu-rs` decoder. This Dart implementation is written independently.
///
/// Throws [DjvuException] for invalid dimensions, an inconsistent padded
/// input plane, or a plane exceeding [djvuMaxIw44PlaneSamples].
Uint8List reconstructDjvuIw44Plane(
  final Int16List coefficients, {
  required final int width,
  required final int height,
}) {
  if (width <= 0 || height <= 0) {
    throw const DjvuException('Invalid DjVu IW44 plane dimensions.');
  }

  if (width > djvuMaxIw44PlaneSamples || height > djvuMaxIw44PlaneSamples) {
    throw const DjvuException('DjVu IW44 plane exceeds the 16-megasample limit.');
  }

  final paddedWidth = ((width + 31) ~/ 32) * 32;
  final paddedHeight = ((height + 31) ~/ 32) * 32;
  final paddedSamples = paddedWidth * paddedHeight;
  if (paddedSamples > djvuMaxIw44PlaneSamples) {
    throw const DjvuException('DjVu IW44 padded plane exceeds the 16-megasample limit.');
  }
  if (coefficients.length != paddedSamples) {
    throw const DjvuException('DjVu IW44 coefficient plane has an invalid padded length.');
  }

  // Keep the caller's scattered coefficients intact while the lifting steps
  // overwrite the working plane at each resolution.
  final reconstructed = Int16List.fromList(coefficients);
  for (var scale = 16; scale >= 1; scale >>= 1) {
    final scaleShift = _scaleShift(scale);
    final verticalSamples = ((height - 1) >> scaleShift) + 1;
    final horizontalSamples = ((width - 1) >> scaleShift) + 1;

    // Column pass, visiting only the positions active at this scale.
    final verticalStep = scale * paddedWidth;
    for (var column = 0; column < width; column += scale) {
      _inverseLine(reconstructed, start: column, step: verticalStep, count: verticalSamples);
    }

    // Row pass over the same scale's active rows.
    for (var row = 0; row < height; row += scale) {
      _inverseLine(reconstructed, start: row * paddedWidth, step: scale, count: horizontalSamples);
    }
  }

  final output = Uint8List(width * height);
  for (var outputRow = 0; outputRow < height; outputRow++) {
    final inputRow = height - outputRow - 1;
    final inputOffset = inputRow * paddedWidth;
    final outputOffset = outputRow * width;
    for (var column = 0; column < width; column++) {
      final q6 = reconstructed[inputOffset + column];
      final signedSample = ((q6 + 32) >> 6).clamp(-128, 127);
      output[outputOffset + column] = signedSample + 128;
    }
  }
  return output;
}

int _scaleShift(final int scale) => switch (scale) {
  16 => 4,
  8 => 3,
  4 => 2,
  2 => 1,
  1 => 0,
  _ => throw const DjvuException('Invalid DjVu IW44 transform scale.'),
};

/// Applies one inverse DDL(4,4) pass over a strided line.
void _inverseLine(
  final Int16List data, {
  required final int start,
  required final int step,
  required final int count,
}) {
  final last = count - 1;

  // Undo the even-sample lifting step. Odd neighbors are unchanged throughout
  // this loop, so each update can read the source plane directly.
  for (var index = 0; index <= last; index += 2) {
    final before1 = index >= 1 ? data[start + (index - 1) * step] : 0;
    final after1 = index + 1 <= last ? data[start + (index + 1) * step] : 0;
    final before3 = index >= 3 ? data[start + (index - 3) * step] : 0;
    final after3 = index + 3 <= last ? data[start + (index + 3) * step] : 0;
    final neighbor1 = before1 + after1;
    final neighbor3 = before3 + after3;
    final delta = ((9 * neighbor1 - neighbor3 + 16) >> 5);
    final offset = start + index * step;
    data[offset] = _wrapInt16(data[offset] - delta);
  }

  // Restore odd samples by interpolation between the now-updated evens.
  for (var index = 1; index <= last; index += 2) {
    final offset = start + index * step;
    final current = data[offset];
    if (index == last) {
      final previous = data[start + (index - 1) * step];
      data[offset] = _wrapInt16(current + previous);
      continue;
    }

    final before1 = data[start + (index - 1) * step];
    final after1 = data[start + (index + 1) * step];
    if (index == 1 || index + 3 > last) {
      data[offset] = _wrapInt16(current + ((before1 + after1 + 1) >> 1));
      continue;
    }

    final before3 = data[start + (index - 3) * step];
    final after3 = data[start + (index + 3) * step];
    final neighbor1 = before1 + after1;
    final neighbor3 = before3 + after3;
    final delta = ((9 * neighbor1 - neighbor3 + 8) >> 4);
    data[offset] = _wrapInt16(current + delta);
  }
}

int _wrapInt16(final int value) {
  final lowWord = value & 0xffff;
  return lowWord >= 0x8000 ? lowWord - 0x10000 : lowWord;
}
