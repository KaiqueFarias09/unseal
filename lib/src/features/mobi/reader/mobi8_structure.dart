import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../codec/mobi_base32.dart';
import '../codec/mobi_byte_search.dart';
import '../codec/mobi_text_codec.dart';
import '../exceptions/exceptions.dart';
import '../header/mobi_header.dart';
import '../header/pdb_header.dart';
import '../index/indx_reader.dart';
import '../index/ncx_reader.dart';

/// The `kindle:pos:fid:N:off:M` link form inside rebuilt parts.
final RegExp mobi8PosFidPattern = RegExp(
  '''['"]kindle:pos:fid:([0-9A-V]+):off:([0-9A-V]+)[^"']*['"]''',
  caseSensitive: false,
);

/// The `data-AmznPageBreak` attribute form kindlegen emits.
final RegExp mobi8PageBreakPattern = RegExp(
  r'''(<[^>]*?)\sdata-AmznPageBreak\s*=\s*['"]([^'"]*)['"]([^>]*>)''',
  caseSensitive: false,
);
final RegExp _idAttrPattern = RegExp(r'''\sid\s*=\s*['"]([^'"]+)['"]''');
final RegExp _nameAttrPattern = RegExp(r'''\sname\s*=\s*['"]([^'"]+)['"]''');
final RegExp _aidAttrPattern = RegExp(r'''\said\s*=\s*['"]([^'"]+)['"]''');

/// KF8 index facts read from records alone: the FDST flow table, the
/// skeleton parts with their raw spans, and the division (fragment)
/// elements. Everything the session needs to plan per-part
/// materialization without any text bytes; the eager parse reads the
/// same facts through [Mobi8Structure.read].
final class Mobi8Indexes {
  Mobi8Indexes._({
    required this.flowTable,
    required this.divCounts,
    required this.elements,
    required this.parts,
    required this.partRawEnds,
  });

  /// Reads the KF8 indexes from [pdb] records. Index record positions
  /// are relative to [textOffset] (the KF8 half of joint files).
  factory Mobi8Indexes.read({
    required final PdbRecordAccess pdb,
    required final MobiHeader header,
    required final int textOffset,
  }) {
    final flowTable = <(int, int)>[];
    final divCounts = <int, int>{};
    final elements = <Mobi8DivElement>[];
    final parts = <Mobi8Part>[];

    Uint8List kf8Record(final int index) => pdb.record(textOffset - 1 + index);

    (IndxTable, Cncx) readIndexOf(final int index) {
      return readIndex(kf8Record, pdb.count - textOffset + 1, index, header.codec);
    }

    if (header.fdstIndex != nullIndex) {
      final record = kf8Record(header.fdstIndex);
      if (!hasAsciiAt(record, 'FDST') || record.length < 12) {
        throw const MobiException('KF8 does not have a valid FDST record');
      }

      final view = ByteData.sublistView(record);
      final sectionStart = view.getUint32(4);
      final sectionCount = view.getUint32(8);
      if (sectionStart > record.length || sectionCount > (record.length - sectionStart) ~/ 8) {
        throw const MobiException('KF8 has a truncated FDST table');
      }

      for (var i = 0; i < sectionCount; i++) {
        flowTable.add((
          view.getUint32(sectionStart + i * 8),
          view.getUint32(sectionStart + i * 8 + 4),
        ));
      }
    }
    if (header.skelIndex != nullIndex) {
      final (table, _) = readIndexOf(header.skelIndex);
      var fileNumber = 0;
      for (final ident in table.keys) {
        final tagMap = table[ident]!;
        final tag6 = tagMap[6] ?? const <int>[];
        final start = tag6.isNotEmpty ? tag6[0] : 0;
        final skeletonLength = tag6.length > 1 ? tag6[1] : 0;

        divCounts[fileNumber] = tagMap[1]?.first ?? 0;
        parts.add(Mobi8Part(fileNumber, partName(fileNumber), start, start + skeletonLength));
        fileNumber++;
      }
    }
    if (header.divIndex != nullIndex) {
      final (table, cncx) = readIndexOf(header.divIndex);
      for (final ident in table.keys) {
        final tagMap = table[ident]!;
        final tag6 = tagMap[6] ?? const <int>[];
        elements.add(
          Mobi8DivElement(
            int.tryParse(ident) ?? 0,
            cncx.get(tagMap[2]?.first ?? -1),
            tagMap[3]?.first ?? 0,
            tag6.isNotEmpty ? tag6[0] : 0,
            tag6.length > 1 ? tag6[1] : 0,
          ),
        );
      }
    }

    // Raw spans: a part's rebuilt content covers its skeleton plus the
    // fragment bytes that follow it in the raw stream. The eager
    // `_buildParts` walk reaches the same ends by advancing a pointer;
    // the computation here needs no text bytes.
    var elementCursor = 0;
    final partRawEnds = <int>[];
    for (var i = 0; i < parts.length; i++) {
      final part = parts[i];
      final count = divCounts[part.fileNumber] ?? 0;
      var end = part.end;
      for (var e = 0; e < count && elementCursor < elements.length; e++) {
        end += elements[elementCursor].length;
        elementCursor++;
      }
      partRawEnds.add(end);
    }

    return Mobi8Indexes._(
      flowTable: flowTable,
      divCounts: divCounts,
      elements: elements,
      parts: parts,
      partRawEnds: partRawEnds,
    );
  }

