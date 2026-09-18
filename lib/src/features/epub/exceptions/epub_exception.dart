import '../../../foundation/exceptions/elivre_exception.dart';

/// Error thrown while reading or parsing an EPUB document.
final class EpubException extends ELivreException {
  /// Creates an [EpubException] with the given [message].
  EpubException(super.message);

  @override
  String toString() => 'EpubException: $message';
}
