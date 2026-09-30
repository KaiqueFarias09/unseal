import 'dart:typed_data';

import '../../foundation/images/bmp_encoder.dart';
import '../../foundation/images/image_dimensions.dart';
import 'tiff_codec.dart';
import 'tiff_container.dart';
import 'tiff_exception.dart';
import 'tiff_limits.dart';

/// The passthrough size cap for one JPEG-in-TIFF page (the djvu BGjp
/// posture).
const _maxJpegBytes = 32 * 1024 * 1024;

/// The decoded visual content of one TIFF page: an RGB raster, or the
/// original JPEG bytes when the page passes through.
final class TiffPageImage {
  /// Creates a raster page.
  const TiffPageImage.raster({
    required this.width,
    required this.height,
    required this.dpi,
    required Uint8List this.rgb,
  }) : jpeg = null;

  /// Creates a JPEG passthrough page.
  const TiffPageImage.jpeg({
    required this.width,
    required this.height,
    required this.dpi,
    required Uint8List this.jpeg,
  }) : rgb = null;

  /// Page geometry in pixels.
  final int width;

  /// Page geometry in pixels.
  final int height;

  /// Horizontal resolution in dots per inch (0 when undeclared).
  final int dpi;

  /// Top-down row-major RGB888 raster for raster pages.
  final Uint8List? rgb;

  /// The self-contained JPEG stream for passthrough pages.
  final Uint8List? jpeg;
}

/// The compression ids whose strips decode to a byte-aligned raster.
const _rasterCompressions = <int>{
  tiffCompressionNone,
  tiffCompressionCcittModifiedHuffman,
  tiffCompressionCcittG3,
  tiffCompressionCcittG4,
  tiffCompressionLzw,
  tiffCompressionDeflate,
  tiffCompressionPackbits,
  tiffCompressionAdobeDeflate,
};

/// The bit depths rasterized into the 24-bit display model.
const _rasterizableBits = <int>{1, 2, 4, 8, 16};

/// Decodes one TIFF IFD into its displayable page image.
///
/// Every declared byte range is validated against the file bounds and
/// every output size against the budget BEFORE the corresponding
/// allocation, and unsupported codecs or layouts fail with
/// [TiffUnsupportedCodecException] naming the codec.
TiffPageImage decodeTiffPage(
  final TiffContainer container,
  final TiffIfd ifd, {
  required final TiffDecodeBudget budget,
}) {
  final width = _requiredUint(container, ifd, 256, 'ImageWidth');
  final height = _requiredUint(container, ifd, 257, 'ImageLength');
  if (width < 1 || height < 1 || width > tiffMaxPagePixels || height > tiffMaxPagePixels) {
    throw const TiffException('Invalid TIFF page dimensions.');
  }
  if (width * height > tiffMaxPagePixels) {
    throw const TiffException('TIFF page exceeds the 256-megapixel limit.');
  }

  final compression = _optionalUint(container, ifd, 259, fallback: 1);
  final samplesPerPixel = _optionalUint(container, ifd, 277, fallback: 1);
  if (samplesPerPixel < 1 || samplesPerPixel > tiffMaxSamplesPerPixel) {
    throw const TiffException('TIFF samples per pixel exceed the 4-sample cap.');
  }
  final bits = _bitsPerSample(container, ifd, samplesPerPixel);
  final planar = _optionalUint(container, ifd, 284, fallback: 1);
  if (planar != 1) {
    throw const TiffUnsupportedCodecException(
      'TIFF page stores planes separately (PlanarConfiguration 2), not decoded.',
    );
  }
  _requireUintSampleFormat(container, ifd);
  final predictor = _optionalUint(container, ifd, 317, fallback: 1);
  if (predictor != 1 && predictor != 2) {
    throw TiffUnsupportedCodecException('TIFF page uses the unsupported Predictor $predictor.');
  }

  if (_rasterCompressions.contains(compression)) {
    if (!_rasterizableBits.contains(bits)) {
      throw TiffUnsupportedCodecException(
        'TIFF page uses the $bits-bit sample depth, which the display '
        'raster does not decode.',
      );
    }
    if (predictor == 2 && bits % 8 != 0) {
      throw const TiffUnsupportedCodecException(
        'TIFF page combines horizontal differencing with a sub-byte sample depth.',
      );
    }
  }

  final photometric = _optionalUint(container, ifd, 262, fallback: bits == 1 ? 0 : 1);
  if (compression == tiffCompressionJpeg) {
    if (bits != 8 || (samplesPerPixel != 1 && samplesPerPixel != 3)) {
      throw const TiffException('TIFF JPEG page must hold 8-bit gray or RGB samples.');
    }
    return _decodeJpegPage(container, ifd, width: width, height: height, budget: budget);
  }
  if (compression == tiffCompressionOldJpeg) {
    throw TiffUnsupportedCodecException(
      'TIFF page needs the unsupported ${tiffCompressionName(tiffCompressionOldJpeg)} codec.',
    );
  }
  if (photometric == 3) {
    throw const TiffUnsupportedCodecException(
      'TIFF page uses a palette color map (PhotometricInterpretation 3), '
      'which the display raster does not decode.',
    );
  }
  if (photometric != 0 && photometric != 1 && photometric != 2) {
    throw TiffUnsupportedCodecException(
      'TIFF page uses the unsupported photometric interpretation $photometric.',
    );
  }
  if (photometric == 2 && bits < 8) {
    throw const TiffException('TIFF RGB page cannot use a sub-byte sample depth.');
  }
  if (bits < 8 && samplesPerPixel > 1) {
    throw const TiffException('TIFF sub-byte samples must be single-sample.');
  }

  final dpi = _pageDpi(container, ifd);
  return _rasterizePage(
    container,
    ifd,
    width: width,
    height: height,
    bits: bits,
    samplesPerPixel: samplesPerPixel,
    photometric: photometric,
    compression: compression,
    predictor: predictor,
    dpi: dpi,
    budget: budget,
  );
}