  /// FDST slices for flow zero and its CSS/SVG companions.
  final List<(int, int)> flowTable;

  /// Fragment count per part file number, in part order.
  final Map<int, int> divCounts;

  /// Division elements in index order; parts consume this list
  /// sequentially.
  final List<Mobi8DivElement> elements;

  /// Skeleton parts in file order; `end` still names the skeleton end
  /// (the eager build walk mutates it to the rebuilt end).
  final List<Mobi8Part> parts;

  /// Each part's end in the raw stream once its fragments are counted
  /// — the span `_fileInfoAt`-style position resolution uses.
  final List<int> partRawEnds;

  /// Stable output name for a KF8 skeleton file number.
  static String partName(final int fileNumber) {
    return fileNumber == 0 ? 'index.html' : 'part${fileNumber.toString().padLeft(4, '0')}.html';
  }

  /// The number of elements the parts before [partIndex] consume.
  int elementOffsetFor(final int partIndex) {
    var cursor = 0;
    for (var i = 0; i < partIndex && i < parts.length; i++) {
      cursor += divCounts[parts[i].fileNumber] ?? 0;
    }

    return cursor;
  }
}

/// KF8 index interpretation and rebuilt skeleton/fragment structure.
final class Mobi8Structure {
  Mobi8Structure._({
    required this.pdb,
    required this.header,
    required this.textOffset,
    required this.rawText,
    required this.indexes,
  });

  /// Reads the KF8 indices and assembles every XHTML skeleton.
  factory Mobi8Structure.read({
    required final PdbRecordAccess pdb,
    required final MobiHeader header,
    required final int textOffset,
    required final Uint8List rawText,
  }) {
    final indexes = Mobi8Indexes.read(pdb: pdb, header: header, textOffset: textOffset);
    final structure = Mobi8Structure._(
      pdb: pdb,
      header: header,
      textOffset: textOffset,
      rawText: rawText,
      indexes: indexes,
    );
    structure._buildParts();

    return structure;
  }

  /// PDB record access used by KF8 indices and navigation.
  final PdbRecordAccess pdb;

  /// KF8 header holding index locations and text codec.
  final MobiHeader header;

  /// First text record index of the KF8 half.
  final int textOffset;

  /// Decompressed KF8 text containing skeletons, fragments, and flows.
  final Uint8List rawText;

  /// The record-level index facts: flows, parts, fragments.
  final Mobi8Indexes indexes;

  final Set<String> _linkedAids = <String>{};
  final List<Uint8List> _partBytes = <Uint8List>[];

  int get _kf8RecordCount => pdb.count - textOffset + 1;

  /// FDST slices for flow zero and its CSS/SVG companions.
  List<(int, int)> get flowTable => indexes.flowTable;

  /// Rebuilt XHTML skeleton bytes in file order.
  List<Uint8List> get partBytes => _partBytes;

  /// The link-resolutions and TOC lookups collected these aid values;
  /// they survive `removeKindleAids` as `id` attributes.
  Set<String> get linkedAids => _linkedAids;

