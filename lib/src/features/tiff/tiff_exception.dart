import '../../foundation/exceptions/unseal_exception.dart';

/// Malformed or excessive TIFF input.
class TiffException extends InvalidBookException {
  /// Creates a TIFF parse failure.
  const TiffException(super.message);
}

/// A structurally valid TIFF page whose codec or layout Unseal does not
/// decode.
///
/// The message names the codec (by TIFF compression id) or layout and,
/// when measured, its incidence in the tracked scanned-archive corpus.
class TiffUnsupportedCodecException extends FormatNotSupportedException {
  /// Creates an unsupported TIFF codec or layout failure.
  const TiffUnsupportedCodecException(super.message);
}
