import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../codec/mobi_binary.dart';
import '../exceptions/exceptions.dart';
import '../header/mobi_header.dart';
import '../header/pdb_header.dart';
import '../index/indx_reader.dart';
import '../index/ncx_reader.dart';

/// KF8 index interpretation and rebuilt skeleton/fragment structure.
final class Mobi8Structure {
  Mobi8Structure._({
    required this.pdb,
    required this.header,
    required this.textOffset,
    required this.rawText,
  });

  /// Reads the KF8 indices and assembles every XHTML skeleton.
  factory Mobi8Structure.read({
    required final PdbRecordAccess pdb,
    required final MobiHeader header,
    required final int textOffset,
    required final Uint8List rawText,
  }) {
    final structure = Mobi8Structure._(
      pdb: pdb,
      header: header,
      textOffset: textOffset,
      rawText: rawText,
    );
    structure
      .._readIndices()
      .._buildParts();

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

  final Map<int, int> _divCounts = <int, int>{};
  final List<_Mobi8Element> _elements = <_Mobi8Element>[];
  final List<(int, int)> _flowTable = <(int, int)>[];
  final Set<String> _linkedAids = <String>{};
  final List<Uint8List> _partBytes = <Uint8List>[];
  final List<Mobi8Part> _parts = <Mobi8Part>[];

  int get _kf8RecordCount => pdb.count - textOffset + 1;

  /// FDST slices for flow zero and its CSS/SVG companions.
  List<(int, int)> get flowTable => _flowTable;

  /// Rebuilt XHTML skeleton bytes in file order.
  List<Uint8List> get partBytes => _partBytes;

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

    return asText.replaceAllMapped(_kindlePosFidPattern, (final match) {
      final resolved = _resolveByPosFid(parseBase32(match.group(1)!), parseBase32(match.group(2)!));
      if (resolved == null) return '"#"';
      final (filename, idtag) = resolved;

      return '"$filename${idtag.isEmpty ? '' : '#$idtag'}"';
    });
  }

  /// Removes kindlegen aid/cid attributes while retaining linked aids as ids.
  String removeKindleAids(final String part) {
    var result = _stripAidAttributes(part, _linkedAids);
    if (_containsAsciiIgnoreCase(result, 'data-amznpagebreak')) {
      result = result.replaceAllMapped(
        _amznPageBreakPattern,
        (final match) =>
            '${match.group(1)} style="page-break-after:${match.group(2)}"${match.group(3)}',
      );
    }

    return result;
  }

  /// Stable output name for a KF8 skeleton file number.
  String partName(final int fileNumber) =>
      fileNumber == 0 ? 'index.html' : 'part${fileNumber.toString().padLeft(4, '0')}.html';

