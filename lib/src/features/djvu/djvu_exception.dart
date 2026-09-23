import '../../foundation/exceptions/unseal_exception.dart';

/// Malformed or excessive DjVu input.
class DjvuException extends InvalidBookException {
  /// Creates a DjVu parse failure.
  const DjvuException(super.message);
}

/// A valid page whose image codec is not yet decoded by Unseal.
class DjvuUnsupportedCodecException extends FormatNotSupportedException {
  /// Creates an unsupported DjVu codec failure.
  const DjvuUnsupportedCodecException(super.message);
}
