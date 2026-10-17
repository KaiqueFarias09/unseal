import 'dart:convert';
import 'dart:typed_data';

import 'bzz_decoder.dart';
import 'djvu_exception.dart';

/// Maximum decompressed size of one TXTz chunk, matching the uncompressed
/// OCR text bound applied to TXTa chunks.
const int _maxTextChunkBytes = 8 * 1024 * 1024;

/// Maximum number of zone records in one TXTz chunk, counted over the
/// whole tree (the page zone and every descendant).
const int _maxTextZones = 65536;

/// Maximum zone nesting depth. The stored grammar lets child records
/// carry any type — real encoders usually nest page>column>region>
/// paragraph>line>word, but the reference decoder imposes no order, so
/// the bound is plain depth, not a type ordering.
const int _maxZoneDepth = 32;

/// Zone record grammar constants (DjVu 3 spec §8.3.5, matching the
/// reference decoder's field layout byte for byte).
const int _zoneRecordBytes = 17;

/// The page zone type: the tree's root record.
const int djvuZoneTypePage = 1;

/// The column zone type: a vertical slice of the page.
const int djvuZoneTypeColumn = 2;

/// The region zone type: a block-level text area.
const int djvuZoneTypeRegion = 3;

/// The paragraph zone type.
const int djvuZoneTypeParagraph = 4;

/// The line zone type.
const int djvuZoneTypeLine = 5;

/// The word zone type.
const int djvuZoneTypeWord = 6;

/// The character zone type: the finest stored level.
const int djvuZoneTypeCharacter = 7;
const int _coordinateBias = 0x8000;

/// One TXTz hidden-text chunk: the page text plus its decoded zone tree.
final class DjvuTextChunk {
  const DjvuTextChunk._({required this.text, required this.zoneCount, required this.root});

  /// Page text in reading order, with the zone separators rendered the way
  /// positional text extraction renders them: a page-zone NUL separator
  /// becomes LF followed by a form feed.
  final String text;

  /// Number of decoded zone records (page, column, region, paragraph, line,
  /// word, or character zones).
  final int zoneCount;

  /// The page zone's decoded subtree, or null when the chunk carries text
  /// without zone records.
  final DjvuTextZone? root;

  /// The page text's UTF-16 length — the offset unit the zones' canonical
  /// ranges use.
  int get utf16Length => text.length;

  /// Rebuilds a chunk from already-decoded parts — the wire decoder's
  /// path. Validates the same invariants the grammar decoder enforces;
  /// [ArgumentError] reports a payload that disagrees with itself.
  factory DjvuTextChunk.restore({
    required final String text,
    required final int zoneCount,
    required final DjvuTextZone? root,
  }) {
    if (zoneCount < 0 || zoneCount > _maxTextZones) {
      throw ArgumentError.value(zoneCount, 'zoneCount', 'Outside the zone-count bounds');
    }
    if (root != null && root.recordCount() != zoneCount) {
      throw ArgumentError.value(zoneCount, 'zoneCount', 'Disagrees with the tree');
    }

    return DjvuTextChunk._(text: text, zoneCount: zoneCount, root: root);
  }
}

/// One node of the TXTz zone tree, decoded to absolute values.
///
/// [xmin]/[ymin]/[xmax]/[ymax] keep the DjVu page coordinate system:
/// origin at the bottom-left corner, y growing upward, integer pixels —
/// the same convention `djvutxt` and `djvused print-txt` report.
/// [utf8Start]/[utf8Length] are the zone's range in the stored UTF-8 text;
/// [utf16Start]/[utf16End] are the same range in the rendered chunk
/// [DjvuTextChunk.text], inclusive start and exclusive end in UTF-16 code
/// units.
final class DjvuTextZone {
  const DjvuTextZone._({
    required this.type,
    required this.xmin,
    required this.ymin,
    required this.xmax,
    required this.ymax,
    required this.utf8Start,
    required this.utf8Length,
    required this.utf16Start,
    required this.utf16End,
    required this.children,
  });

  /// The zone type: 1 page, 2 column, 3 region, 4 paragraph, 5 line,
  /// 6 word, 7 character.
  final int type;

  /// Left edge, in DjVu page pixels.
  final int xmin;

