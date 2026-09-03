import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';

/// Error thrown while reading or parsing an EPUB document.
class EpubException extends ELivreException {
  /// Creates an [EpubException] with the given [message].
  EpubException(super.message);

  @override
  String toString() => 'EpubException: $message';
}
