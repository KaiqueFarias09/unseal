import 'dart:typed_data';

import 'djvu_decode_budget.dart';
import 'djvu_exception.dart';
import 'iw44_inverse_wavelet.dart';
import 'zp_decoder.dart';

const _maxIw44Chunks = 256;
const _maxIw44Slices = 1024;
const _maxIw44ChunkBytes = 32 * 1024 * 1024;
const _maxIw44CoefficientWork = 256 * 1000 * 1000;

const _bandBuckets = <(int, int)>[
  (0, 0),
  (1, 1),
  (2, 2),
  (3, 3),
  (4, 7),
  (8, 11),
  (12, 15),
  (16, 31),
  (32, 47),
  (48, 63),
];

const _quantLowInitial = <int>[
  0x004000,
  0x008000,
  0x008000,
  0x010000,
  0x010000,
  0x010000,
  0x010000,
  0x010000,
  0x010000,
  0x010000,
  0x010000,
  0x010000,
  0x020000,
  0x020000,
  0x020000,
  0x020000,
];

const _quantHighInitial = <int>[
  0,
  0x020000,
  0x020000,
  0x040000,
  0x040000,
  0x040000,
  0x080000,
  0x040000,
  0x040000,
  0x080000,
];

const _zero = 1;
const _active = 2;
const _new = 4;
const _potential = 8;
const _maxDimension = 0xFFFF;

/// A fully decoded IW44 layer in top-to-bottom RGB888 order.
final class DjvuIw44Raster {
  /// Creates an RGB view over a decoded IW44 layer.
  const DjvuIw44Raster({required this.width, required this.height, required this.rgb});

  /// Layer width in pixels.
  final int width;

  /// Layer height in pixels.
  final int height;

  /// Interleaved RGB bytes, top row first.
  final Uint8List rgb;
}

/// Decodes the ordered BG44 or FG44 chunks that form one IW44 layer.
///
/// The decoder supports the DjVu IW44 v1 format through minor version 2,
/// including progressive chunks and chroma delay. Coefficients, the inverse
/// transform working plane, and the returned RGB raster are reserved against
/// the document budget before allocation.
DjvuIw44Raster decodeDjvuIw44(
  final List<Uint8List> chunks, {
  required final int pageWidth,
  required final int pageHeight,
  required final DjvuDecodeBudget budget,
}) {
  if (chunks.isEmpty || chunks.length > _maxIw44Chunks) {
    throw const DjvuException('DjVu IW44 layer has no chunks or exceeds the 256-chunk limit.');
  }
  final header = _preflightChunks(chunks);
  _validateLayerDimensions(header.width, header.height, pageWidth, pageHeight);

  final width = header.width;
  final height = header.height;
  final color = header.color;
  final componentCount = color ? 3 : 1;
  final layerPixels = width * height;
  final blockColumns = (width + 31) ~/ 32;
  final blockRows = (height + 31) ~/ 32;
  final paddedWidth = blockColumns * 32;
  final paddedHeight = blockRows * 32;
  final paddedPixels = paddedWidth * paddedHeight;
  if (paddedPixels > djvuMaxIw44PlaneSamples) {
    throw const DjvuException('DjVu IW44 padded plane exceeds the 16-megasample limit.');
  }
  final paddedCoefficientBytes = paddedPixels * 2 * componentCount;
  final sampleBytes = layerPixels * componentCount;
  final rgbBytes = layerPixels * 3;
  // Reconstruction temporarily holds all coefficient planes, a copied int16
  // plane, and one byte output plane. Final conversion holds all byte planes
  // plus the RGB raster. Reserve the larger peak before allocating any plane.
  final reconstructionScratchBytes = (paddedWidth + paddedHeight) * 16;
  final workingBytes =
      _max(paddedCoefficientBytes + 2 * paddedPixels + layerPixels, sampleBytes + rgbBytes) +
      reconstructionScratchBytes;
  var coefficientWork = 0;
  final blockCount = blockColumns * blockRows;
  for (final sliceCount in header.sliceCounts) {
    coefficientWork += blockCount * sliceCount * componentCount * 256;
    if (coefficientWork > _maxIw44CoefficientWork) {
      throw const DjvuException('DjVu IW44 layer exceeds its coefficient-work limit.');
    }
  }
  budget.reserve(pixels: layerPixels * componentCount, rasterBytes: workingBytes);

  final y = _Iw44Plane(width, height);
  final cb = color ? _Iw44Plane(width, height) : null;
  final cr = color ? _Iw44Plane(width, height) : null;

  var chromaDelay = header.chromaDelay;
  for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
    final chunk = chunks[chunkIndex];
    final slices = header.sliceCounts[chunkIndex];
    if (slices == 0) continue;
    final payloadOffset = chunkIndex == 0 ? 9 : 2;
    final zp = DjvuZpDecoder(
      Uint8List.sublistView(chunk, payloadOffset),
      truncatedMessage: 'Truncated DjVu IW44 arithmetic stream.',
      allowShortPayload: true,
    );
    for (var slice = 0; slice < slices; slice++) {
      y.decodeSlice(zp);
      if (color) {
        if (chromaDelay == 0) {
          cb!.decodeSlice(zp);
          cr!.decodeSlice(zp);
        } else {
          chromaDelay--;
        }
      }
    }
  }

  final ySamples = y.takeSamples();
  late final Uint8List rgb;
  if (color) {
    final cbSamples = cb!.takeSamples();
    final crSamples = cr!.takeSamples();
    rgb = _convertYCbCrToRgb(ySamples, cbSamples, crSamples, layerPixels);
  } else {
    rgb = Uint8List(rgbBytes);
    for (var pixel = 0; pixel < layerPixels; pixel++) {
      final gray = 255 - ySamples[pixel];
      final offset = pixel * 3;
      rgb[offset] = gray;
      rgb[offset + 1] = gray;
      rgb[offset + 2] = gray;
    }
  }
  return DjvuIw44Raster(width: width, height: height, rgb: rgb);
}