  /// Bottom edge, in DjVu page pixels (origin at the page's bottom-left).
  final int ymin;

  /// Right edge, in DjVu page pixels.
  final int xmax;

  /// Top edge, in DjVu page pixels.
  final int ymax;

  /// The zone text's first byte in the stored UTF-8 page text.
  final int utf8Start;

  /// The zone text's byte length in the stored UTF-8 page text.
  final int utf8Length;

  /// The zone text's first UTF-16 code unit in the rendered chunk text.
  final int utf16Start;

  /// One past the zone text's last UTF-16 code unit.
  final int utf16End;

  /// The zone's children, in stored order.
  final List<DjvuTextZone> children;

  /// The zone text's UTF-16 length.
  int get utf16Length => utf16End - utf16Start;

  /// The subtree's record count, including this zone.
  int recordCount() {
    var total = 1;
    for (final child in children) {
      total += child.recordCount();
    }

    return total;
  }

  /// Rebuilds a zone from already-decoded parts — the wire decoder's
  /// path. Validates the stored invariants; [ArgumentError] reports a
  /// payload that disagrees with itself.
  factory DjvuTextZone.restore({
    required final int type,
    required final int xmin,
    required final int ymin,
    required final int xmax,
    required final int ymax,
    required final int utf8Start,
    required final int utf8Length,
    required final int utf16Start,
    required final int utf16End,
    required final List<DjvuTextZone> children,
  }) {
    if (type < djvuZoneTypePage || type > djvuZoneTypeCharacter) {
      throw ArgumentError.value(type, 'type', 'Outside the stored zone types');
    }
    if (xmin >= xmax || ymin >= ymax) {
      throw ArgumentError('Zone rectangles must have positive area');
    }
    if (utf8Start < 0 || utf8Length < 0 || utf16Start < 0 || utf16End < utf16Start) {
      throw ArgumentError('Zone ranges must be non-negative and ordered');
    }

    return DjvuTextZone._(
      type: type,
      xmin: xmin,
      ymin: ymin,
      xmax: xmax,
      ymax: ymax,
      utf8Start: utf8Start,
      utf8Length: utf8Length,
      utf16Start: utf16Start,
      utf16End: utf16End,
      children: children,
    );
  }
}

/// Decodes a BZZ-compressed TXTz chunk (DjVu 3 spec, §8.3.5).
///
/// The decompressed grammar is a 24-bit text length, the UTF-8 page text, a
/// version byte, and the zone-record tree. Every record is validated
/// (bounds, alignment, nesting, record count) and mapped onto the rendered
/// text's UTF-16 offsets.
DjvuTextChunk decodeDjvuTextChunk(final Uint8List encoded) {
  final raw = decodeDjvuBzz(
    encoded,
    truncatedMessage: 'Truncated DjVu TXTz chunk.',
    maxOutputBytes: _maxTextChunkBytes,
  );
  return decodeDjvuTextChunkRaw(raw);
}

/// Validates the decompressed TXTz grammar of [raw] and extracts its text
/// and zone tree.
///
/// Split from [decodeDjvuTextChunk] so hostile decompressed payloads can be
/// exercised directly.
DjvuTextChunk decodeDjvuTextChunkRaw(final Uint8List raw) {
  if (raw.length < 4) {
    throw const DjvuException('Truncated DjVu TXTz text.');
  }
  final textLength = (raw[0] << 16) | (raw[1] << 8) | raw[2];
  if (textLength > raw.length - 4) {
    throw const DjvuException('Truncated DjVu TXTz text.');
  }
  if (raw[3 + textLength] != 1) {
    throw const DjvuException('Unsupported DjVu TXTz version.');
  }
  final zoneBytes = raw.length - 4 - textLength;
  if (zoneBytes % _zoneRecordBytes != 0) {
    throw const DjvuException('DjVu TXTz zone records are misaligned.');
  }
  final recordCount = zoneBytes ~/ _zoneRecordBytes;
  if (recordCount > _maxTextZones) {
    throw const DjvuException('DjVu TXTz chunk exceeds the 65536-zone limit.');
  }

  final String text;
  try {
    text = utf8.decode(Uint8List.sublistView(raw, 3, 3 + textLength));
  } on FormatException {
    throw const DjvuException('DjVu TXTz text is not valid UTF-8.');
  }
  final rendered = _renderPositional(text);
  final index = _Utf8ByteIndex(stored: text, byteLength: textLength);

  final budget = _RecordBudget(recordCount);
  final root = recordCount == 0
      ? null
      : _decodeZone(raw, 4 + textLength, budget, index, depth: 1).zone;

  if (root != null && budget.remaining != 0) {
    throw const DjvuException('DjVu TXTz zone records do not form one tree.');
  }

  return DjvuTextChunk._(text: rendered, zoneCount: recordCount, root: root);
}