int _bitsPerSample(final TiffContainer container, final TiffIfd ifd, final int samplesPerPixel) {
  final entry = ifd[258];
  if (entry == null) return 1;
  final values = container.readUintList(entry);
  if (values.length != samplesPerPixel) {
    throw const TiffException('TIFF BitsPerSample does not match SamplesPerPixel.');
  }
  for (final value in values) {
    if (value < 1 || value > tiffMaxBitsPerSample) {
      throw const TiffException('TIFF BitsPerSample exceeds the 32-bit cap.');
    }
    if (value != values.first) {
      throw const TiffUnsupportedCodecException(
        'TIFF page mixes sample depths, which the display raster does not decode.',
      );
    }
  }
  return values.first;
}

void _requireUintSampleFormat(final TiffContainer container, final TiffIfd ifd) {
  final entry = ifd[339];
  if (entry == null) return;
  for (final value in container.readUintList(entry)) {
    if (value != 1) {
      throw TiffUnsupportedCodecException('TIFF page uses the unsupported SampleFormat $value.');
    }
  }
}

int _pageDpi(final TiffContainer container, final TiffIfd ifd) {
  final resolution = ifd[282];
  if (resolution == null) return 0;
  final value = container.readRational(resolution);
  final unit = _optionalUint(container, ifd, 296, fallback: 2);
  final dpi = switch (unit) {
    2 => value,
    3 => value * 2.54,
    _ => 0.0,
  };
  if (!dpi.isFinite || dpi <= 0 || dpi > 100000) return 0;
  return dpi.round();
}

int _requiredUint(
  final TiffContainer container,
  final TiffIfd ifd,
  final int tag,
  final String label,
) {
  final entry = ifd[tag];
  if (entry == null) {
    throw TiffException('TIFF page is missing the $label tag.');
  }
  return container.readUint(entry);
}

int _optionalUint(
  final TiffContainer container,
  final TiffIfd ifd,
  final int tag, {
  required final int fallback,
}) {
  final entry = ifd[tag];
  if (entry == null) return fallback;
  return container.readUint(entry);
}