({int width, int height, bool color, int chromaDelay, List<int> sliceCounts}) _preflightChunks(
  final List<Uint8List> chunks,
) {
  var expectedSerial = 0;
  var width = 0;
  var height = 0;
  var color = false;
  var chromaDelay = 0;
  var totalSlices = 0;
  final sliceCounts = <int>[];

  for (var index = 0; index < chunks.length; index++) {
    final chunk = chunks[index];
    if (chunk.length > _maxIw44ChunkBytes) {
      throw const DjvuException('DjVu IW44 chunk exceeds the 32 MiB chunk limit.');
    }
    final headerLength = index == 0 ? 9 : 2;
    if (chunk.length < headerLength) {
      throw const DjvuException('Truncated DjVu IW44 chunk header.');
    }
    final serial = chunk[0];
    final slices = chunk[1];
    if (serial != expectedSerial) {
      throw const DjvuException('DjVu IW44 chunks have a missing or repeated serial number.');
    }
    expectedSerial++;

    if (index == 0) {
      final version = chunk[2];
      final major = version & 0x7F;
      final minor = chunk[3];
      if (major != 1 || minor > 2) {
        throw const DjvuUnsupportedCodecException('DjVu IW44 version is not supported.');
      }
      color = (version & 0x80) == 0;
      width = (chunk[4] << 8) | chunk[5];
      height = (chunk[6] << 8) | chunk[7];
      if (width == 0 || height == 0 || width > _maxDimension || height > _maxDimension) {
        throw const DjvuException('Invalid DjVu IW44 layer dimensions.');
      }
      // The byte's high bit is reserved. In v1.2 the low seven bits carry the
      // chrominance delay; v1.0/v1.1 streams start chroma immediately.
      chromaDelay = minor >= 2 ? chunk[8] & 0x7F : 0;
    }

    totalSlices += slices;
    if (totalSlices > _maxIw44Slices) {
      throw const DjvuException('DjVu IW44 layer exceeds the 1024-slice limit.');
    }
    if (slices == 0 && chunk.length != headerLength) {
      throw const DjvuException('DjVu IW44 zero-slice chunk contains unexpected data.');
    }
    sliceCounts.add(slices);
  }
  if (totalSlices == 0) {
    throw const DjvuException('DjVu IW44 layer contains no coefficient slices.');
  }

  return (
    width: width,
    height: height,
    color: color,
    chromaDelay: chromaDelay,
    sliceCounts: sliceCounts,
  );
}

void _validateLayerDimensions(
  final int width,
  final int height,
  final int pageWidth,
  final int pageHeight,
) {
  for (var factor = 1; factor <= 12; factor++) {
    if ((pageWidth + factor - 1) ~/ factor == width &&
        (pageHeight + factor - 1) ~/ factor == height) {
      return;
    }
  }
  throw const DjvuException(
    'DjVu IW44 dimensions do not match an allowed 1-to-12 page sub-sampling factor.',
  );
}