  /// Builds navigation and resolves NCX positions into rebuilt part links.
  Navigation buildToc() {
    final entries = readNcx(_kf8Record, _kf8RecordCount, header.ncxIndex, header.codec);
    for (final entry in entries) {
      final posFid = entry.posFid;
      if (posFid != null && posFid.length >= 2) {
        final resolved = _resolveByPosFid(posFid[0], posFid[1]);
        if (resolved != null) {
          entry.href = resolved.$1;
          entry.idtag = resolved.$2;
          continue;
        }
      }
      if (entry.pos >= 0) {
        final filename = _fileInfoAt(entry.pos);
        if (filename != null) {
          entry.href = filename;
          entry.idtag = _idTagAt(entry.pos);
        }
      }
    }

    return buildNavigation(entries);
  }

  /// Resolves `kindle:pos:fid` links inside a rebuilt part.
  String updateInternalLinks(final Uint8List part) {
    final asText = decodeBytes(part, header.codec);

    return asText.replaceAllMapped(mobi8PosFidPattern, (final match) {
      final resolved = _resolveByPosFid(parseBase32(match.group(1)!), parseBase32(match.group(2)!));
      if (resolved == null) return '"#"';

      final (filename, idtag) = resolved;

      return '"$filename${idtag.isEmpty ? '' : '#$idtag'}"';
    });
  }

  /// Link resolution exposed for the shared markup finalizer.
  (String, String)? resolvePosFid(final int fid, final int offset) => _resolveByPosFid(fid, offset);

  /// Removes kindlegen aid/cid attributes while retaining linked aids as ids.
  String removeKindleAids(final String part) {
    var result = stripMobi8AidAttributes(part, _linkedAids);
    if (containsAsciiIgnoreCase(result, 'data-amznpagebreak')) {
      result = result.replaceAllMapped(mobi8PageBreakPattern, (final match) {
        return '${match.group(1)} style="page-break-after:${match.group(2)}"${match.group(3)}';
      });
    }

    return result;
  }

  /// Stable output name for a KF8 skeleton file number.
  String partName(final int fileNumber) => Mobi8Indexes.partName(fileNumber);

  void _buildParts() {
    final flowSlices = _flowSlices();
    final flows = <Uint8List>[
      for (final (start, end) in flowSlices)
        Uint8List.sublistView(rawText, start, end > rawText.length ? rawText.length : end),
    ];
    // Flow 0 is the XHTML text; the rest are css/svg flows.
    final text = flows.first;

    var elementCursor = 0;
    _partBytes.clear();
    for (var partIndex = 0; partIndex < indexes.parts.length; partIndex++) {
      final part = indexes.parts[partIndex];
      final divCount = indexes.divCounts[part.fileNumber] ?? 0;
      final built = assembleMobi8Part(
        part: part,
        elements: indexes.elements,
        elementOffset: elementCursor,
        divCount: divCount,
        text: text,
      );
      elementCursor += divCount;
      part.end = _partEndAfterBuild(part, elementCursor - divCount, divCount);
      _partBytes.add(built);
    }
  }

  int _partEndAfterBuild(final Mobi8Part part, final int elementOffset, final int divCount) {
    var end = part.end;
    for (var e = 0; e < divCount && elementOffset + e < indexes.elements.length; e++) {
      end += indexes.elements[elementOffset + e].length;
    }

    return end;
  }

  List<(int, int)> _flowSlices() {
    return indexes.flowTable.isEmpty ? <(int, int)>[(0, rawText.length)] : indexes.flowTable;
  }

  String? _fileInfoAt(final int pos) {
    for (var i = 0; i < indexes.parts.length; i++) {
      final part = indexes.parts[i];
      if (pos >= part.start && pos < part.end) return part.filename;
    }

    return null;
  }

  String _idTagAt(final int pos) {
    for (var partIndex = 0; partIndex < indexes.parts.length; partIndex++) {
      final part = indexes.parts[partIndex];
      if (pos < part.start || pos >= part.end) continue;
      if (partIndex >= _partBytes.length) return '';

      final block = _partBytes[partIndex];
      var npos = pos - part.start;
      final gt = indexOfByte(block, 0x3E, npos);
      final lt = indexOfByte(block, 0x3C, npos);
      if (lt == npos || (gt != -1 && (lt == -1 || gt < lt))) npos = gt + 1;
      if (npos > block.length) npos = block.length;

      var end = npos;
      while (end > 0) {
        final pgt = lastIndexOfByte(block, 0x3E, 0, end);
        if (pgt == -1) break;

        final plt = lastIndexOfByte(block, 0x3C, 0, pgt);
        if (plt == -1) break;

        final tag = String.fromCharCodes(block.sublist(plt, pgt + 1));
        final id = _idAttrPattern.firstMatch(tag);
        if (id != null) return id.group(1)!;

        final name = _nameAttrPattern.firstMatch(tag);
        if (name != null) return name.group(1)!;

        final aid = _aidAttrPattern.firstMatch(tag);
        if (aid != null) {
          _linkedAids.add(aid.group(1)!);

          return aid.group(1)!;
        }

        end = plt;
      }

      return '';
    }

    return '';
  }

