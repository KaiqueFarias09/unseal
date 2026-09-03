import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

/// Reads a book from a local filesystem path.
Future<Uint8List> readBookPath(final String value) async {
  if (value.isEmpty) throw ArgumentError.value(value, 'value', 'Path cannot be empty');

  final file = File(value);
  if (!file.existsSync()) throw FileSystemException('No such file or directory', value);

  return file.readAsBytes();
}

/// Runs [operation] with bytes and the normalized source path.
Future<T> withBookPath<T>(
  final String value,
  final Future<T> Function(Uint8List bytes, String sourcePath) operation,
) async {
  final bytes = await readBookPath(value);

  return operation(bytes, path.normalize(value));
}

/// Reads the first valid Calibre OPF sidecar next to [sourcePath].
Future<T?> readBookSidecar<T>(
  final String sourcePath,
  final T Function(String content) parse,
) async {
  final directory = path.dirname(sourcePath);
  final basename = path.basenameWithoutExtension(sourcePath);

  for (final candidate in ['$basename.opf', 'metadata.opf']) {
    final file = File(path.join(directory, candidate));
    if (!file.existsSync()) continue;

    try {
      return parse(await file.readAsString());
    } on Exception {
      // Keep trying the next candidate when a sidecar is malformed.
    }
  }

  return null;
}
