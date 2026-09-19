/// Base class for all exceptions thrown by Unseal.
class UnsealException implements Exception {
  /// Creates an [UnsealException] with the given [message].
  const UnsealException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => 'UnsealException: $message';
}

/// Thrown when the book format is recognized but not supported by Unseal.
class FormatNotSupportedException extends UnsealException {
  /// Creates a [FormatNotSupportedException] with the given [message].
  const FormatNotSupportedException(super.message);

  @override
  String toString() => 'FormatNotSupportedException: $message';
}

/// Thrown when a book is protected by DRM and cannot be parsed.
class DrmProtectedException extends UnsealException {
  /// Creates a [DrmProtectedException] with the given [message].
  const DrmProtectedException(super.message);

  @override
  String toString() => 'DrmProtectedException: $message';
}

/// Thrown when the underlying data cannot be parsed as the detected format.
class InvalidBookException extends UnsealException {
  /// Creates an [InvalidBookException] with the given [message].
  const InvalidBookException(super.message);

  @override
  String toString() => 'InvalidBookException: $message';
}
