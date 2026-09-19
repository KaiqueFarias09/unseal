import '../../../foundation/exceptions/unseal_exception.dart';

/// Error thrown while reading or parsing a MOBI / AZW3 book.
class MobiException extends UnsealException {
  /// Creates a [MobiException] with the given [message].
  const MobiException(super.message);

  @override
  String toString() => 'MobiException: $message';
}