Uint8List _convertYCbCrToRgb(
  final Uint8List y,
  final Uint8List cb,
  final Uint8List cr,
  final int pixels,
) {
  if (y.length != pixels || cb.length != pixels || cr.length != pixels) {
    throw const DjvuException('DjVu IW44 component dimensions do not match.');
  }
  final rgb = Uint8List(pixels * 3);
  for (var pixel = 0; pixel < pixels; pixel++) {
    final luma = y[pixel] - 128;
    final blueDifference = cb[pixel] - 128;
    final redDifference = cr[pixel] - 128;
    final t2 = redDifference + _shr(redDifference, 1);
    final t3 = luma + 128 - _shr(blueDifference, 2);
    final doubledBlue = (blueDifference << 1).toSigned(32);
    final offset = pixel * 3;
    rgb[offset] = (luma + 128 + t2).clamp(0, 255);
    rgb[offset + 1] = (t3 - _shr(t2, 1)).clamp(0, 255);
    rgb[offset + 2] = (t3 + doubledBlue).clamp(0, 255);
  }
  return rgb;
}

/// Arithmetic right shift whose result stays a signed 32-bit value on every
/// platform; compiled JavaScript leaves negative operands as their unsigned
/// 32-bit forms (the same normalization the wavelet and the JPEG 2000
/// decoder apply). The zero-bit shift normalizes the `<<` result too.
int _shr(final int value, final int bits) => (value >> bits).toSigned(32);

int _max(final int a, final int b) => a > b ? a : b;

final class _Iw44Plane {
  _Iw44Plane(this.width, this.height)
    : blockColumns = (width + 31) ~/ 32,
      blockRows = (height + 31) ~/ 32,
      paddedWidth = ((width + 31) ~/ 32) * 32,
      paddedHeight = ((height + 31) ~/ 32) * 32,
      coefficients = Int16List(((width + 31) ~/ 32) * ((height + 31) ~/ 32) * 1024);

  final int width;
  final int height;
  final int blockColumns;
  final int blockRows;
  final int paddedWidth;
  final int paddedHeight;
  Int16List? coefficients;
  final List<int> quantLow = List<int>.of(_quantLowInitial);
  final List<int> quantHigh = List<int>.of(_quantHighInitial);
  final Uint8List coefficientFlags = Uint8List(1024);
  final Uint8List bucketFlags = Uint8List(64);
  final Uint8List decodeCoefficientContexts = Uint8List(80);
  final Uint8List activateCoefficientContexts = Uint8List(16);
  var decodeBucketsContext = 0;
  var increaseCoefficientContext = 0;
  var band = 0;

  int get paddedPixels => paddedWidth * paddedHeight;
  int get pixels => width * height;
  int get blockCount => blockColumns * blockRows;

  int _offset(final int blockIndex, final int zigzagIndex) {
    final blockRow = blockIndex ~/ blockColumns;
    final blockColumn = blockIndex % blockColumns;
    final row = _zigzagRow(zigzagIndex);
    final column = _zigzagColumn(zigzagIndex);
    return (blockRow * 32 + row) * paddedWidth + blockColumn * 32 + column;
  }

  int _coefficient(final int blockIndex, final int zigzagIndex) =>
      coefficients![_offset(blockIndex, zigzagIndex)];

  void _setCoefficient(final int blockIndex, final int zigzagIndex, final int value) {
    coefficients![_offset(blockIndex, zigzagIndex)] = value;
  }

