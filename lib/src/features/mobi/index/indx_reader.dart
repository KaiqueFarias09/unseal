import 'dart:collection';
import 'dart:typed_data';

import 'package:e_livre/src/features/mobi/exceptions/exceptions.dart';
import 'package:e_livre/src/features/mobi/utils/decint.dart';

/// A TAGX tag definition.
class IndxTag {
  /// Creates a TAGX definition from its tag metadata.
  const IndxTag(this.tag, this.numOfValues, this.bitmask, this.eof);

  /// The numeric tag identifier.
  final int tag;

  /// The number of values encoded by the tag.
  final int numOfValues;

  /// The control-byte bitmask for the tag.
  final int bitmask;

  /// Whether this tag terminates the entry.
  final int eof;
}

/// Parsed INDX header fields used by the reader.
class IndxHeaderInfo {
  /// Creates parsed INDX header metadata.
  const IndxHeaderInfo({
    required this.start,
    required this.count,
    required this.code,
    required this.ncncx,
    required this.ordt1,
    required this.ordt2,
    required this.oentries,
    required this.tagxOffset,
  });

  /// The index start value.
  final int start;

  /// The number of index records.
  final int count;

  /// The index code value.
  final int code;

  /// The number of CNCX records.
  final int ncncx;

  /// The first ordinal table offset.
  final int ordt1;

  /// The second ordinal table offset.
  final int ordt2;

  /// The entry table offset.
  final int oentries;

  /// The TAGX section offset.
  final int tagxOffset;
}

/// Compiled NCX strings: offset -> decoded string.
class Cncx {
  /// Builds the string table from the CNCX records.
  Cncx(final List<Uint8List> records, this.codec) {
    var recordOffset = 0;
    for (final raw in records) {
      var pos = 0;
      while (pos < raw.length) {
        final (length, consumed) = decint(raw, pos);
        if (length > 0) {
          final start = pos + consumed;
          var end = start + length;
          if (end > raw.length) {
            end = raw.length;
          }
          strings[pos + recordOffset] = decodeBytes(Uint8List.sublistView(raw, start, end), codec);
        }
        pos += consumed + length;
      }
      recordOffset += 0x10000;
    }
  }

  /// The codec the strings are encoded with.
  final String codec;

  /// Offset -> string mapping.
  final Map<int, String> strings = <int, String>{};

  /// Returns the string at [offset], when present.
  String? get(final int offset) => strings[offset];
}

/// An index table: entry ident -> tag id -> list of values.
typedef IndxTable = LinkedHashMap<String, Map<int, List<int>>>;

/// Reads a Kindle INDX structure starting at record [index].
///
/// [recordAt] provides random access to the PDB records and
/// [recordCount] their total. Returns the parsed table and the
/// compiled NCX string table (empty when the index has none).
(IndxTable, Cncx) readIndex(
  final Uint8List Function(int) recordAt,
  final int recordCount,
  final int index,
  final String codec,
) {
  if (index < 0 || index >= recordCount) throw MobiException('INDX index $index out of range.');
  final data = recordAt(index);
  final header = _parseIndxHeader(data);
  final table = IndxTable();

  var cncx = Cncx(const <Uint8List>[], codec);
  if (header.ncncx > 0) {
    final off = index + header.count + 1;
    if (off + header.ncncx <= recordCount) {
      cncx = Cncx(List<Uint8List>.generate(header.ncncx, (final i) => recordAt(off + i)), codec);
    }
  }

  var tagSectionStart = header.tagxOffset;
  if (tagSectionStart + 4 > data.length || !_hasMagic(data, tagSectionStart, 'TAGX')) {
    final found = _findMagic(data, 'TAGX', 184);
    if (found > -1) {
      tagSectionStart = found;
    }
  }
  final (controlByteCount, tags) = _parseTagxSection(Uint8List.sublistView(data, tagSectionStart));

  for (var i = index + 1; i <= index + header.count && i < recordCount; i++) {
    _parseIndexRecord(table, recordAt(i), controlByteCount, tags, codec);
  }

  return (table, cncx);
}

IndxHeaderInfo _parseIndxHeader(final Uint8List data) {
  if (!_hasMagic(data, 0, 'INDX')) throw const MobiException('Not a valid INDX record.');
  final view = ByteData.sublistView(data);
  // 45 u32 words follow the magic: len..ncncx (13), 27 unknowns,
  // ocnt, oentries, ordt1, ordt2, tagx.
  const wordCount = 45;
  int word(final int i) => view.getUint32(4 + i * 4);
  if (4 + wordCount * 4 > data.length) throw const MobiException('Truncated INDX header.');

  return IndxHeaderInfo(
    start: word(4),
    count: word(5),
    code: word(6),
    ncncx: word(12),
    ordt1: word(42),
    ordt2: word(43),
    oentries: word(41),
    tagxOffset: word(44),
  );
}

