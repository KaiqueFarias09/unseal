import '../../../foundation/exceptions/unseal_exception.dart';

/// Error raised while opening a CB7 or CBC comic container.
class Comic7Exception extends UnsealException {
  /// Creates a [Comic7Exception].
  const Comic7Exception(super.message);

  @override
  String toString() => 'Comic7Exception: $message';
}

/// Thrown when a CB7/CBC input contains no readable image pages.
class Comic7PagesNotFoundException extends Comic7Exception {
  /// Creates a [Comic7PagesNotFoundException].
  const Comic7PagesNotFoundException(super.message);

  @override
  String toString() => 'Comic7PagesNotFoundException: $message';
}

/// Thrown when a CBC collection is missing or cannot resolve comics.txt.
class InvalidCbcCollectionException extends Comic7Exception {
  /// Creates an [InvalidCbcCollectionException].
  const InvalidCbcCollectionException(super.message);

  @override
  String toString() => 'InvalidCbcCollectionException: $message';
}
