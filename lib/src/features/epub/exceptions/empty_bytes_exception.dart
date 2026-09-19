import '../../../foundation/exceptions/unseal_exception.dart';

/// Exception thrown when an EPUB parser receives no bytes.
///
/// Extends [UnsealException] so empty input upholds the library-wide
/// contract: every parse entry point fails TYPED, never with an
/// exception outside the hierarchy.
final class EmptyBytesException extends UnsealException {
  /// Creates an exception with an optional explanatory [message].
  EmptyBytesException([super.message = 'Bytes cannot be empty']);

  @override
  String toString() => 'EmptyBytesException: $message';
}
