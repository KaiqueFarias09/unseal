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

/// The decoded visual content of one TIFF page: a BMP raster, or the
/// original JPEG bytes when the page passes through.
final class TiffPageImage {
  /// Creates a raster page.
  const TiffPageImage.raster({
    required this.width,
    required this.height,
    required this.dpi,
    required Uint8List this.bmp,
  }) : jpeg = null;

  /// Creates a JPEG passthrough page.
  const TiffPageImage.jpeg({
    required this.width,
    required this.height,
    required this.dpi,
    required Uint8List this.jpeg,
  }) : bmp = null;

  /// Page geometry in pixels.
  final int width;

  /// Page geometry in pixels.
  final int height;

  /// Horizontal resolution in dots per inch (0 when undeclared).
  final int dpi;

  /// The 24-bit BMP (top-left orientation) for raster pages.
  final Uint8List? bmp;

  /// The self-contained JPEG stream for passthrough pages.
  final Uint8List? jpeg;
}

/// The compression ids whose segments decode to a byte-aligned raster.
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
  if (_optionalUint(container, ifd, 266, fallback: 1) == 2) {
    throw const TiffUnsupportedCodecException(
      'TIFF page uses reversed bit fill order (FillOrder 2), not decoded.',
    );
  }
  final orientation = _orientation(container, ifd);

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
    orientation: orientation,
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

/// Accepts SampleFormat 1 (unsigned) and 4 (void): libtiff reads both as
/// plain integer samples, and `tiffcp` emits 4 for files carrying the
/// obsolete SGI DataType tag.
void _requireUintSampleFormat(final TiffContainer container, final TiffIfd ifd) {
  final entry = ifd[339];
  if (entry == null) return;
  for (final value in container.readUintList(entry)) {
    if (value != 1 && value != 4) {
      throw TiffUnsupportedCodecException('TIFF page uses the unsupported SampleFormat $value.');
    }
  }
}

