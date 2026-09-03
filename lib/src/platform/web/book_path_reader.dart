import 'dart:typed_data';

/// Web has no local filesystem path source for a book.
Future<Uint8List> readBookPath(final String value) {
  throw UnsupportedError('Opening a book from a path is not supported on web');
}

/// Path-backed reads are unavailable on web.
Future<T> withBookPath<T>(
  final String value,
  final Future<T> Function(Uint8List bytes, String sourcePath) operation,
) {
  throw UnsupportedError('Opening a book from a path is not supported on web');
}

/// Web has no local filesystem sidecar source.
Future<T?> readBookSidecar<T>(
  final String sourcePath,
  final T Function(String content) parse,
) async =>
    null;
