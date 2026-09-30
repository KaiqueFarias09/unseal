import 'djvu_exception.dart';

/// Maximum decoded page pixels materialized by one DjVu document.
///
/// Sized for real scanned books: the 121-page speller corpus file decodes to
/// ~1.4 gigapixels, so the cap admits multi-hundred-page scans while still
/// rejecting declarations beyond any legitimate book.
const djvuMaxDecodedPixelsPerBook = 2048 * 1000 * 1000;

/// Maximum raster bytes materialized by one DjVu document.
///
/// Sized alongside [djvuMaxDecodedPixelsPerBook]: full 24-bit BMP pages of a
/// real scanned book reach hundreds of MiB, and the cap must bound hostile
/// multi-page documents, not reject legitimate ones.
const djvuMaxDecodedRasterBytesPerBook = 1024 * 1024 * 1024;

/// Tracks decoded visual work across every page before its output is allocated.
///
/// Image decoders reserve both values before creating a page mask or raster.
/// A shared budget prevents bundled documents from multiplying page-level
/// limits into unbounded book-sized output.
final class DjvuDecodeBudget {
  var _decodedPixels = 0;
  var _rasterBytes = 0;

  /// Reserves decoded pixels and the materialized output bytes for one layer.
  void reserve({required final int pixels, required final int rasterBytes}) {
    if (pixels < 0 || rasterBytes < 0) {
      throw const DjvuException('Invalid DjVu decoded-image budget request.');
    }
    if (pixels > djvuMaxDecodedPixelsPerBook - _decodedPixels) {
      throw const DjvuException('DjVu document exceeds the 256-megapixel decoded-image limit.');
    }
    if (rasterBytes > djvuMaxDecodedRasterBytesPerBook - _rasterBytes) {
      throw const DjvuException('DjVu document exceeds the 128 MiB decoded-image byte limit.');
    }
    _decodedPixels += pixels;
    _rasterBytes += rasterBytes;
  }
}
