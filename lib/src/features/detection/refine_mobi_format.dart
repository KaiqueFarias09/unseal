import 'dart:typed_data';

import '../../foundation/entities/entities.dart';

/// Refines the [BookFormat] for MOBI family bytes.
///
/// Reads the PDB record table and the MOBI header to distinguish MOBI 6 from KF8 (AZW3).
BookFormat refineMobiFormat(final Uint8List bytes) {
  final record0Offset = _recordOffset(0, bytes);
  if (bytes.length < record0Offset + 0x6C + 4) return BookFormat.mobi;

  final byteData = ByteData.sublistView(bytes);
  final mobiVersion = byteData.getUint32(record0Offset + 0x68);

  return mobiVersion == 8 ? BookFormat.azw3 : BookFormat.mobi;
}

int _recordOffset(final int record, final Uint8List bytes) {
  return ByteData.sublistView(bytes).getUint32(78 + record * 8);
}