  Uint8List _kf8Record(final int index) => pdb.record(textOffset - 1 + index);

  (String, String)? _resolveByPosFid(final int fid, final int offset) {
    if (fid < 0 || fid >= indexes.elements.length) return null;

    final pos = indexes.elements[fid].insertPos + offset;
    final filename = _fileInfoAt(pos);
    if (filename == null) return null;

    return (filename, _idTagAt(pos));
  }
}

bool _firstGtBeforeLt(final Uint8List block) {
  final gt = indexOfByte(block, 0x3E, 0);
  final lt = indexOfByte(block, 0x3C, 0);
  if (gt == -1 && lt == -1) return false;

  return gt != -1 && (lt == -1 || gt < lt);
}

bool _lastGtBeforeLt(final Uint8List block) {
  final gt = lastIndexOfByte(block, 0x3E, 0, block.length);
  final lt = lastIndexOfByte(block, 0x3C, 0, block.length);
  if (gt == -1 && lt == -1) return false;

  return gt < lt;
}

int? _locateTagByAid(final Uint8List block, final String aid) {
  if (aid.isEmpty) return null;

  var i = 0;
  while (true) {
    final lt = indexOfByte(block, 0x3C, i);
    if (lt == -1) break;

    final gt = indexOfByte(block, 0x3E, lt + 1);
    if (gt == -1) break;

    final tag = String.fromCharCodes(block.sublist(lt, gt + 1));
    if (RegExp('\\said\\s*=\\s*["\']${RegExp.escape(aid)}["\']').hasMatch(tag)) return lt;

    i = gt + 1;
  }

  return null;
}

/// Assembles one rebuilt KF8 part: the skeleton span with its fragment
/// bytes inserted at their positions, including the kindlegen
/// tag-relocation repair. Shared by the eager whole-stream build and
/// the session's per-part build, so both produce identical bytes.
Uint8List assembleMobi8Part({
  required final Mobi8Part part,
  required final List<Mobi8DivElement> elements,
  required final int elementOffset,
  required final int divCount,
  required final Uint8List text,
}) {
  var basePtr = part.end;
  var skeleton = Uint8List.sublistView(text, part.start, basePtr);
  var divPointer = elementOffset;
  for (var i = 0; i < divCount && divPointer < elements.length; i++) {
    final element = elements[divPointer];
    var insertPos = element.insertPos - part.start;
    final divEnd = basePtr + element.length;
    final div = Uint8List.sublistView(text, basePtr, divEnd);

    final headEnd = insertPos < skeleton.length ? insertPos : skeleton.length;
    final head = Uint8List.sublistView(skeleton, 0, headEnd);
    final tail = insertPos < skeleton.length
        ? Uint8List.sublistView(skeleton, insertPos)
        : Uint8List(0);
    final brokenTail = _firstGtBeforeLt(tail);
    final brokenHead = _lastGtBeforeLt(head);
    if (brokenTail || brokenHead) {
      final aid = i == 0 && element.tocText != null && element.tocText!.length > 14
          ? element.tocText!.substring(12, element.tocText!.length - 2)
          : '';
      final tagStart = _locateTagByAid(skeleton, aid);
      if (tagStart != null) insertPos = tagStart + 1 + element.startPos - part.start;
    }

    final insert = insertPos.clamp(0, skeleton.length);
    final merged = BytesBuilder(copy: false)
      ..add(skeleton.sublist(0, insert))
      ..add(div)
      ..add(skeleton.sublist(insert));

    skeleton = merged.takeBytes();
    basePtr = divEnd;
    divPointer++;
  }

  return skeleton;
}

/// A rebuilt KF8 XHTML file: name plus its span in the raw text.
class Mobi8Part {
  /// Creates a KF8 part with its source file number, name, and text span.
  Mobi8Part(this.fileNumber, this.filename, this.start, this.end);

  /// The zero-based file number in the KF8 skeleton.
  final int fileNumber;

