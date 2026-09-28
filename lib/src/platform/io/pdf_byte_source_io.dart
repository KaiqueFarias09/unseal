import 'dart:io';
import 'dart:typed_data';

import '../../features/pdf/reader/pdf_byte_source.dart';

/// Source over a local PDF file: every read is a seek-and-slice, so a
/// session never holds the whole document in memory to parse it.
final class FilePdfByteSource implements PdfByteSource {
  FilePdfByteSource._(this._access, this.length);

  /// Opens [path] for random access.
  static FilePdfByteSource open(final String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('No such file or directory', path);
    }

    final access = file.openSync();
    final length = access.lengthSync();

    return FilePdfByteSource._(access, length);
  }

  final RandomAccessFile _access;

  /// Total source length in bytes.
  @override
  final int length;

  @override
  Uint8List read(final int offset, final int count) {
    RangeError.checkValidRange(offset, offset + count, length, 'offset', 'end');
    _access.setPositionSync(offset);

    return _access.readSync(count);
  }

  @override
  void close() {
    try {
      _access.closeSync();
    } on FileSystemException {
      // Already closed when the session raced its own teardown.
    }
  }
}
