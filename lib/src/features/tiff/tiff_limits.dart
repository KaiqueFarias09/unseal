import 'dart:typed_data';

import 'tiff_exception.dart';

/// The input-size limit for one TIFF document.
const tiffMaxInputBytes = 128 * 1024 * 1024;

/// The page-count limit for one TIFF IFD chain.
const tiffMaxPages = 1024;

/// The per-IFD entry-count sanity cap.
const tiffMaxIfdEntries = 0x10000;

/// The per-page pixel cap (the 256-megapixel house ceiling), also applied
/// to one tile footprint.
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

/// Maximum resident decoded bytes for one TIFF document: materialized
/// page images plus the live conversion and segment scratch buffers.
const tiffMaxDecodedRasterBytesPerBook = 128 * 1024 * 1024;

/// Maximum decoded segment bytes for one TIFF document, counted at the
/// full strip or tile footprint (edge-tile padding included) and never
/// released. Bounds the work a small page can demand through oversized
/// tiles regardless of how little output it keeps.
const tiffMaxDecodedWorkBytesPerBook = 512 * 1024 * 1024;

/// Tracks decoded visual work across every page before its output is
/// allocated.
///
/// Independent counters guard one document: decoded pixels, resident
/// bytes (materialized page images plus live scratch), and cumulative
/// decode work. Raster decoders reserve each of them before creating the
/// corresponding buffer, so multipage documents cannot multiply
/// page-level limits into unbounded book-sized output, and a page cannot
/// pay for oversized temporary tiles with a small raster.
final class TiffDecodeBudget {
  var _decodedPixels = 0;
  var _materializedBytes = 0;
  var _scratchBytes = 0;
  var _workBytes = 0;

  /// Decoded pixels reserved so far.
  int get decodedPixels => _decodedPixels;

  /// Bytes held by page images kept for the document's lifetime.
  int get materializedBytes => _materializedBytes;

  /// Bytes currently reserved by live scratch buffers.
  int get scratchBytes => _scratchBytes;

  /// Decoded segment bytes accumulated so far.
  int get workBytes => _workBytes;

  /// Reserves decoded pixels and the materialized output bytes of one
  /// page image. Both stay reserved for the document's lifetime.
  void reserve({required final int pixels, required final int rasterBytes}) {
    if (pixels < 0 || rasterBytes < 0) {
      throw const TiffException('Invalid TIFF decoded-image budget request.');
    }
    if (pixels > tiffMaxDecodedPixelsPerBook - _decodedPixels) {
      throw const TiffException('TIFF document exceeds the 256-megapixel decoded-image limit.');
    }
    if (rasterBytes > tiffMaxDecodedRasterBytesPerBook - _materializedBytes - _scratchBytes) {
      throw const TiffException('TIFF document exceeds the 128 MiB decoded-image byte limit.');
    }
    _decodedPixels += pixels;
    _materializedBytes += rasterBytes;
  }

  /// Reserves a transient buffer (segment scratch, RGB conversion) against
  /// the resident cap; [releaseScratch] returns it when the page completes.
  void reserveScratch(final int bytes) {
    if (bytes < 0) {
      throw const TiffException('Invalid TIFF decoded-image budget request.');
    }
    if (bytes > tiffMaxDecodedRasterBytesPerBook - _materializedBytes - _scratchBytes) {
      throw const TiffException(
        'TIFF page scratch buffers exceed the 128 MiB decoded-image byte limit.',
      );
    }
    _scratchBytes += bytes;
  }

  /// Returns [bytes] of scratch reserved by [reserveScratch].
  void releaseScratch(final int bytes) {
    if (bytes < 0 || bytes > _scratchBytes) {
      throw const TiffException('Invalid TIFF decoded-image budget release.');
    }
    _scratchBytes -= bytes;
  }

  /// Accounts [bytes] of segment decoding at full footprint. Never released.
  void reserveWork(final int bytes) {
    if (bytes < 0) {
      throw const TiffException('Invalid TIFF decoded-image budget request.');
    }
    if (bytes > tiffMaxDecodedWorkBytesPerBook - _workBytes) {
      throw const TiffException('TIFF document exceeds the 512 MiB decode-work limit.');
    }
    _workBytes += bytes;
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
