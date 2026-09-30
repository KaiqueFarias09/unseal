import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;

import '../../features/djvu/djvu_exception.dart';
import '../../features/djvu/djvu_indirect.dart';

/// Reads a book from a local filesystem path.
Future<Uint8List> readBookPath(final String value) async {
  if (value.isEmpty) throw ArgumentError.value(value, 'value', 'Path cannot be empty');

  final file = File(value);
  if (!file.existsSync()) throw FileSystemException('No such file or directory', value);

  return file.readAsBytes();
}

/// Assembles an indirect DjVu document directory into a bundled image.
///
/// Returns [bytes] unchanged unless they are a DjVu directory whose DIRM
/// declares indirect components; the DIRM-named component files are then
/// loaded from the document's own directory. Every other input — bundled
/// DjVu documents included — returns null so the caller keeps its normal
/// parse path.
Future<Uint8List?> resolveIndirectDjvu(final Uint8List bytes, final String sourcePath) async {
  if (bytes.length < 16 ||
      String.fromCharCodes(bytes, 0, 4) != 'AT&T' ||
      String.fromCharCodes(bytes, 12, 16) != 'DJVM') {
    return null;
  }
  final directory = readDjvuDirectory(bytes);
  if (directory.bundled) return null;

  final directoryPath = path.dirname(sourcePath);
  return assembleIndirectDjvu(bytes, (final name) {
    final file = File(path.join(directoryPath, name));
    if (!file.existsSync()) {
      throw DjvuException('DjVu indirect component "$name" is missing next to the document.');
    }
    return file.readAsBytesSync();
  });
}

/// Runs [operation] with bytes and the normalized source path.
Future<T> withBookPath<T>(
  final String value,
  final Future<T> Function(Uint8List bytes, String sourcePath) operation,
) async {
  final bytes = await readBookPath(value);

  return operation(bytes, path.normalize(value));
}

/// Reads the first valid OPF sidecar next to [sourcePath].
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
