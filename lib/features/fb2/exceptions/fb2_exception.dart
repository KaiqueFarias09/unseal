import 'package:e_livre/features/core/exceptions/elivre_exception.dart';

/// Error thrown while reading or parsing an FB2 book.
class Fb2Exception extends ELivreException {
  /// Creates an [Fb2Exception] with the given [message].
  const Fb2Exception(super.message);

  @override
  String toString() => 'Fb2Exception: $message';
}
