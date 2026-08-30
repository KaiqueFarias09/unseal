import 'package:e_livre/features/core/exceptions/elivre_exception.dart';

/// Error thrown while reading or parsing a comic book.
class ComicException extends ELivreException {
  /// Creates a [ComicException] with the given [message].
  const ComicException(super.message);

  @override
  String toString() => 'ComicException: $message';
}
