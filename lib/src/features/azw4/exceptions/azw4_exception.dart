import '../../../foundation/exceptions/unseal_exception.dart';

/// Base exception for an AZW4 container that cannot be safely read.
class Azw4Exception extends UnsealException {
  /// Creates an [Azw4Exception] with [message].
  const Azw4Exception(super.message);

  @override
  String toString() => 'Azw4Exception: $message';
}

/// Thrown when a PalmDB/MOBI wrapper is malformed or violates the structural limits needed for safe
/// record extraction.
class Azw4InvalidContainerException extends Azw4Exception {
  /// Creates an [Azw4InvalidContainerException] with [message].
  const Azw4InvalidContainerException(super.message);

  @override
  String toString() => 'Azw4InvalidContainerException: $message';
}

/// Thrown when an AZW4 container has no complete embedded PDF.
class Azw4PdfNotFoundException extends Azw4Exception {
  /// Creates an [Azw4PdfNotFoundException] with [message].
  const Azw4PdfNotFoundException(super.message);

  @override
  String toString() => 'Azw4PdfNotFoundException: $message';
}

/// Thrown when the MOBI wrapper advertises encryption/DRM.
class Azw4DrmProtectedException extends DrmProtectedException {
  /// Creates an [Azw4DrmProtectedException] with [message].
  const Azw4DrmProtectedException(super.message);

  @override
  String toString() => 'Azw4DrmProtectedException: $message';
}
