import 'dart:typed_data';

import 'tiff_exception.dart';

/// The input-size limit for one TIFF document.
const tiffMaxInputBytes = 128 * 1024 * 1024;

/// The page-count limit for one TIFF IFD chain.
const tiffMaxPages = 1024;

/// The per-IFD entry-count sanity cap.
const tiffMaxIfdEntries = 0x10000;

/// The per-page pixel cap (the 256-megapixel house ceiling).
const tiffMaxPagePixels = 256 * 1000 * 1000;

/// The samples-per-pixel cap (covers gray, RGB, and RGBA layouts).
const tiffMaxSamplesPerPixel = 4;

/// The bits-per-sample security cap applied before any codec runs.
const tiffMaxBitsPerSample = 32;

/// The per-page strip/tile count cap.
const tiffMaxSegmentsPerPage = 1 << 20;

/// The per-entry array-value cap, checked before any list allocation.
const tiffMaxValueCount = 1 << 20;

/// The ASCII value cap for metadata strings.
const tiffMaxAsciiBytes = 1 << 20;

/// Maximum decoded page pixels materialized by one TIFF document.
const tiffMaxDecodedPixelsPerBook = 256 * 1000 * 1000;

/// Maximum raster bytes materialized by one TIFF document.
const tiffMaxDecodedRasterBytesPerBook = 128 * 1024 * 1024;

/// Tracks decoded visual work across every page before its output is
/// allocated.
///
/// Raster decoders reserve both values before creating page rasters. A
/// shared budget prevents multipage documents from multiplying
/// page-level limits into unbounded book-sized output.
final class TiffDecodeBudget {
  var _decodedPixels = 0;
  var _rasterBytes = 0;

  /// Reserves decoded pixels and the materialized output bytes for one
  /// page or strip.
  void reserve({required final int pixels, required final int rasterBytes}) {
    if (pixels < 0 || rasterBytes < 0) {
      throw const TiffException('Invalid TIFF decoded-image budget request.');
    }
    if (pixels > tiffMaxDecodedPixelsPerBook - _decodedPixels) {
      throw const TiffException('TIFF document exceeds the 256-megapixel decoded-image limit.');
    }
    if (rasterBytes > tiffMaxDecodedRasterBytesPerBook - _rasterBytes) {
      throw const TiffException('TIFF document exceeds the 128 MiB decoded-image byte limit.');
    }
    _decodedPixels += pixels;
    _rasterBytes += rasterBytes;
  }
}

/// Checks that [offset]..`offset + length` lies inside [bytes] without
/// ever adding two attacker-controlled values (the subtraction form
/// cannot overflow 64-bit ints).
void requireTiffRange(final Uint8List bytes, final int offset, final int length) {
  if (offset < 0 || length < 0 || offset > bytes.length || length > bytes.length - offset) {
    throw TiffException(
      'TIFF value at offset $offset with length $length lies beyond the file bounds.',
    );
  }
}