List<int> _requiredUintList(
  final TiffContainer container,
  final TiffIfd ifd,
  final int tag,
  final String label,
) {
  final entry = ifd[tag];
  if (entry == null) {
    throw TiffException('TIFF page is missing the $label tag.');
  }
  return container.readUintList(entry);
}

/// Validates one segment (strip or tile) byte range against the file
/// bounds before any view or buffer is created.
void _validateSegmentRange(
  final TiffContainer container, {
  required final int offset,
  required final int byteCount,
  required final int index,
}) {
  if (offset < 0 || byteCount <= 0) {
    throw TiffException('TIFF segment $index declares an invalid offset or byte count.');
  }
  if (offset > container.bytes.length || byteCount > container.bytes.length - offset) {
    throw TiffException(
      'TIFF segment $index ($offset + $byteCount bytes) lies beyond the file bounds.',
    );
  }
}

TiffPageImage _decodeJpegPage(
  final TiffContainer container,
  final TiffIfd ifd, {
  required final int width,
  required final int height,
  required final TiffDecodeBudget budget,
}) {
  if (ifd[322] != null) {
    throw const TiffUnsupportedCodecException(
      'TIFF JPEG page is tiled; tiled JPEG is not decoded.',
    );
  }
  final offsets = _requiredUintList(container, ifd, 273, 'StripOffsets');
  final byteCounts = _requiredUintList(container, ifd, 279, 'StripByteCounts');
  if (offsets.length != 1 || byteCounts.length != 1) {
    throw TiffUnsupportedCodecException(
      'TIFF JPEG page is not a single self-contained JPEG strip '
      '(${offsets.length} strips; JPEGTables tiling is not decoded).',
    );
  }
  final offset = offsets.single;
  final byteCount = byteCounts.single;
  if (byteCount > _maxJpegBytes) {
    throw const TiffException('TIFF JPEG page exceeds its size limit or is empty.');
  }
  if (ifd[347] != null) {
    throw const TiffUnsupportedCodecException(
      'TIFF JPEG page shares quantization/Huffman tables through the '
      'JPEGTables tag; abbreviated strip streams are not decoded.',
    );
  }
  _validateSegmentRange(container, offset: offset, byteCount: byteCount, index: 0);
  final encoded = Uint8List.sublistView(container.bytes, offset, offset + byteCount);
  requireSelfContainedTiffJpeg(encoded, strips: 1);
  budget.reserve(pixels: 0, rasterBytes: encoded.length);
  final size = imageSize(encoded);
  if (size == null || size.width < 1 || size.height < 1) {
    throw const TiffException('TIFF JPEG strip does not contain a valid JPEG header.');
  }
  if (size.width > width || size.height > height) {
    throw const TiffException('TIFF JPEG dimensions exceed the page dimensions.');
  }
  return TiffPageImage.jpeg(
    width: width,
    height: height,
    dpi: _pageDpi(container, ifd),
    jpeg: Uint8List.fromList(encoded),
  );
}

