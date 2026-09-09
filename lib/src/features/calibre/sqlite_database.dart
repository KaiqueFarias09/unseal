import 'dart:convert' as convert;
import 'dart:typed_data';

/// A read-only, dependency-free reader for the SQLite file format,
/// scoped to what Calibre's `metadata.db` needs: whole-table scans of
/// rowid tables (interior + leaf b-tree pages, overflow chains).
///
/// See https://www.sqlite.org/fileformat2.html.
///
/// This type is public-named only because Dart privacy is library-scoped. It remains an internal
/// Calibre implementation and is not exported from a package entry point.
final class SqliteDatabaseReader {
  /// Creates a reader over the complete bytes of a SQLite database file.
  SqliteDatabaseReader(final Uint8List bytes) : _bytes = bytes {
    final magic = convert.ascii.decode(_bytes.sublist(0, 15));
    if (!magic.startsWith('SQLite format 3')) {
      throw const FormatException('Not an SQLite database file.');
    }
    final view = ByteData.sublistView(_bytes);
    var pageSize = view.getUint16(16);
    if (pageSize == 1) pageSize = 65536;
    _pageSize = pageSize;
    _reserved = _bytes[20];
  }

  final Uint8List _bytes;
  late final int _pageSize;
  late final int _reserved;

  int get _usableSize => _pageSize - _reserved;

  int _u16(final int offset) => ByteData.sublistView(_bytes).getUint16(offset);
  int _u32(final int offset) => ByteData.sublistView(_bytes).getUint32(offset);

  /// Reads every row of the table rooted at [rootPage] as
  /// `(rowid, decoded column values)`.
  List<(int, List<Object?>)> readTable(final int rootPage) {
    final rows = <(int, List<Object?>)>[];
    _walk(rootPage, rows);
    return rows;
  }

  void _walk(final int pageNumber, final List<(int, List<Object?>)> rows) {
    final base = (pageNumber - 1) * _pageSize;
    // Page 1 carries the 100-byte database header before its b-tree
    // page header.
    final treeBase = base + (pageNumber == 1 ? 100 : 0);
    final type = _bytes[treeBase];
    final headerSize = type == 0x05 || type == 0x02 ? 12 : 8;
    final cellCount = _u16(treeBase + 3);
    final pointersStart = treeBase + headerSize;

    if (type == 0x05) {
      // Interior table page: cells point at child pages.
      for (var i = 0; i < cellCount; i++) {
        _walk(_u32(base + _u16(pointersStart + i * 2)), rows);
      }
      _walk(_u32(treeBase + 8), rows); // right-most child
      return;
    }
    if (type == 0x0D) {
      // Leaf table page: cells carry the records.
      for (var i = 0; i < cellCount; i++) {
        final cellOffset = _u16(pointersStart + i * 2);
        final (rowid, payload, overflowPage, payloadSize) = _readLeafCell(base, cellOffset);
        rows.add((rowid, _decodeRecord(_assemblePayload(payload, overflowPage, payloadSize))));
      }
      return;
    }
    throw FormatException('Unexpected SQLite page type 0x${type.toRadixString(16)}.');
  }

  (int, Uint8List, int, int) _readLeafCell(final int base, final int offset) {
    var pos = base + offset;
    final (payloadSize, afterSize) = _readVarint(pos);
    final (rowid, afterRowid) = _readVarint(afterSize);
    pos = afterRowid;

    final usable = _usableSize;
    final maxLocal = usable - 35;
    int localSize;
    if (payloadSize <= maxLocal) {
      localSize = payloadSize;
    } else {
      final minLocal = ((usable - 12) * 32 ~/ 255) - 23;
      final k = minLocal + ((payloadSize - minLocal) % (usable - 4));
      localSize = k <= maxLocal ? k : minLocal;
    }

    final payload = Uint8List.sublistView(_bytes, pos, pos + localSize);
    final overflowPage = localSize < payloadSize ? _u32(pos + localSize) : 0;
    return (rowid, Uint8List.fromList(payload), overflowPage, payloadSize);
  }

  Uint8List _assemblePayload(
    final Uint8List local,
    final int firstOverflowPage,
    final int payloadSize,
  ) {
    if (firstOverflowPage == 0) return local;

    final chunks = BytesBuilder(copy: false)..add(local);
    var page = firstOverflowPage;
    while (page != 0 && chunks.length < payloadSize) {
      final base = (page - 1) * _pageSize;
      final take = (payloadSize - chunks.length).clamp(0, _usableSize - 4);
      chunks.add(Uint8List.sublistView(_bytes, base + 4, base + 4 + take));
      page = _u32(base);
    }
    return chunks.toBytes();
  }

  (int, int) _readVarint(final int position) {
    var result = 0;
    var pos = position;
    for (var i = 0; i < 8; i++) {
      final byte = _bytes[pos];
      result = (result << 7) | (byte & 0x7F);
      pos++;
      if (byte & 0x80 == 0) return (result, pos);
    }
    result = (result << 8) | _bytes[pos];
    pos++;
    return (result, pos);
  }

  List<Object?> _decodeRecord(final Uint8List payload) {
    int readLocalVarint(final int position) {
      var result = 0;
      var pos = position;
      for (var i = 0; i < 8; i++) {
        final byte = payload[pos];
        result = (result << 7) | (byte & 0x7F);
        pos++;
        if (byte & 0x80 == 0) return result;
      }
      return (result << 8) | payload[pos];
    }

    final headerSize = readLocalVarint(0);
    var pos = 1;
    final serialTypes = <int>[];
    while (pos < headerSize) {
      final type = readLocalVarint(pos);
      serialTypes.add(type);
      // Multi-byte varints carry 7 bits per byte.
      while (payload[pos] & 0x80 != 0) {
        pos++;
      }
      pos++;
    }

    var body = headerSize;
    final values = <Object?>[];
    for (final type in serialTypes) {
      final (value, size) = _decodeValue(payload, body, type);
      values.add(value);
      body += size;
    }
    return values;
  }

  (Object?, int) _decodeValue(final Uint8List payload, final int offset, final int type) {
    int readInt(final int size) {
      var value = payload[offset] >= 0x80 ? -1 : 0;
      for (var i = 0; i < size; i++) {
        value = (value << 8) | payload[offset + i];
      }
      return value;
    }

    switch (type) {
      case 0:
        return (null, 0);
      case 1:
        return (readInt(1), 1);
      case 2:
        return (readInt(2), 2);
      case 3:
        return (readInt(3), 3);
      case 4:
        return (readInt(4), 4);
      case 5:
        return (readInt(6), 6);
      case 6:
        return (readInt(8), 8);
      case 7:
        return (ByteData.sublistView(payload).getFloat64(offset), 8);
      case 8:
        return (0, 0);
      case 9:
        return (1, 0);
      default:
        if (type >= 12 && type.isEven) {
          final size = (type - 12) ~/ 2;
          return (Uint8List.sublistView(payload, offset, offset + size), size);
        }
        if (type >= 13) {
          final size = (type - 13) ~/ 2;
          final bytes = Uint8List.sublistView(payload, offset, offset + size);
          return (convert.utf8.decode(bytes, allowMalformed: true), size);
        }
        throw FormatException('Unsupported SQLite serial type $type.');
    }
  }
}