  void _buildParts() {
    final flowSlices = _flowTable.isEmpty ? <(int, int)>[(0, rawText.length)] : _flowTable;
    final flows = <Uint8List>[
      for (final (start, end) in flowSlices)
        Uint8List.sublistView(rawText, start, end > rawText.length ? rawText.length : end),
    ];
    // Flow 0 is the XHTML text; the rest are css/svg flows.
    final text = flows.first;

    var divPointer = 0;
    _partBytes.clear();
    for (final part in _parts) {
      var basePtr = part.end;
      var skeleton = Uint8List.sublistView(text, part.start, basePtr);
      final divCount = _divCounts[part.fileNumber] ?? 0;

      for (var i = 0; i < divCount && divPointer < _elements.length; i++) {
        final element = _elements[divPointer];
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

      part.end = basePtr;
      _partBytes.add(skeleton);
    }
  }

  String? _fileInfoAt(final int pos) {
    for (final part in _parts) {
      if (pos >= part.start && pos < part.end) return part.filename;
    }

    return null;
  }

  String _idTagAt(final int pos) {
    for (var partIndex = 0; partIndex < _parts.length; partIndex++) {
      final part = _parts[partIndex];
      if (pos < part.start || pos >= part.end) continue;
      if (partIndex >= _partBytes.length) return '';
      final block = _partBytes[partIndex];
      var npos = pos - part.start;
      final gt = _indexOfByte(block, 0x3E, npos);
      final lt = _indexOfByte(block, 0x3C, npos);
      if (lt == npos || (gt != -1 && (lt == -1 || gt < lt))) npos = gt + 1;
      if (npos > block.length) npos = block.length;

      var end = npos;
      while (end > 0) {
        final pgt = _lastIndexOfByte(block, 0x3E, 0, end);
        if (pgt == -1) break;
        final plt = _lastIndexOfByte(block, 0x3C, 0, pgt);
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

  (IndxTable, Cncx) _readIndex(final int index) =>
      readIndex(_kf8Record, _kf8RecordCount, index, header.codec);

  void _readIndices() {
    if (header.fdstIndex != nullIndex) {
      final record = _kf8Record(header.fdstIndex);
      if (!_hasMagic(record, 'FDST')) {
        throw const MobiException('KF8 does not have a valid FDST record');
      }
      final view = ByteData.sublistView(record);
      final sectionStart = view.getUint32(4);
      final sectionCount = view.getUint32(8);
      for (var i = 0; i < sectionCount; i++) {
        _flowTable.add((
          view.getUint32(sectionStart + i * 8),
          view.getUint32(sectionStart + i * 8 + 4),
        ));
      }
    }

    if (header.skelIndex != nullIndex) {
      final (table, _) = _readIndex(header.skelIndex);
      var fileNumber = 0;
      for (final ident in table.keys) {
        final tagMap = table[ident]!;
        final tag6 = tagMap[6] ?? const <int>[];
        final start = tag6.isNotEmpty ? tag6[0] : 0;
        final skeletonLength = tag6.length > 1 ? tag6[1] : 0;
        _divCounts[fileNumber] = tagMap[1]?.first ?? 0;
        _parts.add(Mobi8Part(fileNumber, partName(fileNumber), start, start + skeletonLength));
        fileNumber++;
      }
    }

    if (header.divIndex != nullIndex) {
      final (table, cncx) = _readIndex(header.divIndex);
      for (final ident in table.keys) {
        final tagMap = table[ident]!;
        final tag6 = tagMap[6] ?? const <int>[];
        _elements.add(
          _Mobi8Element(
            int.tryParse(ident) ?? 0,
            cncx.get(tagMap[2]?.first ?? -1),
            tagMap[3]?.first ?? 0,
            tag6.isNotEmpty ? tag6[0] : 0,
            tag6.length > 1 ? tag6[1] : 0,
          ),
        );
      }
    }
  }

  bool _firstGtBeforeLt(final Uint8List block) {
    final gt = _indexOfByte(block, 0x3E, 0);
    final lt = _indexOfByte(block, 0x3C, 0);
    if (gt == -1 && lt == -1) return false;

    return gt < lt;
  }

  bool _lastGtBeforeLt(final Uint8List block) {
    final gt = _lastIndexOfByte(block, 0x3E, 0, block.length);
    final lt = _lastIndexOfByte(block, 0x3C, 0, block.length);
    if (gt == -1 && lt == -1) return false;

    return gt < lt;
  }

  int? _locateTagByAid(final Uint8List block, final String aid) {
    if (aid.isEmpty) return null;
    var i = 0;
    while (true) {
      final lt = _indexOfByte(block, 0x3C, i);
      if (lt == -1) break;
      final gt = _indexOfByte(block, 0x3E, lt + 1);
      if (gt == -1) break;
      final tag = String.fromCharCodes(block.sublist(lt, gt + 1));
      if (RegExp('\\said\\s*=\\s*["\']${RegExp.escape(aid)}["\']').hasMatch(tag)) return lt;
      i = gt + 1;
    }

    return null;
  }

  (String, String)? _resolveByPosFid(final int fid, final int offset) {
    if (fid < 0 || fid >= _elements.length) return null;
    final pos = _elements[fid].insertPos + offset;
    final filename = _fileInfoAt(pos);
    if (filename == null) return null;

    return (filename, _idTagAt(pos));
  }
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

final class _Mobi8Element {
  const _Mobi8Element(this.insertPos, this.tocText, this.fileNumber, this.startPos, this.length);

  final int insertPos;
  final String? tocText;
  final int fileNumber;
  final int startPos;
  final int length;
}

final RegExp _kindlePosFidPattern = RegExp(
  '''['"]kindle:pos:fid:([0-9A-V]+):off:([0-9A-V]+)[^"']*['"]''',
  caseSensitive: false,
);
final RegExp _amznPageBreakPattern = RegExp(
  r'''(<[^>]*?)\sdata-AmznPageBreak\s*=\s*['"]([^'"]*)['"]([^>]*>)''',
  caseSensitive: false,
);
final RegExp _idAttrPattern = RegExp(r'''\sid\s*=\s*['"]([^'"]+)['"]''');
final RegExp _nameAttrPattern = RegExp(r'''\sname\s*=\s*['"]([^'"]+)['"]''');
final RegExp _aidAttrPattern = RegExp(r'''\said\s*=\s*['"]([^'"]+)['"]''');

bool _hasMagic(final Uint8List data, final String magic) {
  if (data.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (data[i] != magic.codeUnitAt(i)) return false;
  }

  return true;
}

String _stripAidAttributes(final String part, final Set<String> linkedAids) {
  final units = part.codeUnits;
  final length = units.length;
  final buffer = StringBuffer();
  var isChanged = false;
  var i = 0;
  while (i < length) {
    if (units[i] != _lt) {
      var end = i + 1;
      while (end < length && units[end] != _lt) {
        end++;
      }
      buffer.write(part.substring(i, end));
      i = end;
      continue;
    }
    var gt = i + 1;
    while (gt < length && units[gt] != _gt) {
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
  for (var i = from; i + 3 < to; i++) {
    if (!_isMarkupWhitespace(units[i])) continue;
    final c1 = _asciiLowerCase(units[i + 1]);
    if (c1 != _a && c1 != _c) continue;
    if (_asciiLowerCase(units[i + 2]) != _i || _asciiLowerCase(units[i + 3]) != _d) continue;
    var k = i + 4;
    while (k < to && _isMarkupWhitespace(units[k])) {
      k++;
    }
    if (k >= to || units[k] != _equals) continue;
    k++;
    while (k < to && _isMarkupWhitespace(units[k])) {
      k++;
    }
    if (k >= to || (units[k] != _doubleQuote && units[k] != _singleQuote)) continue;
    final valueStart = k + 1;
    var valueEnd = valueStart;
    while (valueEnd < units.length &&
        units[valueEnd] != _doubleQuote &&
        units[valueEnd] != _singleQuote) {
      valueEnd++;
    }
    if (valueEnd < units.length) return (i, valueStart, valueEnd);
  }

  return null;
}

bool _containsAsciiIgnoreCase(final String text, final String lowercaseNeedle) {
  final units = text.codeUnits;
  final needle = lowercaseNeedle.codeUnits;
  final lastStart = units.length - needle.length;
  for (var i = 0; i <= lastStart; i++) {
    var isMatched = true;
    for (var j = 0; j < needle.length; j++) {
      if (_asciiLowerCase(units[i + j]) != needle[j]) {
        isMatched = false;
        break;
      }
    }
    if (isMatched) return true;
  }

  return false;
}

int _asciiLowerCase(final int codeUnit) =>
    codeUnit >= 0x41 && codeUnit <= 0x5A ? codeUnit + 0x20 : codeUnit;

bool _isMarkupWhitespace(final int codeUnit) =>
    codeUnit == 0x20 ||
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

int _indexOfByte(final Uint8List data, final int byte, final int from) {
  for (var i = from < 0 ? 0 : from; i < data.length; i++) {
    if (data[i] == byte) return i;
  }

  return -1;
}

int _lastIndexOfByte(final Uint8List data, final int byte, final int from, final int to) {
  for (var i = to - 1; i >= from; i--) {
    if (data[i] == byte) return i;
  }

  return -1;
}

const int _lt = 0x3C;
const int _gt = 0x3E;
const int _a = 0x61;
const int _c = 0x63;
const int _i = 0x69;
const int _d = 0x64;
const int _equals = 0x3D;
const int _doubleQuote = 0x22;
const int _singleQuote = 0x27;
