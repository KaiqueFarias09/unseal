import 'dart:typed_data';

/// Web has no local filesystem path source for a book.
Future<Uint8List> readBookPath(final String value) async {
  throw UnsupportedError('Opening a book from a path is not supported on web');
}

/// Path-backed reads are unavailable on web.
Future<T> withBookPath<T>(
  final String value,
  final Future<T> Function(Uint8List bytes, String sourcePath) operation,
) async {
  throw UnsupportedError('Opening a book from a path is not supported on web');
}

/// Web has no local filesystem sidecar source.
Future<T?> readBookSidecar<T>(
  final String sourcePath,
  final T Function(String content) parse,
) async => null;

/// Indirect DjVu components cannot resolve on web: there is no filesystem to
/// load sibling files from. Bytes-only callers keep the typed rejection.
Future<Uint8List?> resolveIndirectDjvu(final Uint8List bytes, final String sourcePath) async =>
    null;
