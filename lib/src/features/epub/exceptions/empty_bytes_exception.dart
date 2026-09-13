import '../../../foundation/exceptions/elivre_exception.dart';

/// Exception thrown when an EPUB parser receives no bytes.
///
/// Extends [ELivreException] so empty input upholds the library-wide
/// contract: every parse entry point fails TYPED, never with an
/// exception outside the hierarchy.
final class EmptyBytesException extends ELivreException {
  /// Creates an exception with an optional explanatory [message].
  EmptyBytesException([super.message = 'Bytes cannot be empty']);

  @override
  String toString() => 'EmptyBytesException: $message';
}
