import '../../foundation/exceptions/unseal_exception.dart';

/// Malformed, excessive, or inconsistent hOCR input.
class HocrException extends InvalidBookException {
  /// Creates an hOCR parse or binding failure.
  const HocrException(super.message);
}

/// A structurally sound hOCR document that declares a feature outside the
/// supported subset: an explicit `order` or `cflow` reading order.
class HocrUnsupportedFeatureException extends FormatNotSupportedException {
  /// Creates an hOCR out-of-subset failure.
  const HocrUnsupportedFeatureException(super.message);
}