/// Renders the stored text with the separator convention of positional text
/// extraction: the NUL that separates page zones becomes LF + form feed.
String _renderPositional(final String text) {
  if (!text.contains('\x00')) return text;
  return text.replaceAll('\x00', '\n\x0C');
}

/// The remaining zone records one tree decode may still consume.
class _RecordBudget {
  _RecordBudget(this.remaining);

  int remaining;

  void consume() {
    remaining--;
    if (remaining < 0) {
      throw const DjvuException('DjVu TXTz chunk exceeds the 65536-zone limit.');
    }
  }
}

/// The parent-side values a child record's deltas accumulate against.
class _ZoneFrame {
  const _ZoneFrame({
    required this.xmin,
    required this.ymax,
    required this.utf8Start,
    required this.utf8Length,
    required this.type,
  });

  final int xmin;
  final int ymax;
  final int utf8Start;
  final int utf8Length;
  final int type;
}

class _DecodedRecord {
  const _DecodedRecord(this.zone, this.nextRecord, this.frame);

  final DjvuTextZone zone;
  final int nextRecord;
  final _ZoneFrame frame;
}

_DecodedRecord _decodeZone(
  final Uint8List raw,
  final int start,
  final _RecordBudget budget,
  final _Utf8ByteIndex index, {
  required final int depth,
  final DjvuTextZone? prev,
  final _ZoneFrame? parent,
}) {
  budget.consume();
  if (depth > _maxZoneDepth) {
    throw const DjvuException('DjVu TXTz zone tree exceeds the depth limit.');
  }
  if (start + _zoneRecordBytes > raw.length) {
    throw const DjvuException('Truncated DjVu TXTz zone record.');
  }
  final type = raw[start];
  if (type < djvuZoneTypePage || type > djvuZoneTypeCharacter) {
    throw const DjvuException('DjVu TXTz zone record has an invalid zone type.');
  }
  var x = (raw[start + 1] << 8) | raw[start + 2];
  var y = (raw[start + 3] << 8) | raw[start + 4];
  final width = ((raw[start + 5] << 8) | raw[start + 6]) - _coordinateBias;
  final height = ((raw[start + 7] << 8) | raw[start + 8]) - _coordinateBias;
  var textStart = ((raw[start + 9] << 8) | raw[start + 10]) - _coordinateBias;
  final textLength = (raw[start + 11] << 16) | (raw[start + 12] << 8) | raw[start + 13];
  final childCount = (raw[start + 14] << 16) | (raw[start + 15] << 8) | raw[start + 16];
  x -= _coordinateBias;
  y -= _coordinateBias;

  // Delta accumulation follows the reference decoder: page, paragraph and
  // line zones stack downward from the previous sibling's bottom edge,
  // column, word and character zones continue to its right, and a first
  // child starts relative to its parent.
  if (prev != null) {
    if (type == djvuZoneTypePage || type == djvuZoneTypeParagraph || type == djvuZoneTypeLine) {
      x += prev.xmin;
      y = prev.ymin - (y + height);
    } else {
      x += prev.xmax;
      y += prev.ymin;
    }
    textStart += prev.utf8Start + prev.utf8Length;
  } else if (parent != null) {
    x += parent.xmin;
    y = parent.ymax - (y + height);
    textStart += parent.utf8Start;
  }
  if (width <= 0 || height <= 0) {
    throw const DjvuException('DjVu TXTz zone record has an empty rectangle.');
  }
  if (textStart < 0 || textStart + textLength > index.byteLength) {
    throw const DjvuException('DjVu TXTz zone text range exceeds the page text.');
  }
  final utf16Start = index.utf16OffsetOf(textStart);
  final utf16End = index.utf16OffsetOf(textStart + textLength);
  final frame = _ZoneFrame(
    xmin: x,
    ymax: y + height,
    utf8Start: textStart,
    utf8Length: textLength,
    type: type,
  );

  var next = start + _zoneRecordBytes;
  final children = <DjvuTextZone>[];
  DjvuTextZone? lastChild;
  for (var i = 0; i < childCount; i++) {
    final child = _decodeZone(
      raw,
      next,
      budget,
      index,
      depth: depth + 1,
      prev: lastChild,
      parent: frame,
    );
    children.add(child.zone);
    lastChild = child.zone;
    next = child.nextRecord;
  }

  final zone = DjvuTextZone._(
    type: type,
    xmin: x,
    ymin: y,
    xmax: x + width,
    ymax: y + height,
    utf8Start: textStart,
    utf8Length: textLength,
    utf16Start: utf16Start,
    utf16End: utf16End,
    children: children,
  );

  return _DecodedRecord(zone, next, frame);
}

