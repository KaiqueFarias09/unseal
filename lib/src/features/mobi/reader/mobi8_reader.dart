import "dart:typed_data";

import 'package:e_livre/src/features/mobi/exceptions/exceptions.dart';
import 'package:e_livre/src/features/mobi/header/mobi_header.dart';
import 'package:e_livre/src/features/mobi/header/pdb_header.dart';
import 'package:e_livre/src/features/mobi/index/indx_reader.dart';
import 'package:e_livre/src/features/mobi/index/ncx_reader.dart';
import 'package:e_livre/src/features/mobi/reader/mobi_text.dart';
import 'package:e_livre/src/features/mobi/utils/containers.dart';
import 'package:e_livre/src/features/mobi/utils/decint.dart';
import 'package:e_livre/src/features/mobi/utils/fonts.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';

import 'package:e_livre/src/foundation/utils/image_sniffer.dart';

/// Assembles KF8 (AZW3) books from raw records.
///
/// Ports the Kindle KF8 structure: FDST flow boundaries, skeleton /
/// div reassembly of XHTML files, resource extraction (raw and
/// CONT/CRES wrapped images, FONT records) and `kindle:` link
/// resolution.
class Mobi8Reader {
  /// Creates a reader over [pdb] records with the KF8 [header].
  ///
  /// [textOffset] is the first text record of the KF8 half and
  /// [resourceOffsets] are the (start, end) record ranges holding
  /// resources (two ranges for joint MOBI 6 + KF8 files).
  Mobi8Reader({
    required this.pdb,
    required this.header,
    required this.textOffset,
    required this.resourceOffsets,
    this.huffOffsetOverride,
  });

  final Map<int, int> _divCounts = <int, int>{};
  final List<_Elem> _elems = <_Elem>[];
  final List<_Flow> _flows = <_Flow>[];
  List<(int, int)> _flowTable = const <(int, int)>[];
  final List<BinaryFile> _fonts = <BinaryFile>[];
  final List<BinaryFile> _images = <BinaryFile>[];
  final Set<String> _linkedAids = <String>{};
  final List<Uint8List> _partBytes = <Uint8List>[];
  final List<Mobi8Part> _parts = <Mobi8Part>[];
  late Uint8List _rawText;
  final List<String?> _resourceMap = <String?>[];

  /// The KF8 MOBI header.
  final MobiHeader header;

  /// PDB record access.
  final PdbRecordAccess pdb;

  /// Resource record ranges.
  final List<(int, int)> resourceOffsets;

  /// First text record index of the KF8 half.
  final int textOffset;

  /// Rebases the HUFF section for joint MOBI 6 + KF8 files.
  final int? huffOffsetOverride;

  int get _kf8RecordCount => pdb.count - textOffset + 1;

  /// Runs the full assembly.
  Mobi8Assembly assemble() {
    _rawText = extractMobiText(
      recordAt: pdb.record,
      recordCount: pdb.count,
      textOffset: textOffset,
      header: header,
      huffOffsetOverride: huffOffsetOverride,
    );

    _readIndices();
    _buildParts();
    _classifyFlows();
    _extractResources();

    return _expandMarkup();
  }

