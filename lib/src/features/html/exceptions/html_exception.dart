import '../../../foundation/exceptions/elivre_exception.dart';

/// Error thrown while reading a standalone HTML file or an HTMLZ archive.
final class HtmlException extends ELivreException {
  /// Creates an HTML parsing error with a user-actionable message.
  const HtmlException(super.message);

  @override
  String toString() => 'HtmlException: $message';
}