/// Maps stored UTF-8 byte offsets onto the rendered text's UTF-16 offsets.
///
/// Most zone text is ASCII, where bytes and code units agree one to one.
/// The index records only the exceptional code points — multi-byte UTF-8
/// sequences, and the NUL separators the renderer expands to two code
/// units — so lookups are a binary search over a usually tiny list, and a
/// zone offset landing inside a multi-byte sequence is corrupt input
/// instead of a silent mis-slice.
class _Utf8ByteIndex {
  _Utf8ByteIndex({required String stored, required this.byteLength}) {
    var byteOffset = 0;
    var utf16Offset = 0;
    var unit = 0;
    while (unit < stored.length) {
      final code = stored.codeUnitAt(unit);
      int codePoint;
      int utf16Advance;
      if (code >= 0xD800 && code <= 0xDBFF && unit + 1 < stored.length) {
        final low = stored.codeUnitAt(unit + 1);
        codePoint = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
        utf16Advance = 2;
      } else {
        codePoint = code;
        utf16Advance = 1;
      }
      final byteLengthOfPoint = codePoint < 0x80
          ? 1
          : codePoint < 0x800
          ? 2
          : codePoint < 0x10000
          ? 3
          : 4;
      if (byteLengthOfPoint > 1 || code == 0x00) {
        _entries.add(
          _ByteEntry(
            byteStart: byteOffset,
            utf16Start: utf16Offset,
            byteLength: byteLengthOfPoint,
            utf16Length: code == 0x00 ? 2 : utf16Advance,
          ),
        );
      }
      byteOffset += byteLengthOfPoint;
      utf16Offset += code == 0x00 ? 2 : utf16Advance;
      unit += utf16Advance;
    }
    if (byteOffset != byteLength) {
      throw const DjvuException('DjVu TXTz text byte length disagrees with its UTF-8 form.');
    }
  }

  /// The stored text's byte length.
  final int byteLength;
  final List<_ByteEntry> _entries = <_ByteEntry>[];

  /// The UTF-16 offset of [byteOffset] in the rendered text; a
  /// [DjvuException] reports offsets that land inside a multi-byte
  /// sequence.
  int utf16OffsetOf(int byteOffset) {
    if (byteOffset < 0 || byteOffset > byteLength) {
      throw const DjvuException('DjVu TXTz zone text range exceeds the page text.');
    }
    if (_entries.isEmpty || byteOffset < _entries.first.byteStart) {
      return byteOffset;
    }
    var low = 0;
    var high = _entries.length - 1;
    var pivot = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (_entries[mid].byteStart <= byteOffset) {
        pivot = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    final entry = _entries[pivot];
    if (byteOffset == entry.byteStart) return entry.utf16Start;
    if (byteOffset < entry.byteStart + entry.byteLength) {
      throw const DjvuException('DjVu TXTz zone splits a multi-byte character.');
    }

    return entry.utf16Start + entry.utf16Length + (byteOffset - entry.byteStart - entry.byteLength);
  }
}

class _ByteEntry {
  const _ByteEntry({
    required this.byteStart,
    required this.utf16Start,
    required this.byteLength,
    required this.utf16Length,
  });

  final int byteStart;
  final int utf16Start;
  final int byteLength;
  final int utf16Length;
}