TiffPageImage _rasterizePage(
  final TiffContainer container,
  final TiffIfd ifd, {
  required final int width,
  required final int height,
  required final int bits,
  required final int samplesPerPixel,
  required final int photometric,
  required final int compression,
  required final int predictor,
  required final int dpi,
  required final TiffDecodeBudget budget,
}) {
  final isTiled = ifd[322] != null;
  final sampleBytes = samplesPerPixel * (bits ~/ 8);
  final rowBytes = bits >= 8 ? width * sampleBytes : (width * bits * samplesPerPixel + 7) ~/ 8;

  final List<int> segmentOffsets;
  final List<int> segmentByteCounts;
  var segmentsAcross = 1;
  var segmentsDown = 1;
  var segmentRows = height;
  var segmentRowBytes = rowBytes;
  if (isTiled) {
    final tileWidth = _requiredUint(container, ifd, 322, 'TileWidth');
    final tileLength = _requiredUint(container, ifd, 323, 'TileLength');
    if (tileWidth < 1 ||
        tileLength < 1 ||
        tileWidth > tiffMaxPagePixels ||
        tileLength > tiffMaxPagePixels) {
      throw const TiffException('Invalid TIFF tile dimensions.');
    }
    segmentsAcross = (width + tileWidth - 1) ~/ tileWidth;
    segmentsDown = (height + tileLength - 1) ~/ tileLength;
    segmentRows = tileLength;
    segmentRowBytes = bits >= 8
        ? tileWidth * sampleBytes
        : (tileWidth * bits * samplesPerPixel + 7) ~/ 8;
    segmentOffsets = _requiredUintList(container, ifd, 324, 'TileOffsets');
    segmentByteCounts = _requiredUintList(container, ifd, 325, 'TileByteCounts');
  } else {
    final declaredRowsPerStrip = _optionalUint(container, ifd, 278, fallback: height);
    if (declaredRowsPerStrip < 1) {
      throw const TiffException('TIFF RowsPerStrip must be positive.');
    }
    segmentRows = declaredRowsPerStrip > height ? height : declaredRowsPerStrip;
    segmentOffsets = _requiredUintList(container, ifd, 273, 'StripOffsets');
    segmentByteCounts = _requiredUintList(container, ifd, 279, 'StripByteCounts');
  }

  final segmentCount = isTiled ? segmentsAcross * segmentsDown : _stripCount(height, segmentRows);
  if (segmentCount > tiffMaxSegmentsPerPage) {
    throw const TiffException('TIFF page exceeds the strip count limit.');
  }
  if (segmentOffsets.length != segmentCount || segmentByteCounts.length != segmentCount) {
    throw TiffException(
      'TIFF page declares ${segmentOffsets.length} offsets and '
      '${segmentByteCounts.length} byte counts for $segmentCount segments.',
    );
  }

  final expectedSegmentBytes = segmentRows * segmentRowBytes;
  final rasterBytes = rowBytes * height;
  final bmpBytes = bmpHeaderBytes + bmpRowStride(width) * height;
  budget.reserve(pixels: width * height, rasterBytes: rasterBytes + bmpBytes);

  final rgb = Uint8List(width * height * 3);
  final isCcitt =
      compression == tiffCompressionCcittModifiedHuffman ||
      compression == tiffCompressionCcittG3 ||
      compression == tiffCompressionCcittG4;

  for (var segment = 0; segment < segmentCount; segment++) {
    final offset = segmentOffsets[segment];
    final byteCount = segmentByteCounts[segment];
    _validateSegmentRange(container, offset: offset, byteCount: byteCount, index: segment);
    final encoded = Uint8List.sublistView(container.bytes, offset, offset + byteCount);

    final expectedBytes = isTiled || segment + 1 < segmentCount
        ? expectedSegmentBytes
        : (height - (segmentCount - 1) * segmentRows) * segmentRowBytes;
    final ccittPlan = isCcitt
        ? tiffCcittPlan(
            compression: compression,
            t4Options: _optionalUint(container, ifd, 292, fallback: 0),
            t6Options: _optionalUint(container, ifd, 293, fallback: 0),
            fillOrder: _optionalUint(container, ifd, 266, fallback: 1),
          )
        : null;
    final decoded = decodeTiffSegment(
      encoded,
      compression: compression,
      expectedBytes: expectedBytes,
      ccittPlan: ccittPlan,
      ccittColumns: isCcitt ? width : 0,
      ccittRowBytes: isCcitt ? (width + 7) ~/ 8 : 1,
    );
    if (predictor == 2) {
      applyTiffPredictor(
        decoded,
        rows: expectedBytes ~/ segmentRowBytes,
        rowBytes: segmentRowBytes,
        sampleBytes: sampleBytes,
      );
    }

    if (isTiled) {
      final tileRow = segment ~/ segmentsAcross;
      final tileColumn = segment % segmentsAcross;
      _copyTile(
        decoded,
        rgb,
        tileRow: tileRow,
        tileColumn: tileColumn,
        segmentRowBytes: segmentRowBytes,
        segmentRows: segmentRows,
        width: width,
        height: height,
        segmentsAcross: segmentsAcross,
        bits: bits,
        samplesPerPixel: samplesPerPixel,
        photometric: photometric,
        endian: container.endian,
      );
    } else {
      final rows = expectedBytes ~/ segmentRowBytes;
      for (var row = 0; row < rows; row++) {
        _unpackSamples(
          decoded,
          row * segmentRowBytes,
          rgb,
          (segment * segmentRows + row) * width,
          startSample: 0,
          samples: width,
          bits: bits,
          samplesPerPixel: samplesPerPixel,
          photometric: photometric,
          endian: container.endian,
        );
      }
    }
  }

  return TiffPageImage.raster(width: width, height: height, dpi: dpi, rgb: rgb);
}

