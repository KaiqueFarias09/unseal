import 'dart:typed_data';

import '../entities/entities.dart';

/// Creates a typed binary entry while keeping the archive-relative path.
BinaryFile binaryFile(final String path, final List<int> bytes) {
  final name = path.split('/').last;
  final type = name.contains('.') ? name.split('.').last.toLowerCase() : '';

  return BinaryFile(
    content: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
    name: name,
    type: type,
    path: path,
  );
}

/// Creates a typed text entry while keeping the archive-relative path.
TextFile textFile(final String path, final String content, {final String? type}) {
  final name = path.split('/').last;
  return TextFile(
    content: content,
    name: name,
    type: type ?? (name.contains('.') ? name.split('.').last.toLowerCase() : ''),
    path: path,
  );
}
