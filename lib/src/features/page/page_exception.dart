import '../../foundation/exceptions/unseal_exception.dart';

/// Malformed, excessive, or inconsistent PAGE XML input.
class PageXmlException extends InvalidBookException {
  /// Creates a PAGE parse failure.
  const PageXmlException(super.message);
}

/// A structurally well-formed PAGE document whose namespace version or
/// declared feature set sits outside the supported 2019-07-15 subset.
class PageXmlUnsupportedFeatureException extends FormatNotSupportedException {
  /// Creates a PAGE out-of-subset failure.
  const PageXmlUnsupportedFeatureException(super.message);
}