(int, List<IndxTag>) _parseTagxSection(final Uint8List data) {
  if (!_hasMagic(data, 0, 'TAGX')) throw const MobiException('Not a valid TAGX section.');
  final view = ByteData.sublistView(data);
  final firstEntryOffset = view.getUint32(4);
  final controlByteCount = view.getUint32(8);
  final tags = <IndxTag>[];
  for (var i = 12; i + 4 <= firstEntryOffset && i + 4 <= data.length; i += 4) {
    tags.add(IndxTag(data[i], data[i + 1], data[i + 2], data[i + 3]));
  }

  return (controlByteCount, tags);
}

void _parseIndexRecord(
  final IndxTable table,
  final Uint8List data,
  final int controlByteCount,
  final List<IndxTag> tags,
  final String codec,
) {
  final header = _parseIndxHeader(data);
  final idxtPos = header.start;
  if (idxtPos + 4 > data.length || !_hasMagic(data, idxtPos, 'IDXT')) {
    return; // Calibre warns and continues.
  }
  final view = ByteData.sublistView(data);
  final entryCount = header.count;
  final positions = <int>[];
  for (var j = 0; j < entryCount; j++) {
    final at = idxtPos + 4 + 2 * j;
    if (at + 2 > data.length) break;
    positions.add(view.getUint16(at));
  }
  positions.add(idxtPos);

  for (var j = 0; j < entryCount && j + 1 < positions.length; j++) {
    final start = positions[j];
    final end = positions[j + 1];
    if (start >= end || end > data.length) {
      continue;
    }
    final rec = Uint8List.sublistView(data, start, end);
    var (ident, consumed) = decodeIndexString(rec, codec);
    if (ident.contains(String.fromCharCode(0))) {
      // Some guide idents are UTF-16; retry with a UTF-16 decode of
      // the length-prefixed bytes.
      final utf16 = _decodeUtf16Prefixed(rec);
      if (utf16 != null) {
        ident = utf16.$1;
        consumed = utf16.$2;
      }
    }
    if (consumed >= rec.length) {
      continue;
    }
    final tagMap = _getTagMap(controlByteCount, tags, Uint8List.sublistView(rec, consumed));
    table[ident] = tagMap;
  }
}

(String, int)? _decodeUtf16Prefixed(final Uint8List rec) {
  if (rec.isEmpty) return null;
  final length = rec[0];
  final available = length < rec.length - 1 ? length : rec.length - 1;
  final chunk = rec.sublist(1, 1 + available);
  final units = <int>[];
  for (var i = 0; i + 1 < chunk.length; i += 2) {
    units.add(chunk[i] << 8 | chunk[i + 1]);
  }

  return (String.fromCharCodes(units), 1 + available);
}

Map<int, List<int>> _getTagMap(
  final int controlByteCount,
  final List<IndxTag> tags,
  final Uint8List data,
) {
  final pending = <(int, int, int?, int?)>[];
  final controlLength = controlByteCount < data.length ? controlByteCount : data.length;
  var controlBytes = data.sublist(0, controlLength);
  var rest = Uint8List.sublistView(data, controlLength);

  for (final x in tags) {
    if (x.eof == 0x01) {
      if (controlBytes.isNotEmpty) {
        controlBytes = controlBytes.sublist(1);
      }
      continue;
    }
    if (controlBytes.isEmpty) {
      continue;
    }
    var value = controlBytes[0] & x.bitmask;
    if (value == 0) {
      continue;
    }
    int? valueCount;
    int? valueBytes;
    if (value == x.bitmask) {
      if (countSetBits(x.bitmask) > 1) {
        final (bytes, consumed) = decint(rest);
        valueBytes = bytes;
        rest = Uint8List.sublistView(rest, consumed);
      } else {
        valueCount = 1;
      }
    } else {
      var mask = x.bitmask;
      while ((mask & 1) == 0) {
        mask >>= 1;
        value >>= 1;
      }
      valueCount = value;
    }
    pending.add((x.tag, x.numOfValues, valueCount, valueBytes));
  }

  final result = <int, List<int>>{};
  for (final (tag, numOfValues, valueCount, valueBytes) in pending) {
    final values = <int>[];
    if (valueCount != null) {
      final toRead = valueCount * numOfValues;
      for (var i = 0; i < toRead; i++) {
        final (value, consumed) = decint(rest);
        rest = Uint8List.sublistView(rest, consumed);
        values.add(value);
      }
    } else if (valueBytes != null) {
      var totalConsumed = 0;
      while (totalConsumed < valueBytes) {
        final (value, consumed) = decint(rest);
        rest = Uint8List.sublistView(rest, consumed);
        totalConsumed += consumed;
        values.add(value);
      }
    }
    result[tag] = values;
  }

  return result;
}

bool _hasMagic(final Uint8List data, final int offset, final String magic) {
  if (offset + magic.length > data.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (data[offset + i] != magic.codeUnitAt(i)) return false;
  }

  return true;
}

int _findMagic(final Uint8List data, final String magic, final int from) {
  for (var i = from; i + magic.length <= data.length; i++) {
    if (_hasMagic(data, i, magic)) return i;
  }

  return -1;
}