  void _buildParts() {
    final flowSlices = _flowTable.isEmpty ? <(int, int)>[(0, _rawText.length)] : _flowTable;
    final flows = <Uint8List>[
      for (final (start, end) in flowSlices)
        Uint8List.sublistView(_rawText, start, end > _rawText.length ? _rawText.length : end),
    ];
    // Flow 0 is the XHTML text; the rest are css/svg flows.
    final text = flows.first;

    var divPointer = 0;
    _partBytes.clear();
    for (final part in _parts) {
      var basePtr = part.end;
      var skeleton = Uint8List.sublistView(text, part.start, basePtr);
      final divCount = _divCounts[part.fileNumber] ?? 0;

      for (var i = 0; i < divCount && divPointer < _elems.length; i++) {
        final elem = _elems[divPointer];
        var insertPos = elem.insertPos - part.start;
        final divEnd = basePtr + elem.length;
        final div = Uint8List.sublistView(text, basePtr, divEnd);

        final headEnd = insertPos < skeleton.length ? insertPos : skeleton.length;
        final head = Uint8List.sublistView(skeleton, 0, headEnd);
        final tail = insertPos < skeleton.length
            ? Uint8List.sublistView(skeleton, insertPos)
            : Uint8List(0);
        final brokenTail = _firstGtBeforeLt(tail);
        final brokenHead = _lastGtBeforeLt(head);
        if (brokenTail || brokenHead) {
          final aid = i == 0 && elem.tocText != null && elem.tocText!.length > 14
              ? elem.tocText!.substring(12, elem.tocText!.length - 2)
              : '';
          final tagStart = _locateTagByAid(skeleton, aid);
          if (tagStart != null) {
            insertPos = tagStart + 1 + elem.startPos - part.start;
          }
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

  Navigation _buildToc() {
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

  void _classifyFlows() {
    final flowSlices = _flowTable.isEmpty ? <(int, int)>[(0, _rawText.length)] : _flowTable;
    for (var j = 1; j < flowSlices.length; j++) {
      final (start, end) = flowSlices[j];
      final slice = Uint8List.sublistView(
        _rawText,
        start,
        end > _rawText.length ? _rawText.length : end,
      );
      final asText = String.fromCharCodes(slice);
      final number = j.toString().padLeft(4, '0');

      final svgMatch = _svgOpenTagPattern.firstMatch(asText);
      if (svgMatch != null) {
        final stripped = asText.substring(svgMatch.start);
        final hasImage = _svgImagePattern.hasMatch(stripped);
        if (hasImage) {
          _flows.add(_Flow(j, 'svg', null, stripped));
        } else {
          _flows.add(_Flow(j, 'svg', 'svg$number.svg', stripped));
        }
      } else if (asText.contains('[CDATA[')) {
        _flows.add(_Flow(j, 'css', null, '<style type="text/css">\n$asText\n</style>\n'));
      } else {
        _flows.add(_Flow(j, 'css', 'flow$number.css', asText));
      }
    }
  }

  String? _embedHref(final String base32Number) {
    final index = parseBase32(base32Number);
    if (index < 1 || index > _resourceMap.length) return null;

    return _resourceMap[index - 1];
  }

  Mobi8Assembly _expandMarkup() {
    // 1. Resolve internal pos:fid links, then decode to strings.
    var parts = <String>[for (final bytes in _partBytes) _updateInternalLinks(bytes)];

    // 2. Strip kindlegen aid/cid attributes (keeping linked ones as id).
    parts = parts.map(_removeKindleAids).toList();

    // 3. Resolve references inside the flows themselves.
    for (final flow in _flows) {
      flow.content = _updateFlowLinks(flow.content);
    }

    // 4. Inline flows and image references into the markup.
    for (var i = 0; i < parts.length; i++) {
      parts[i] = _insertFlows(parts[i]);
      parts[i] = _insertImages(parts[i]);
      parts[i] = _normalizePart(parts[i]);
    }

    final html = <TextFile>[];
    for (var i = 0; i < parts.length; i++) {
      final name = _partName(i);
      html.add(TextFile(name: name, type: 'html', path: name, content: parts[i]));
    }

    final css = <TextFile>[];
    final svgImages = <BinaryFile>[];
    for (final flow in _flows) {
      if (flow.filename == null) continue;
      if (flow.kind == 'css') {
        css.add(
          TextFile(name: flow.filename!, type: 'css', path: flow.filename!, content: flow.content),
        );
      } else {
        svgImages.add(
          BinaryFile(
            content: Uint8List.fromList(flow.content.codeUnits),
            name: flow.filename!,
            type: 'svg',
            path: flow.filename!,
          ),
        );
      }
    }

    String? coverName;
    final coverOffset = header.exth?.coverOffset;
    if (coverOffset != null && coverOffset < _resourceMap.length) {
      coverName = _resourceMap[coverOffset];
    }

    return Mobi8Assembly(
      html,
      css,
      [..._images, ...svgImages],
      List<BinaryFile>.from(_fonts),
      _buildToc(),
      _resourceMap,
      coverName,
    );
  }

  void _extractResources() {
    MobiContainer? container;
    for (final (start, end) in resourceOffsets) {
      for (var i = start; i < end && i < pdb.count; i++) {
        final fnameIdx = i - start + 1;
        final data = pdb.record(i);
        final type = data.length >= 4 ? String.fromCharCodes(data.sublist(0, 4)) : '';
        String? href;

        if (const {
              'FLIS',
              'FCIS',
              'SRCS',
              'BOUN',
              'FDST',
              'DATP',
              'AUDI',
              'VIDE',
              'RESC',
              'CMET',
              'PAGE',
            }.contains(type) ||
            _isUnknownMarker(data)) {
          // Ignored record kinds.
        } else if (type == 'FONT') {
          final font = decodeFontRecord(data);
          final name = 'font${fnameIdx.toString().padLeft(5, '0')}.${font.extension}';
          href = name;
          _fonts.add(BinaryFile(content: font.data, name: name, type: font.extension, path: name));
        } else if (type == 'CONT') {
          container = _hasMagic(data, 'CONTBOUNDARY') ? null : MobiContainer(data);
        } else if (type == 'CRES') {
          if (container != null) {
            final image = container.loadImage(data);
            if (image != null) {
              final sniffed = sniffImageType(image)!;
              final name =
                  'image${container.resourceIndex.toString().padLeft(5, '0')}.${sniffed.fileExtension}';
              href = name;
              _images.add(
                BinaryFile(content: image, name: name, type: sniffed.fileExtension, path: name),
              );
            }
          }
        } else if (_isPlaceholder(data) && container != null) {
          container.resourceIndex += 1;
        } else if (container == null) {
          final sniffed = sniffImageType(data);
          if (sniffed != null) {
            final name = 'image${fnameIdx.toString().padLeft(5, '0')}.${sniffed.fileExtension}';
            href = name;
            _images.add(
              BinaryFile(content: data, name: name, type: sniffed.fileExtension, path: name),
            );
          }
        }

        _resourceMap.add(href);
      }
    }
  }

  // --- link resolution helpers ---

  String? _fileInfoAt(final int pos) {
    for (final part in _parts) {
      if (pos >= part.start && pos < part.end) return part.filename;
    }

    return null;
  }

  bool _firstGtBeforeLt(final Uint8List block) {
    final gt = _indexOfByte(block, 0x3E, 0);
    final lt = _indexOfByte(block, 0x3C, 0);
    // Mirrors Python: find returns -1 when absent, so -1 < anything.
    if (gt == -1 && lt == -1) return false;

    return gt < lt;
  }

  _Flow? _flowByNumber(final int number) {
    for (final flow in _flows) {
      if (flow.number == number) return flow;
    }

    return null;
  }

  String _idTagAt(final int pos) {
    for (var partIndex = 0; partIndex < _parts.length; partIndex++) {
      final part = _parts[partIndex];
      if (pos < part.start || pos >= part.end) {
        continue;
      }
      if (partIndex >= _partBytes.length) return '';
      final block = _partBytes[partIndex];
      var npos = pos - part.start;
      final gt = _indexOfByte(block, 0x3E, npos);
      final lt = _indexOfByte(block, 0x3C, npos);
      if (lt == npos || (gt != -1 && (lt == -1 || gt < lt))) {
        npos = gt + 1;
      }
      if (npos > block.length) {
        npos = block.length;
      }

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

  String _insertFlows(final String part) {
    if (!_containsAsciiIgnoreCase(part, 'kindle:flow')) return part;

    return part.replaceAllMapped(_anyTagPattern, (final tagMatch) {
      final tag = tagMatch.group(1)!;
      final match = _flowRefPattern.firstMatch(tag);
      if (match == null) return tag;

      final target = _flowByNumber(parseBase32(match.group(1)!));
      if (target == null) return '';
      if (target.filename == null) return target.content;

      return tag.replaceFirst(_flowRefPattern, '"${target.filename}"');
    });
  }

  String _insertImages(final String part) {
    if (!_containsAsciiIgnoreCase(part, 'kindle:embed')) return part;
    var result = part.replaceAllMapped(_imgTagPattern, (final tagMatch) {
      final tag = tagMatch.group(1)!;
      return tag.replaceFirstMapped(_kindleEmbedWrappedPattern, (final match) {
        final href = _embedHref(match.group(1)!);
        return href == null ? match.group(0)! : '"$href"';
      });
    });

    result = result.replaceAllMapped(_styledTagPattern, (final tagMatch) {
      final tag = tagMatch.group(1)!;
      if (!tag.contains('kindle:embed')) return tag;

      return tag.replaceAllMapped(_kindleEmbedWrappedPattern, (final match) {
        final href = _embedHref(match.group(1)!);
        return href == null ? match.group(0)! : '"$href"';
      });
    });

    return result;
  }

  Uint8List _kf8Record(final int index) => pdb.record(textOffset - 1 + index);

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

  String _normalizePart(final String part) {
    var result = part.replaceAll(_xmlDeclarationPattern, '');
    result = result.replaceAll('\uFEFF', '');
    if (!result.contains('charset')) {
      result = result.replaceFirst('<head>', '<head><meta charset="utf-8"/>');
    }

    return result;
  }

  String _partName(final int fileNumber) =>
      fileNumber == 0 ? 'index.html' : 'part${fileNumber.toString().padLeft(4, '0')}.html';

  (IndxTable, Cncx) _readIndex(final int index) {
    return readIndex(_kf8Record, _kf8RecordCount, index, header.codec);
  }

  void _readIndices() {
    if (header.fdstIndex != nullIndex) {
      final record = _kf8Record(header.fdstIndex);
      if (!_hasMagic(record, 'FDST')) {
        throw const MobiException('KF8 does not have a valid FDST record');
      }
      final view = ByteData.sublistView(record);
      final sectionStart = view.getUint32(4);
      final sectionCount = view.getUint32(8);
      final table = <(int, int)>[];
      for (var i = 0; i < sectionCount; i++) {
        table.add((view.getUint32(sectionStart + i * 8), view.getUint32(sectionStart + i * 8 + 4)));
      }
      _flowTable = table;
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
        _parts.add(Mobi8Part(fileNumber, _partName(fileNumber), start, start + skeletonLength));
        fileNumber++;
      }
    }

    if (header.divIndex != nullIndex) {
      final (table, cncx) = _readIndex(header.divIndex);
      for (final ident in table.keys) {
        final tagMap = table[ident]!;
        final tag6 = tagMap[6] ?? const <int>[];
        _elems.add(
          _Elem(
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

  String _removeKindleAids(final String part) {
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

  (String, String)? _resolveByPosFid(final int fid, final int offset) {
    if (fid < 0 || fid >= _elems.length) return null;
    final pos = _elems[fid].insertPos + offset;
    final filename = _fileInfoAt(pos);
    if (filename == null) return null;

    return (filename, _idTagAt(pos));
  }

  String _updateFlowLinks(final String content) {
    var result = content.replaceAllMapped(_flowImageTagPattern, (final tagMatch) {
      final tag = tagMatch.group(1)!;
      return tag.replaceFirstMapped(
        _kindleEmbedQuotedPattern,
        (final match) => '"${_embedHref(match.group(1)!) ?? ''}"',
      );
    });

    result = result.replaceAllMapped(_cssUrlPattern, (final urlMatch) {
      var inner = urlMatch.group(1)!;
      inner = inner.replaceAllMapped(
        _kindleEmbedMimePattern,
        (final match) => _embedHref(match.group(1)!) ?? inner,
      );
      inner = inner.replaceAllMapped(
        _kindleEmbedPattern,
        (final match) => _embedHref(match.group(1)!) ?? inner,
      );
      inner = inner.replaceAllMapped(_kindleFlowCssPattern, (final match) {
        final target = _flowByNumber(parseBase32(match.group(1)!));
        return target?.filename ?? inner;
      });

      return 'url($inner)';
    });

    return result;
  }

  String _updateInternalLinks(final Uint8List part) {
    final asText = decodeBytes(part, header.codec);
    return asText.replaceAllMapped(_kindlePosFidPattern, (final match) {
      final resolved = _resolveByPosFid(parseBase32(match.group(1)!), parseBase32(match.group(2)!));
      if (resolved == null) return '"#"';
      final (filename, idtag) = resolved;

      return '"$filename${idtag.isEmpty ? '' : '#$idtag'}"';
    });
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

class _Elem {
  const _Elem(this.insertPos, this.tocText, this.fileNumber, this.startPos, this.length);

  /// Insert position inside the skeleton (the div entry ident).
  final int insertPos;

  /// CNCX text carrying the div aid.
  final String? tocText;

  /// File number this div belongs to.
  final int fileNumber;

  /// Raw text start of the fragment.
  final int startPos;

  /// Raw text length of the fragment.
  final int length;
}

class _Flow {
  _Flow(this.number, this.kind, this.filename, this.content);

  final int number;

  /// `css` or `svg`.
  final String kind;

  /// File name for standalone flows, null when inlined.
  final String? filename;

  /// Flow content.
  String content;
}

/// Fully assembled KF8 (AZW3) content.
class Mobi8Assembly {
  /// Creates the assembled XHTML, resources, navigation, and cover metadata.
  const Mobi8Assembly(
    this.html,
    this.css,
    this.images,
    this.fonts,
    this.navigation,
    this.resourceMap,
    this.coverName,
  );

  /// Rebuilt XHTML files.
  final List<TextFile> html;

  /// Standalone CSS files.
  final List<TextFile> css;

  /// Images (incl. standalone SVG flows).
  final List<BinaryFile> images;

  /// Fonts.
  final List<BinaryFile> fonts;

  /// TOC from the NCX index.
  final Navigation navigation;

  /// Resource index (1-based embed numbering) to file name.
  final List<String?> resourceMap;

  /// The cover resource name, when resolved.
  final String? coverName;
}

// Markup patterns are compiled once and shared by every part —
// rebuilding them per tag or per chapter dominates parse time on
// large KF8 books.
final RegExp _kindlePosFidPattern = RegExp(
  '''['"]kindle:pos:fid:([0-9A-V]+):off:([0-9A-V]+)[^"']*['"]''',
  caseSensitive: false,
);

final RegExp _amznPageBreakPattern = RegExp(
  r'''(<[^>]*?)\sdata-AmznPageBreak\s*=\s*['"]([^'"]*)['"]([^>]*>)''',
  caseSensitive: false,
);

final RegExp _flowImageTagPattern = RegExp(
  r'(<(?:img|image|svg:image)\b[^>]*>)',
  caseSensitive: false,
);

final RegExp _kindleEmbedQuotedPattern = RegExp(
  '''['"]kindle:embed:([0-9A-V]+)[^"']*['"]''',
  caseSensitive: false,
);

final RegExp _cssUrlPattern = RegExp(r'url\((.*?)\)', caseSensitive: false, dotAll: true);

final RegExp _kindleEmbedMimePattern = RegExp(
  r'''kindle:embed:([0-9A-V]+)\?mime=image/[^\)]*''',
  caseSensitive: false,
);

final RegExp _kindleEmbedPattern = RegExp('kindle:embed:([0-9A-V]+)', caseSensitive: false);

final RegExp _kindleFlowCssPattern = RegExp(
  r'''kindle:flow:([0-9A-V]+)\?mime=text/css[^\)]*''',
  caseSensitive: false,
);

final RegExp _anyTagPattern = RegExp('(<[^>]*>)');

final RegExp _flowRefPattern = RegExp(
  r'''['"]kindle:flow:([0-9A-V]+)\?mime=([^'"]+)['"]''',
  caseSensitive: false,
);

final RegExp _imgTagPattern = RegExp(r'(<(?:img|image)\b[^>]*>)', caseSensitive: false);

final RegExp _kindleEmbedWrappedPattern = RegExp(
  '''[('"]kindle:embed:([0-9A-V]+)[^'")]*[)'"]''',
  caseSensitive: false,
);

final RegExp _styledTagPattern = RegExp(
  r'(<[a-zA-Z0-9]+\s[^>]*style\s*=\s*[^>]*>)',
  caseSensitive: false,
);

final RegExp _xmlDeclarationPattern = RegExp(r'<\?xml[^>]*>');

final RegExp _svgOpenTagPattern = RegExp('<svg[^>]*>', caseSensitive: false);

final RegExp _svgImagePattern = RegExp('<(?:svg:)?image[^>]*>', caseSensitive: false);

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

/// Removes kindlegen `aid`/`cid` attributes (renaming linked ones to
/// `id`) in a single pass, one attribute per tag — mirroring the
/// `(<[^>]*?)\s[ac]id\s*=\s*['"]([^'"]*)['"]([^>]*>)` replacement it
/// replaces.
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
      // No '>': the pattern needs its trailing one.
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
      if (linkedAids.contains(aid)) {
        buffer.write(' id="$aid"');
      }
      buffer.write(part.substring(valueEnd + 1, gt + 1));
    }
    i = gt + 1;
  }

  return isChanged ? buffer.toString() : part;
}

/// First `aid`/`cid` attribute inside `(from, to)`, as
/// `(separator index, value start, closing quote index)`.
(int, int, int)? _findAidAttribute(
  final String part,
  final List<int> units,
  final int from,
  final int to,
) {
  for (var i = from; i + 3 < to; i++) {
    if (!_isMarkupWhitespace(units[i])) {
      continue;
    }
    final c1 = _asciiLowerCase(units[i + 1]);
    if (c1 != _a && c1 != _c) {
      continue;
    }
    if (_asciiLowerCase(units[i + 2]) != _i || _asciiLowerCase(units[i + 3]) != _d) {
      continue;
    }
    var k = i + 4;
    while (k < to && _isMarkupWhitespace(units[k])) {
      k++;
    }
    if (k >= to || units[k] != _equals) {
      continue;
    }
    k++;
    while (k < to && _isMarkupWhitespace(units[k])) {
      k++;
    }
    if (k >= to || (units[k] != _doubleQuote && units[k] != _singleQuote)) {
      continue;
    }
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

const int _lt = 0x3C;

const int _gt = 0x3E;

const int _a = 0x61;

const int _c = 0x63;

const int _i = 0x69;

const int _d = 0x64;

const int _equals = 0x3D;

const int _doubleQuote = 0x22;

const int _singleQuote = 0x27;

int _asciiLowerCase(final int codeUnit) =>
    codeUnit >= 0x41 && codeUnit <= 0x5A ? codeUnit + 0x20 : codeUnit;

/// The RegExp `\s` set (ECMAScript).
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

bool _isUnknownMarker(final Uint8List data) =>
    data.length >= 4 && data[0] == 0xE9 && data[1] == 0x8E && data[2] == 0x0D && data[3] == 0x0A;

bool _isPlaceholder(final Uint8List data) =>
    data.length == 4 && data[0] == 0xA0 && data[1] == 0xA0 && data[2] == 0xA0 && data[3] == 0xA0;

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