  void decodeSlice(final DjvuZpDecoder zp) {
    final lowBand = band == 0;
    if (lowBand ? _isNullLowSlice() : _isNullHighSlice()) {
      _finishSlice();
      return;
    }
    final (firstBucket, lastBucket) = _bandBuckets[band];
    final bucketCount = lastBucket - firstBucket + 1;
    for (var blockIndex = 0; blockIndex < blockCount; blockIndex++) {
      var blockFlags = 0;
      for (var relativeBucket = 0; relativeBucket < bucketCount; relativeBucket++) {
        final bucket = firstBucket + relativeBucket;
        var flags = 0;
        final start = bucket * 16;
        for (var item = 0; item < 16; item++) {
          final step = lowBand ? quantLow[item] : quantHigh[band];
          final coefficient = _coefficient(blockIndex, start + item);
          final state = step > 0 && step < 0x8000
              ? coefficient == 0
                    ? _potential
                    : _active
              : _zero;
          coefficientFlags[start + item] = state;
          flags |= state;
        }
        bucketFlags[relativeBucket] = flags;
        blockFlags |= flags;
      }

      final blockActive = blockFlags & _active != 0;
      final hasPotential = blockFlags & _potential != 0;
      final shouldDecodeBuckets =
          bucketCount < 16 || blockActive || (hasPotential && _decodeBucketDecision(zp));
      if (shouldDecodeBuckets) {
        for (var relativeBucket = 0; relativeBucket < bucketCount; relativeBucket++) {
          final flags = bucketFlags[relativeBucket];
          if (flags & _potential == 0) continue;
          final bucket = firstBucket + relativeBucket;
          var nonZero = 0;
          if (!lowBand) {
            final start = bucket * 4;
            for (var item = 0; item < 4; item++) {
              if (_coefficient(blockIndex, start + item) != 0) nonZero++;
            }
            if (nonZero == 4) nonZero = 3;
          }
          final contextIndex = band * 8 + nonZero + (blockActive ? 4 : 0);
          if (_decodeAdaptive(zp, decodeCoefficientContexts, contextIndex)) {
            bucketFlags[relativeBucket] = flags | _new;
          }
        }

        for (var relativeBucket = 0; relativeBucket < bucketCount; relativeBucket++) {
          final bucketState = bucketFlags[relativeBucket];
          if (bucketState & _new == 0) continue;
          final bucket = firstBucket + relativeBucket;
          final start = bucket * 16;
          var potentialRemaining = 0;
          for (var item = 0; item < 16; item++) {
            if (coefficientFlags[start + item] & _potential != 0) potentialRemaining++;
          }
          final contextBase = bucketState & _active != 0 ? 8 : 0;
          for (var item = 0; item < 16; item++) {
            final index = start + item;
            if (coefficientFlags[index] & _potential != 0) {
              final contextIndex = contextBase + (potentialRemaining < 7 ? potentialRemaining : 7);
              if (_decodeAdaptive(zp, activateCoefficientContexts, contextIndex)) {
                final negative = zp.decodePassthroughIw44();
                final step = lowBand ? quantLow[item] : quantHigh[band];
                final value = step + (step >> 1) - (step >> 3);
                _setCoefficient(blockIndex, index, negative ? -value : value);
                potentialRemaining = 0;
              }
              if (potentialRemaining > 0) potentialRemaining--;
            }
          }
        }
      }

      if (blockActive) {
        for (var relativeBucket = 0; relativeBucket < bucketCount; relativeBucket++) {
          final bucket = firstBucket + relativeBucket;
          final start = bucket * 16;
          for (var item = 0; item < 16; item++) {
            final index = start + item;
            if (coefficientFlags[index] & _active == 0) continue;
            final coefficient = _coefficient(blockIndex, index);
            final step = lowBand ? quantLow[item] : quantHigh[band];
            var magnitude = coefficient.abs();
            final usesContext = magnitude <= 3 * step;
            final increase = usesContext ? _decodeIncreaseDecision(zp) : zp.decodePassthroughIw44();
            if (usesContext) magnitude += step >> 2;
            magnitude += increase ? step >> 1 : -step + (step >> 1);
            _setCoefficient(blockIndex, index, coefficient < 0 ? -magnitude : magnitude);
          }
        }
      }
    }
    _finishSlice();
  }

  bool _decodeBucketDecision(final DjvuZpDecoder zp) {
    final decoded = zp.decodeBit(decodeBucketsContext);
    decodeBucketsContext = decoded.state;
    return decoded.bit;
  }

  bool _decodeIncreaseDecision(final DjvuZpDecoder zp) {
    final decoded = zp.decodeBit(increaseCoefficientContext);
    increaseCoefficientContext = decoded.state;
    return decoded.bit;
  }

  bool _isNullLowSlice() {
    for (final step in quantLow) {
      if (step > 0 && step < 0x8000) return false;
    }
    return true;
  }

  bool _isNullHighSlice() {
    final step = quantHigh[band];
    return step == 0 || step >= 0x8000;
  }

  void _finishSlice() {
    quantHigh[band] >>= 1;
    if (band == 0) {
      for (var index = 0; index < quantLow.length; index++) {
        quantLow[index] >>= 1;
      }
    }
    band = (band + 1) % _bandBuckets.length;
  }

  Uint8List takeSamples() {
    final source = coefficients;
    if (source == null) throw const DjvuException('DjVu IW44 plane was already reconstructed.');
    final output = reconstructDjvuIw44Plane(source, width: width, height: height);
    coefficients = null;
    return output;
  }
}

bool _decodeAdaptive(final DjvuZpDecoder zp, final Uint8List contexts, final int index) {
  final decoded = zp.decodeBit(contexts[index]);
  contexts[index] = decoded.state;
  return decoded.bit;
}

int _zigzagRow(final int index) {
  return ((index >> 1) & 1) * 16 +
      ((index >> 3) & 1) * 8 +
      ((index >> 5) & 1) * 4 +
      ((index >> 7) & 1) * 2 +
      ((index >> 9) & 1);
}

int _zigzagColumn(final int index) {
  return (index & 1) * 16 +
      ((index >> 2) & 1) * 8 +
      ((index >> 4) & 1) * 4 +
      ((index >> 6) & 1) * 2 +
      ((index >> 8) & 1);
}
