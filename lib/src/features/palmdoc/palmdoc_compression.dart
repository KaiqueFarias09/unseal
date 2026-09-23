import 'dart:typed_data';

import '../../foundation/exceptions/unseal_exception.dart';

/// Expands one independent PalmDOC LZ77 text record with a hard output bound.
Uint8List decompressPalmdocRecord(final Uint8List data, {required final int maxOutputBytes}) {
  final bytes = <int>[];
  var offset = 0;

  void append(final int value) {
    if (bytes.length >= maxOutputBytes) {
      throw const InvalidBookException('PalmDOC decompression limit exceeded.');
    }
    bytes.add(value);
  }

  while (offset < data.length) {
    final first = data[offset++];
    if (first >= 1 && first <= 8) {
      if (offset + first > data.length) {
        throw const InvalidBookException('Truncated PalmDOC literal run.');
      }
      for (var i = 0; i < first; i++) {
        append(data[offset++]);
      }
    } else if (first <= 0x7F) {
      append(first);
    } else if (first >= 0xC0) {
      append(0x20);
      append(first ^ 0x80);
    } else {
      if (offset >= data.length) {
        throw const InvalidBookException('Truncated PalmDOC back reference.');
      }
      final pair = (first << 8) | data[offset++];
      final distance = (pair & 0x3FFF) >> 3;
      final length = (pair & 7) + 3;
      if (distance == 0 || distance > bytes.length) {
        throw const InvalidBookException('Invalid PalmDOC back reference.');
      }
      for (var i = 0; i < length; i++) {
        append(bytes[bytes.length - distance]);
      }
    }
  }
  return Uint8List.fromList(bytes);
}
