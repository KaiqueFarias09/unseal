import 'dart:typed_data';

import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';

/// Random access to the records of a MOBI book.
abstract class PdbRecordAccess {
  /// Number of available records.
  int get count;

  /// Returns record [index].
  Uint8List record(final int index);
}

/// The PalmDB (PDB) header of a MOBI file plus zero-copy record access.
class PdbHeader implements PdbRecordAccess {
  /// Parses the PDB header of [bytes].
  PdbHeader.parse(final Uint8List bytes) {
    if (bytes.length < 78) {
      throw const InvalidBookException('File is too small to be a MOBI book.');
    }
    _bytes = bytes;
    final nameBytes = bytes.sublist(0, 32);
    final nameBuffer = StringBuffer();
    for (final byte in nameBytes) {
      if (byte == 0) break;
      nameBuffer.writeCharCode(byte);
    }
    name = nameBuffer.toString();

    final ident = String.fromCharCodes(bytes.sublist(60, 68)).toUpperCase();
    if (ident != 'BOOKMOBI' && ident != 'TEXTREAD') {
      throw InvalidBookException('Unknown book type: $ident');
    }
    this.ident = ident;

    final view = ByteData.sublistView(bytes);
    recordCount = view.getUint16(76);
    if (recordCount == 0 || 78 + recordCount * 8 > bytes.length) {
      throw const InvalidBookException('Invalid PDB record table.');
    }
    offsets = List<int>.generate(
      recordCount,
      (final i) => view.getUint32(78 + i * 8),
    );
  }

  late final Uint8List _bytes;

  /// The PDB database name (bytes 0..32).
  late final String name;

  /// The type identifier at offset 60 (`BOOKMOBI` or `TEXTREAD`).
  late final String ident;

  /// Number of records in the file.
  late final int recordCount;

  /// Record count via the [PdbRecordAccess] interface.
  @override
  int get count => recordCount;

  /// Offset of each record, in record order.
  late final List<int> offsets;

  /// Returns record [index] as a view into the original bytes.
  @override
  Uint8List record(final int index) {
    if (index < 0 || index >= recordCount) {
      throw InvalidBookException('Record $index out of range.');
    }
    final start = offsets[index];
    return Uint8List.sublistView(_bytes, start, start + recordLength(index));
  }

  /// Computes the length of record [index].
  int recordLength(final int index) {
    if (index == recordCount - 1) {
      return _bytes.length - offsets[index];
    }
    final next = offsets[index + 1];
    if (next > offsets[index]) {
      return next - offsets[index];
    }
    // Records stored out of order: use the nearest greater offset.
    var end = _bytes.length;
    for (final offset in offsets) {
      if (offset > offsets[index] && offset < end) {
        end = offset;
      }
    }
    return end - offsets[index];
  }
}
