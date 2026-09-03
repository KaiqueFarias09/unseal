import 'dart:typed_data';

/// Strips the trailing data entries from a MOBI text record.
///
/// Text records can carry index and multibyte-overlap data appended
/// after the compressed text. [extraFlags] (from the MOBI header at
/// offset 0xF2) is a bitmask: bit 0 marks a multibyte overlap tail,
/// higher bits mark backward-encoded variable-width-sized entries.
Uint8List stripTrailingEntries(final Uint8List record, final int extraFlags) {
  var num = 0;
  final size = record.length;
  var flags = extraFlags >> 1;
  while (flags != 0) {
    if ((flags & 1) != 0) {
      final entrySize = _sizeofTrailingEntry(record, size - num);
      if (entrySize == null) return record;
      num += entrySize;
    }
    flags >>= 1;
  }
  if ((extraFlags & 1) != 0) {
    final off = size - num - 1;
    if (off < 0 || off >= record.length) {
      num += 1;
    } else {
      num += (record[off] & 0x3) + 1;
    }
  }
  if (num <= 0 || num >= record.length) return record;

  return Uint8List.sublistView(record, 0, record.length - num);
}

int? _sizeofTrailingEntry(final Uint8List record, final int psize) {
  var bitpos = 0;
  var result = 0;
  var size = psize;
  while (size > 0) {
    final v = record[size - 1];
    result |= (v & 0x7F) << bitpos;
    bitpos += 7;
    size -= 1;
    if ((v & 0x80) != 0 || bitpos >= 28 || size == 0) return result;
  }

  return null;
}
