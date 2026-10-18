/// Hard budgets and shared code-block style flags for the JPEG 2000
/// codec. Every allocation (rasters, tile buffers, coefficient
/// buffers, tag trees, packet bookkeeping) is checked against these
/// numbers before memory is reserved, in arithmetic that stays exact
/// on the VM and on JavaScript doubles.
library;

/// Code-block style flag: arithmetic coding bypass (lazy) passes.
const int kJpxCblkStyleBypass = 0x01;

/// Maximum codestream or JP2 payload the codec accepts.
const int kJpxMaxInputBytes = 256 << 20;

/// Maximum samples per component of the decoded raster
/// (16k x 16k): bounds the final image allocation per component.
const int kJpxMaxRasterSamples = 1 << 28;

/// Maximum bytes of the interleaved decode work buffers (tile
/// component data across all components), mirroring the 256 MiB
/// packed-image cap the PDF bitmap codecs already apply.
const int kJpxMaxTileBufferBytes = 256 << 20;

/// Standard cap on codestream components (SIZ Csiz is 16 bits, the
/// Part 1 limit is 16384).
const int kJpxMaxComponents = 16384;

/// Part 1 decomposition-level limit plus slack for validation.
const int kJpxMaxDecompositionLevels = 32;

/// Maximum number of quality layers.
const int kJpxMaxLayers = 16384;

/// Maximum tile-parts per tile.
const int kJpxMaxTileParts = 65536;

/// Maximum number of tiles (products beyond this are rejected before
/// any tile bookkeeping is allocated).
const int kJpxMaxTiles = 1 << 24;

/// Maximum code-block coefficients (a code-block is at most 4096
/// samples by the standard; this guards corrupted headers too).
const int kJpxMaxCodeblockSamples = 4096;

/// Sub-band exponent cap (SIZ coordinates live in 31 bits).
const int kJpxMaxCoordinate = (1 << 31) - 1;

/// Lowest unsigned sample precision the codec decodes.
const int kJpxMinPrecision = 8;

/// Highest unsigned sample precision the codec decodes; 16 bits keeps
/// every native plane inside a Uint16List and the 2x coefficient
/// convention inside 32-bit integers.
const int kJpxMaxPrecision = 16;

/// Largest XRsiz/YRsiz the standard allows (one byte each).
const int kJpxMaxSubsampling = 255;

/// Quantization entries a QCD/QCC may carry: 3 bands per decomposition
/// level plus LL, for the 32-level cap (OpenJPEG's OPJ_J2K_MAXBANDS).
const int kJpxMaxBands = 3 * (kJpxMaxDecompositionLevels + 1) - 2;

/// Cap on the bytes of each decoded stage that the image keeps
/// resident — native planes, reference-grid planes (upsampled or RGB
/// converted) and PNG scanlines — checked before the stage allocates.
const int kJpxMaxImageBytes = 256 << 20;

/// [kJpxMaxTileBufferBytes] is generous for work buffers; the raster
/// the PDF layer turns into a PNG also respects the codec-wide cap.
const int kJpxMaxPngBytes = 256 << 20;

/// Multiplies without overflowing JavaScript doubles or wrapping the
/// VM int: throws [kJpxBudgetMessage] when the product leaves the
/// safe range every budget is compared against.
int checkedProduct(final int first, final int second) {
  final product = first.toDouble() * second.toDouble();
  if (product > 9007199254740992.0) {
    throw const _BudgetExceeded();
  }
  return first * second;
}

/// The single user-visible message every budget breach raises.
const String kJpxBudgetMessage =
    'JPEG 2000 stream declares sizes beyond '
    'the codec budget.';

final class _BudgetExceeded implements Exception {
  const _BudgetExceeded();
}

/// Casts a declared but unvalidated count, converting a budget
/// breach into the typed [kJpxBudgetMessage] failure.
int budgeted(final int value) {
  if (value < 0) throw const _BudgetExceeded();
  return value;
}
