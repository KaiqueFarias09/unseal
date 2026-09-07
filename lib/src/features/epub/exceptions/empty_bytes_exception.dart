/// Exception thrown when an EPUB parser receives no bytes.
class EmptyBytesException implements Exception {
  /// Creates an exception with an optional explanatory [message].
  EmptyBytesException([this.message = 'Bytes cannot be empty']);

  /// Explanation associated with the empty-byte failure.
  final String message;

  @override
  String toString() => 'EmptyBytesException: $message';
}
