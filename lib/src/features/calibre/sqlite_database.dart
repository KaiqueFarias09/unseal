part of 'calibre_database.dart';

/// A read-only, dependency-free reader for the SQLite file format, scoped to what the importer's
/// `metadata.db` schema needs: whole-table scans of rowid tables (interior + leaf b-tree pages,
/// overflow chains).
///
/// See https://www.sqlite.org/fileformat2.html.
final class _SqliteDatabaseReader {
  _SqliteDatabaseReader(final Uint8List bytes) : _bytes = bytes {
    if (_bytes.length < 100 || !_hasSqliteHeader(_bytes)) {
      throw const FormatException('Not an SQLite database file.');
    }

    _view = ByteData.sublistView(_bytes);
    var pageSize = _view.getUint16(16);
    if (pageSize == 1) pageSize = 65536;
    final reserved = _bytes[20];
    if (!_isValidPageSize(pageSize) ||
        reserved >= pageSize ||
        _bytes.length < pageSize ||
        _bytes.length % pageSize != 0) {
      throw const FormatException('Invalid or truncated SQLite page layout.');
    }

    _pageSize = pageSize;
    _reserved = reserved;
  }

  final Uint8List _bytes;
  late final ByteData _view;
  late final int _pageSize;
  late final int _reserved;

  int get _usableSize => _pageSize - _reserved;

  int _u16(final int offset) => _view.getUint16(offset);
  int _u32(final int offset) => _view.getUint32(offset);

  /// Reads every row of the table rooted at [rootPage] as `(rowid, decoded column values)`.
  List<_DatabaseRow> readTable(final int rootPage) {
    try {
      final rows = <_DatabaseRow>[];
      _walk(rootPage, rows, <int>{});

      return rows;
    } on RangeError catch (error) {
      throw FormatException('Truncated or corrupt SQLite page data.', error);
    }
  }

  void _walk(final int pageNumber, final List<_DatabaseRow> rows, final Set<int> visitedPages) {
    if (!visitedPages.add(pageNumber)) {
      throw FormatException('SQLite b-tree contains a cycle at page $pageNumber.');
    }

    final base = _pageBase(pageNumber);
    // Page 1 carries the 100-byte database header before its b-tree page header.
    final treeBase = base + (pageNumber == 1 ? 100 : 0);
    final type = _bytes[treeBase];
    final headerSize = type == 0x05 || type == 0x02 ? 12 : 8;
    final cellCount = _u16(treeBase + 3);
    final pointersStart = treeBase + headerSize;
    final pageEnd = base + _usableSize;
    if (pointersStart + cellCount * 2 > pageEnd) {
      throw FormatException('SQLite page $pageNumber has an invalid cell pointer array.');
    }

    if (type == 0x05) {
      // Interior table page: cells point at child pages.
      for (var i = 0; i < cellCount; i++) {
        final cellOffset = _u16(pointersStart + i * 2);
        final cellPosition = base + cellOffset;
        if (cellPosition < base || cellPosition + 4 > pageEnd) {
          throw FormatException('SQLite page $pageNumber has an invalid interior cell.');
        }

        _walk(_u32(cellPosition), rows, visitedPages);
      }
      _walk(_u32(treeBase + 8), rows, visitedPages); // right-most child

      return;
    }
    if (type == 0x0D) {
      // Leaf table page: cells carry the records.
      for (var i = 0; i < cellCount; i++) {
        final cellOffset = _u16(pointersStart + i * 2);
        final (rowid, payload, overflowPage, payloadSize) = _readLeafCell(
          pageNumber,
          base,
          cellOffset,
        );
        rows.add((rowid, _decodeRecord(_assemblePayload(payload, overflowPage, payloadSize))));
      }

      return;
    }

    throw FormatException('Unexpected SQLite page type 0x${type.toRadixString(16)}.');
  }

  int _pageBase(final int pageNumber) {
    final pageCount = _bytes.length ~/ _pageSize;
    if (pageNumber < 1 || pageNumber > pageCount) {
      throw FormatException('SQLite page $pageNumber is outside the file.');
    }

    return (pageNumber - 1) * _pageSize;
  }

  (int, Uint8List, int, int) _readLeafCell(final int pageNumber, final int base, final int offset) {
    final pageEnd = base + _usableSize;
    var pos = base + offset;
    if (pos < base || pos >= pageEnd) {
      throw FormatException('SQLite page $pageNumber has an invalid leaf cell.');
    }

    final (payloadSize, afterSize) = _readVarint(_bytes, pos, end: pageEnd);
    final (rowid, afterRowid) = _readVarint(_bytes, afterSize, end: pageEnd);

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

    final cellEnd = pos + localSize + (localSize < payloadSize ? 4 : 0);
    if (cellEnd > pageEnd) {
      throw FormatException('SQLite page $pageNumber has a truncated leaf cell.');
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
    if (local.length == payloadSize) return local;
    if (firstOverflowPage == 0) {
      throw const FormatException('SQLite payload is missing its overflow chain.');
    }

    final chunks = BytesBuilder(copy: false)..add(local);
    final visitedPages = <int>{};
    var page = firstOverflowPage;
    while (page != 0 && chunks.length < payloadSize) {
      if (!visitedPages.add(page)) {
        throw FormatException('SQLite overflow chain contains a cycle at page $page.');
      }

      final base = _pageBase(page);
      final take = (payloadSize - chunks.length).clamp(0, _usableSize - 4);
      chunks.add(Uint8List.sublistView(_bytes, base + 4, base + 4 + take));
      page = _u32(base);
    }

    if (chunks.length < payloadSize || page != 0) {
      throw const FormatException('Truncated SQLite overflow chain.');
    }

    return chunks.toBytes();
  }

  (int, int) _readVarint(final Uint8List source, final int position, {final int? end}) {
    var result = 0;
    var pos = position;
    final limit = end ?? source.length;
    for (var i = 0; i < 8; i++) {
      if (pos >= limit) throw const FormatException('Truncated SQLite varint.');

      final byte = source[pos];
      result = (result << 7) | (byte & 0x7F);
      pos++;
      if (byte & 0x80 == 0) return (result, pos);
    }

    if (pos >= limit) throw const FormatException('Truncated SQLite varint.');

    result = (result << 8) | source[pos];
    pos++;

    return (result, pos);
  }

  List<Object?> _decodeRecord(final Uint8List payload) {
    final (headerSize, serialTypesStart) = _readVarint(payload, 0);
    if (headerSize < serialTypesStart || headerSize > payload.length) {
      throw const FormatException('Invalid SQLite record header size.');
    }

    var pos = serialTypesStart;
    final serialTypes = <int>[];
    while (pos < headerSize) {
      final (type, nextPosition) = _readVarint(payload, pos, end: headerSize);
      serialTypes.add(type);
      pos = nextPosition;
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

  static bool _hasSqliteHeader(final Uint8List bytes) {
    const signature = 'SQLite format 3';
    for (var index = 0; index < signature.length; index++) {
      if (bytes[index] != signature.codeUnitAt(index)) return false;
    }

    return bytes[signature.length] == 0;
  }

  static bool _isValidPageSize(final int pageSize) {
    return pageSize >= 512 && pageSize <= 65536 && pageSize & (pageSize - 1) == 0;
  }
}