/// Reads Orientation (274): 1-4 are honored by flipping the finished
/// raster, 5-8 (transposed) fail typed, and values libtiff ignores as
/// invalid fall back to top-left the way libtiff does.
int _orientation(final TiffContainer container, final TiffIfd ifd) {
  final value = _optionalUint(container, ifd, 274, fallback: 1);
  if (value >= 5 && value <= 8) {
    throw TiffUnsupportedCodecException(
      'TIFF page uses the transposed Orientation $value, which the display '
      'raster does not decode.',
    );
  }
  return value >= 1 && value <= 4 ? value : 1;
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

/// Reads a tile address array, falling back to the strip tag when the
/// tile tag is absent: libtiff stores both pairs in one field, and the
/// Silicon Graphics Image Library wrote tiled files with the strip tags.
List<int> _tileSegmentList(
  final TiffContainer container,
  final TiffIfd ifd, {
  required final int tileTag,
  required final int stripTag,
  required final String label,
}) {
  final entry = ifd[tileTag] ?? ifd[stripTag];
  if (entry == null) {
    throw TiffException('TIFF tiled page is missing the $label tag.');
  }
  return container.readUintList(entry);
}

/// Validates every segment (strip or tile) address of one page before any
/// buffer exists: file bounds, no overlap with the file header or the
/// page's own directory table, and no overlap between segments.
void _validateSegmentLayout(
  final TiffContainer container,
  final TiffIfd ifd,
  final List<int> offsets,
  final List<int> byteCounts,
) {
  final fileLength = container.bytes.length;
  final tableStart = ifd.offset;
  final tableEnd = ifd.offset + ifd.tableBytes;
  for (var index = 0; index < offsets.length; index++) {
    final offset = offsets[index];
    final byteCount = byteCounts[index];
    if (offset < 0 || byteCount <= 0) {
      throw TiffException('TIFF segment $index declares an invalid offset or byte count.');
    }
    if (offset > fileLength || byteCount > fileLength - offset) {
      throw TiffException(
        'TIFF segment $index ($offset + $byteCount bytes) lies beyond the file bounds.',
      );
    }
    if (offset < container.headerBytes) {
      throw TiffException('TIFF segment $index overlaps the file header.');
    }
    if (offset < tableEnd && byteCount > tableStart - offset) {
      throw TiffException('TIFF segment $index overlaps its own directory table.');
    }
  }
  final order = List<int>.generate(offsets.length, (final index) => index)
    ..sort((final a, final b) => offsets[a].compareTo(offsets[b]));
  for (var position = 1; position < order.length; position++) {
    final previous = order[position - 1];
    final current = order[position];
    if (byteCounts[previous] > offsets[current] - offsets[previous]) {
      throw TiffException('TIFF segments $previous and $current overlap.');
    }
  }
}

TiffPageImage _decodeJpegPage(
  final TiffContainer container,
  final TiffIfd ifd, {
  required final int width,
  required final int height,
  required final TiffDecodeBudget budget,
}) {
  if (ifd[322] != null || ifd[323] != null) {
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
  _validateSegmentLayout(container, ifd, offsets, byteCounts);
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
  required final int orientation,
  required final int dpi,
  required final TiffDecodeBudget budget,
}) {
  final isTiled = ifd[322] != null || ifd[323] != null;
  final sampleBytes = samplesPerPixel * (bits ~/ 8);
  int rowBytesFor(final int pixels) =>
      bits >= 8 ? pixels * sampleBytes : (pixels * bits * samplesPerPixel + 7) ~/ 8;
  final rowBytes = rowBytesFor(width);

  // The page is a grid of segments: tiles, or strips as a one-column grid.
  final List<int> segmentOffsets;
  final List<int> segmentByteCounts;
  final int segmentsAcross;
  final int segmentsDown;
  final int segmentRows;
  final int segmentWidth;
  if (isTiled) {
    final tileWidth = _requiredUint(container, ifd, 322, 'TileWidth');
    final tileLength = _requiredUint(container, ifd, 323, 'TileLength');
    if (tileWidth < 1 ||
        tileLength < 1 ||
        tileWidth > tiffMaxPagePixels ||
        tileLength > tiffMaxPagePixels) {
      throw const TiffException('Invalid TIFF tile dimensions.');
    }
    if (tileWidth * tileLength > tiffMaxPagePixels) {
      throw const TiffException('TIFF tile exceeds the 256-megapixel limit.');
    }
    segmentsAcross = (width + tileWidth - 1) ~/ tileWidth;
    segmentsDown = (height + tileLength - 1) ~/ tileLength;
    segmentRows = tileLength;
    segmentWidth = tileWidth;
    segmentOffsets = _tileSegmentList(
      container,
      ifd,
      tileTag: 324,
      stripTag: 273,
      label: 'TileOffsets',
    );
    segmentByteCounts = _tileSegmentList(
      container,
      ifd,
      tileTag: 325,
      stripTag: 279,
      label: 'TileByteCounts',
    );
  } else {
    final declaredRowsPerStrip = _optionalUint(container, ifd, 278, fallback: height);
    if (declaredRowsPerStrip < 1) {
      throw const TiffException('TIFF RowsPerStrip must be positive.');
    }
    segmentRows = declaredRowsPerStrip > height ? height : declaredRowsPerStrip;
    segmentsAcross = 1;
    segmentsDown = (height + segmentRows - 1) ~/ segmentRows;
    segmentWidth = width;
    segmentOffsets = _requiredUintList(container, ifd, 273, 'StripOffsets');
    segmentByteCounts = _requiredUintList(container, ifd, 279, 'StripByteCounts');
  }
  final segmentRowBytes = rowBytesFor(segmentWidth);

  final segmentCount = segmentsAcross * segmentsDown;
  if (segmentCount > tiffMaxSegmentsPerPage) {
    throw const TiffException('TIFF page exceeds the strip count limit.');
  }
  if (segmentOffsets.length != segmentCount || segmentByteCounts.length != segmentCount) {
    throw TiffException(
      'TIFF page declares ${segmentOffsets.length} offsets and '
      '${segmentByteCounts.length} byte counts for $segmentCount segments.',
    );
  }
  _validateSegmentLayout(container, ifd, segmentOffsets, segmentByteCounts);

  // Every tile decodes at its full footprint; only the last strip is
  // shorter. The budget takes the kept BMP, then the live scratch (RGB
  // conversion plus the decoded segment, which LZW and PackBits hold
  // twice while their chunks are joined), then the total decode work,
  // each before the matching allocation.
  final segmentBytes = segmentRows * segmentRowBytes;
  final rgbBytes = width * height * 3;
  final bmpBytes = bmpHeaderBytes + bmpRowStride(width) * height;
  budget.reserve(pixels: width * height, rasterBytes: bmpBytes);
  final scratchCopies = switch (compression) {
    tiffCompressionNone => predictor == 2 ? 1 : 0,
    tiffCompressionLzw || tiffCompressionPackbits => 2,
    _ => 1,
  };
  final scratchBytes = rgbBytes + segmentBytes * scratchCopies;
  budget.reserveScratch(scratchBytes);
  budget.reserveWork(isTiled ? segmentCount * segmentBytes : rowBytes * height);

  final rgb = Uint8List(rgbBytes);
  final isCcitt =
      compression == tiffCompressionCcittModifiedHuffman ||
      compression == tiffCompressionCcittG3 ||
      compression == tiffCompressionCcittG4;
  final ccittPlan = isCcitt
      ? tiffCcittPlan(
          compression: compression,
          t4Options: _optionalUint(container, ifd, 292, fallback: 0),
          t6Options: _optionalUint(container, ifd, 293, fallback: 0),
          fillOrder: _optionalUint(container, ifd, 266, fallback: 1),
        )
      : null;

  for (var segment = 0; segment < segmentCount; segment++) {
    final offset = segmentOffsets[segment];
    final byteCount = segmentByteCounts[segment];
    final encoded = Uint8List.sublistView(container.bytes, offset, offset + byteCount);
    final gridRow = segment ~/ segmentsAcross;
    final gridColumn = segment % segmentsAcross;
    final rowStart = gridRow * segmentRows;
    final columnStart = gridColumn * segmentWidth;
    final rows = isTiled || segmentRows < height - rowStart ? segmentRows : height - rowStart;
    final expectedBytes = rows * segmentRowBytes;
    var decoded = decodeTiffSegment(
      encoded,
      compression: compression,
      expectedBytes: expectedBytes,
      ccittPlan: ccittPlan,
      ccittColumns: isCcitt ? segmentWidth : 0,
      ccittRowBytes: isCcitt ? segmentRowBytes : 1,
    );
    if (predictor == 2) {
      // Uncompressed segments are views of the source; differencing must
      // not write into the bytes the book keeps.
      if (compression == tiffCompressionNone) decoded = Uint8List.fromList(decoded);
      applyTiffPredictor(
        decoded,
        rows: rows,
        rowBytes: segmentRowBytes,
        samplesPerPixel: samplesPerPixel,
        bytesPerSample: bits ~/ 8,
        endian: container.endian,
      );
    }
    final visibleRows = rows < height - rowStart ? rows : height - rowStart;
    final visibleColumns = segmentWidth < width - columnStart ? segmentWidth : width - columnStart;
    for (var row = 0; row < visibleRows; row++) {
      _unpackSamples(
        decoded,
        row * segmentRowBytes,
        rgb,
        (rowStart + row) * width + columnStart,
        samples: visibleColumns,
        bits: bits,
        samplesPerPixel: samplesPerPixel,
        photometric: photometric,
        endian: container.endian,
      );
    }
  }

  _applyOrientation(rgb, width: width, height: height, orientation: orientation);
  final bmp = encodeRgb24Bmp(width: width, height: height, rgb: rgb);
  budget.releaseScratch(scratchBytes);
  return TiffPageImage.raster(width: width, height: height, dpi: dpi, bmp: bmp);
}

/// Unpacks [samples] consecutive pixels of one source row into RGB bytes.
void _unpackSamples(
  final Uint8List source,
  final int sourceBase,
  final Uint8List rgb,
  final int rgbSampleBase, {
  required final int samples,
  required final int bits,
  required final int samplesPerPixel,
  required final int photometric,
  required final Endian endian,
}) {
  final data = ByteData.sublistView(source);
  for (var x = 0; x < samples; x++) {
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
        red = data.getUint16(sourceIndex, endian) >> 8;
        green = data.getUint16(sourceIndex + 2, endian) >> 8;
        blue = data.getUint16(sourceIndex + 4, endian) >> 8;
      }
    } else {
      // Gray: scale the sample to the 0..255 display range, then map
      // the photometric convention (0 = WhiteIsZero inverts).
      var value = bits == 16
          ? data.getUint16(sourceIndex, endian) >> 8
          : bits == 8
          ? source[sourceIndex]
          : _subByteSample(source, sourceBase, x, bits) * 255 ~/ ((1 << bits) - 1);
      if (photometric == 0) value = 255 - value;
      red = value;
      green = value;
      blue = value;
    }
    final target = (rgbSampleBase + x) * 3;
    rgb[target] = red;
    rgb[target + 1] = green;
    rgb[target + 2] = blue;
  }
}

