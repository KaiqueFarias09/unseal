import '../../../foundation/exceptions/unseal_exception.dart';

/// Error thrown while reading or parsing a comic book.
class ComicException extends UnsealException {
  /// Creates a [ComicException] with the given [message].
  const ComicException(super.message);

  @override
  String toString() => 'ComicException: $message';
}
