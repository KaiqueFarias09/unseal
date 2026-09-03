/// Base class for all exceptions thrown by eLivre.
class ELivreException implements Exception {
  /// Creates an [ELivreException] with the given [message].
  const ELivreException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => 'ELivreException: $message';
}

/// Thrown when the book format is recognized but not supported by eLivre.
class FormatNotSupportedException extends ELivreException {
  /// Creates a [FormatNotSupportedException] with the given [message].
  const FormatNotSupportedException(super.message);

  @override
  String toString() => 'FormatNotSupportedException: $message';
}

/// Thrown when a book is protected by DRM and cannot be parsed.
class DrmProtectedException extends ELivreException {
  /// Creates a [DrmProtectedException] with the given [message].
  const DrmProtectedException(super.message);

  @override
  String toString() => 'DrmProtectedException: $message';
}

/// Thrown when the underlying data cannot be parsed as the detected format.
class InvalidBookException extends ELivreException {
  /// Creates an [InvalidBookException] with the given [message].
  const InvalidBookException(super.message);

  @override
  String toString() => 'InvalidBookException: $message';
}
