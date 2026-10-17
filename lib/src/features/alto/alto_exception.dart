import '../../foundation/exceptions/unseal_exception.dart';

/// Malformed, excessive, or out-of-subset ALTO input.
class AltoException extends InvalidBookException {
  /// Creates an ALTO parse failure.
  const AltoException(super.message);
}

/// A structurally valid ALTO document whose declared version, namespace,
/// or feature set sits outside the supported subset.
class AltoUnsupportedFeatureException extends FormatNotSupportedException {
  /// Creates an ALTO out-of-subset failure.
  const AltoUnsupportedFeatureException(super.message);
}

/// A coordinate conversion that cannot be verified: the document's unit
/// is physical and no verifiable scale (dpi or page-dimension agreement)
/// was supplied.
class AltoUnitConversionException extends AltoException {
  /// Creates an unverifiable-conversion failure.
  const AltoUnitConversionException(super.message);
}