int _stripCount(final int height, final int rowsPerStrip) =>
    (height + rowsPerStrip - 1) ~/ rowsPerStrip;

void _copyTile(
  final Uint8List decoded,
  final Uint8List rgb, {
  required final int tileRow,
  required final int tileColumn,
  required final int segmentRowBytes,
  required final int segmentRows,
  required final int width,
  required final int height,
  required final int segmentsAcross,
  required final int bits,
  required final int samplesPerPixel,
  required final int photometric,
  required final Endian endian,
}) {
  final tileWidth = segmentRowBytes * 8 ~/ (bits * samplesPerPixel);
  final rowStart = tileRow * segmentRows;
  final columnStart = tileColumn * tileWidth;
  final rows = segmentRows < height - rowStart ? segmentRows : height - rowStart;
  final columns = tileWidth < width - columnStart ? tileWidth : width - columnStart;
  for (var row = 0; row < rows; row++) {
    _unpackSamples(
      decoded,
      row * segmentRowBytes,
      rgb,
      (rowStart + row) * width + columnStart,
      startSample: 0,
      samples: columns,
      bits: bits,
      samplesPerPixel: samplesPerPixel,
      photometric: photometric,
      endian: endian,
    );
  }
}

/// Unpacks [samples] consecutive pixel samples starting at absolute
/// sample index [startSample] within the source row into RGB bytes.
void _unpackSamples(
  final Uint8List source,
  final int sourceBase,
  final Uint8List rgb,
  final int rgbSampleBase, {
  required final int startSample,
  required final int samples,
  required final int bits,
  required final int samplesPerPixel,
  required final int photometric,
  required final Endian endian,
}) {
  final data = ByteData.sublistView(source);
  for (var sample = 0; sample < samples; sample++) {
    final x = startSample + sample;
    final sourceIndex = sourceBase + x * samplesPerPixel * (bits ~/ 8);
    int red;
    int green;
    int blue;
    if (photometric == 2) {
      if (bits == 8) {
        red = source[sourceIndex];
        green = source[sourceIndex + 1];
        blue = source[sourceIndex + 2];
      } else {
        red = _u16Sample(data, sourceIndex, endian) >> 8;
        green = _u16Sample(data, sourceIndex + 2, endian) >> 8;
        blue = _u16Sample(data, sourceIndex + 4, endian) >> 8;
      }
    } else {
      // Gray: scale the sample to the 0..255 display range, then map
      // the photometric convention (0 = WhiteIsZero inverts).
      var value = bits == 16
          ? _u16Sample(data, sourceIndex, endian) >> 8
          : bits == 8
          ? source[sourceIndex]
          : _subByteSample(source, sourceBase, x, bits) * 255 ~/ ((1 << bits) - 1);
      if (photometric == 0) value = 255 - value;
      red = value;
      green = value;
      blue = value;
    }
    final target = (rgbSampleBase + sample) * 3;
    rgb[target] = red;
    rgb[target + 1] = green;
    rgb[target + 2] = blue;
  }
}

int _u16Sample(final ByteData data, final int offset, final Endian endian) =>
    data.getUint16(offset, endian);

/// Reads one 1/2/4-bit sample, most significant bit first.
int _subByteSample(final Uint8List source, final int sourceBase, final int x, final int bits) {
  final bitOffset = x * bits;
  final byte = source[sourceBase + (bitOffset >> 3)];
  final shift = 8 - bits - (bitOffset & 7);
  return (byte >> shift) & ((1 << bits) - 1);
}