  /// The output file name.
  final String filename;

  /// The inclusive raw-text start offset.
  final int start;

  /// The exclusive raw-text end offset.
  int end;
}

/// One KF8 division (fragment) element from the DIV index: the raw
/// stream position its bytes insert at, the fragment length, and the
/// CNCX navigation text. Public because the session's per-part
/// assembler consumes the same list.
final class Mobi8DivElement {
  /// Creates a division element from its index fields.
  const Mobi8DivElement(this.insertPos, this.tocText, this.fileNumber, this.startPos, this.length);

  /// Absolute raw-stream position the fragment inserts at.
  final int insertPos;

  /// CNCX navigation text carried by the division.
  final String? tocText;

  /// File number the division declares.
  final int fileNumber;

  /// In-part start offset declared by the index.
  final int startPos;

  /// Fragment byte length in the raw stream.
  final int length;
}

/// Removes kindlegen `aid`/`cid` attributes from one part, retaining
/// the ones in [linkedAids] as `id` attributes. Shared with the
/// progressive session's markup finalizer.
String stripMobi8AidAttributes(final String part, final Set<String> linkedAids) {
  const lt = 0x3C;
  const gtByte = 0x3E;
  final units = part.codeUnits;
  final length = units.length;
  final buffer = StringBuffer();
  var isChanged = false;
  var i = 0;
  while (i < length) {
    if (units[i] != lt) {
      var end = i + 1;
      while (end < length && units[end] != lt) {
        end++;
      }
      buffer.write(part.substring(i, end));
      i = end;
      continue;
    }

    var gt = i + 1;
    while (gt < length && units[gt] != gtByte) {
      gt++;
    }

    if (gt == length) {
      buffer.write(part.substring(i));
      break;
    }

    final attr = _findAidAttribute(part, units, i + 1, gt);
    if (attr == null) {
      buffer.write(part.substring(i, gt + 1));
    } else {
      isChanged = true;
      final (separator, valueStart, valueEnd) = attr;
      final aid = part.substring(valueStart, valueEnd);
      buffer.write(part.substring(i, separator));
      if (linkedAids.contains(aid)) buffer.write(' id="$aid"');
      buffer.write(part.substring(valueEnd + 1, gt + 1));
    }
    i = gt + 1;
  }

  return isChanged ? buffer.toString() : part;
}

(int, int, int)? _findAidAttribute(
  final String part,
  final List<int> units,
  final int from,
  final int to,
) {
  const aidFirstLetter = 0x61;
  const cidFirstLetter = 0x63;
  const idSecondLetter = 0x69;
  const idThirdLetter = 0x64;
  const equals = 0x3D;
  const doubleQuote = 0x22;
  const singleQuote = 0x27;
  for (var i = from; i + 3 < to; i++) {
    if (!_isMarkupWhitespace(units[i])) continue;

    final firstLetter = asciiLowerCase(units[i + 1]);
    if (firstLetter != aidFirstLetter && firstLetter != cidFirstLetter) continue;
    if (asciiLowerCase(units[i + 2]) != idSecondLetter ||
        asciiLowerCase(units[i + 3]) != idThirdLetter) {
      continue;
    }

    var k = i + 4;
    while (k < to && _isMarkupWhitespace(units[k])) {
      k++;
    }

    if (k >= to || units[k] != equals) continue;

    k++;
    while (k < to && _isMarkupWhitespace(units[k])) {
      k++;
    }

    if (k >= to || (units[k] != doubleQuote && units[k] != singleQuote)) continue;

    final quote = units[k];
    final valueStart = k + 1;
    var valueEnd = valueStart;
    while (valueEnd < to && units[valueEnd] != quote) {
      valueEnd++;
    }

    if (valueEnd < to) return (i, valueStart, valueEnd);
  }

  return null;
}

bool _isMarkupWhitespace(final int codeUnit) {
  return codeUnit == 0x20 ||
      (codeUnit >= 0x09 && codeUnit <= 0x0D) ||
      codeUnit == 0xA0 ||
      codeUnit == 0x1680 ||
      (codeUnit >= 0x2000 && codeUnit <= 0x200A) ||
      codeUnit == 0x2028 ||
      codeUnit == 0x2029 ||
      codeUnit == 0x202F ||
      codeUnit == 0x205F ||
      codeUnit == 0x3000 ||
      codeUnit == 0xFEFF;
}