/// Reads one 1/2/4-bit sample, most significant bit first.
int _subByteSample(final Uint8List source, final int sourceBase, final int x, final int bits) {
  final bitOffset = x * bits;
  final byte = source[sourceBase + (bitOffset >> 3)];
  final shift = 8 - bits - (bitOffset & 7);
  return (byte >> shift) & ((1 << bits) - 1);
}

/// Brings a stored raster to top-left orientation in place: 2 mirrors
/// rows, 3 rotates 180 degrees, 4 mirrors columns.
void _applyOrientation(
  final Uint8List rgb, {
  required final int width,
  required final int height,
  required final int orientation,
}) {
  void swapPixels(final int a, final int b) {
    for (var channel = 0; channel < 3; channel++) {
      final value = rgb[a * 3 + channel];
      rgb[a * 3 + channel] = rgb[b * 3 + channel];
      rgb[b * 3 + channel] = value;
    }
  }

  switch (orientation) {
    case 2:
      for (var y = 0; y < height; y++) {
        final row = y * width;
        for (var x = 0; x < width ~/ 2; x++) {
          swapPixels(row + x, row + width - 1 - x);
        }
      }
    case 3:
      final total = width * height;
      for (var index = 0; index < total ~/ 2; index++) {
        swapPixels(index, total - 1 - index);
      }
    case 4:
      final rowBytes = width * 3;
      final line = Uint8List(rowBytes);
      for (var y = 0; y < height ~/ 2; y++) {
        final top = y * rowBytes;
        final bottom = (height - 1 - y) * rowBytes;
        line.setRange(0, rowBytes, rgb, top);
        rgb.setRange(top, top + rowBytes, rgb, bottom);
        rgb.setRange(bottom, bottom + rowBytes, line);
      }
  }
}
