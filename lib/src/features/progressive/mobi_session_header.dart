import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import '../../foundation/images/image_type_sniffer.dart';
import '../mobi/codec/mobi_base32.dart';
import '../mobi/codec/mobi_byte_search.dart';
import '../mobi/codec/mobi_text_codec.dart';
import '../mobi/entities/entities.dart';
import '../mobi/header/mobi_header.dart';
import '../mobi/header/mobi_layout.dart';
import '../mobi/header/pdb_header.dart';
import '../mobi/index/ncx_reader.dart';
import '../mobi/reader/mobi6_markup.dart' show isMobi6NonImageRecord, processMobi6Html;
import '../mobi/reader/mobi6_sections.dart';
import '../mobi/reader/mobi8_markup.dart';
import '../mobi/reader/mobi8_session_scan.dart';
import '../mobi/reader/mobi8_structure.dart';
import '../mobi/reader/mobi_container.dart';
import '../mobi/reader/mobi_font.dart';
import '../mobi/reader/mobi_text_store.dart';
import 'session_metrics.dart';
import 'session_policy.dart';

/// The backward id-tag walk over a part's built bytes stops after this
/// many bytes and reports an empty tag, like a part without any
/// anchor. The eager walk is unbounded; the bound only diverges when
/// the nearest `id`/`name`/`aid` attribute sits more than a megabyte
/// before the resolved position.
const _idScanBudget = 1 << 20;

/// Builds a MOBI/AZW3 session: the structural header book plus the
/// resident content state.
///
/// The open pass reads the PDB record table, the MOBI/EXTH headers,
/// the KF8 indexes (FDST, skeleton, division, NCX) and the HUFF/CDIC
/// dictionary when the book uses it, and runs one decompression pass
/// over the text records to build the record → stream-span index,
/// scanning the decompressed bytes for navigation anchors, section
/// boundaries, flow classification, and `kindle:pos:fid` references as
/// they flow through. No section text, part markup, or resource bytes
/// stay resident.
///
/// DRM fails typed exactly like the eager parse; a PDB that is not a
/// MOBI book (PalmDOC, eReader, Plucker payloads) fails as an
/// unsupported session format.
MobiSessionHeader buildMobiSessionHeader({
  required final PdbRandomAccess pdb,
  required final SessionPolicy policy,
  required final SessionMetricsCounter counter,
}) {
  final layout = parseMobiLayout(pdb, pdb.name);
  final header = layout.header;
  final coverIndex = _coverRecordIndex(pdb, header);

  if (!layout.isKf8) {
    final scan = Mobi6OpenScan();
    final store = MobiTextStore.build(
      pdb: pdb,
      header: header,
      textOffset: layout.textOffset,
      huffOffsetOverride: layout.huffOffsetOverride,
      counter: counter,
      onRecord: (final recordIndex, final streamStart, final bytes) => scan.addRecord(bytes),
    );
    scan.finish();
    final navigation = deriveMobi6NavigationBytes(
      scan,
      store,
      header.exth?.title ?? header.title,
      header.codec,
    );
    final sectionPlan = computeMobi6Sections(scan, store, navigation);
    // Declared R3: session targets name their section, so a
    // navigation point resolves across the per-section file model.
    final qualified = _qualifyMobi6Targets(navigation, sectionPlan);
    final paths = <String>[for (final section in sectionPlan.sections) section.name];
    final cover = _coverFile(pdb, coverIndex, policy);

    final book = MobiBook(
      navigation: qualified,
      files: Files.empty(),
      cover: cover,
      header: header,
      format: BookFormat.mobi,
      readingOrderPaths: paths,
    );
    final plan = Mobi6ServingPlan(sectionPlan: sectionPlan, navigation: qualified);

    return MobiSessionHeader(
      book: book,
      content: MobiSessionContent._(
        pdb: pdb,
        layout: layout,
        counter: counter,
        store: store,
        coverRecordIndex: coverIndex,
        mobi6: plan,
        kf8: null,
      ),
    );
  }

  // KF8 / AZW3. The scan rides the single decompression pass: flow
  // classification and reference discovery happen while the index
  // builds.
  final indexes = Mobi8Indexes.read(pdb: pdb, header: header, textOffset: layout.textOffset);
  final flowSpans = <(int, int)>[
    for (var i = 1; i < indexes.flowTable.length; i++)
      (indexes.flowTable[i].$1, indexes.flowTable[i].$2),
  ];
  final scan = Mobi8SessionScan(flowSpans: flowSpans);
  final store = MobiTextStore.build(
    pdb: pdb,
    header: header,
    textOffset: layout.textOffset,
    huffOffsetOverride: layout.huffOffsetOverride,
    counter: counter,
    onRecord: (_, _, bytes) => scan.addRecord(bytes),
  );
  scan.finish();

  final plan = Mobi8ServingPlan(
    pdb: pdb,
    header: header,
    store: store,
    indexes: indexes,
    resourceOffsets: layout.resourceOffsets,
    scan: scan,
    flow0Start: indexes.flowTable.isEmpty ? 0 : indexes.flowTable.first.$1,
    textOffset: layout.textOffset,
  );
  final navigation = plan.buildToc();
  final paths = <String>[for (var i = 0; i < plan.partCount; i++) plan.filenameOf(i)!];
  final cover = _coverFile(pdb, coverIndex, policy);

  final book = MobiBook(
    navigation: navigation,
    files: Files.empty(),
    cover: cover,
    header: header,
    format: BookFormat.azw3,
    readingOrderPaths: paths,
  );

  return MobiSessionHeader(
    book: book,
    content: MobiSessionContent._(
      pdb: pdb,
      layout: layout,
      counter: counter,
      store: store,
      coverRecordIndex: coverIndex,
      mobi6: null,
      kf8: plan,
    ),
  );
}

/// Rewrites MOBI 6 navigation targets from same-document anchors
/// (`#fileposN`) into section-qualified ones
/// (`chapterNNNNN.html#fileposN`), pointing each at the section whose
/// span begins at that anchor's insertion boundary.
Navigation _qualifyMobi6Targets(final Navigation navigation, final Mobi6SectionPlan plan) {
  String? sectionContaining(final int boundary) {
    for (final section in plan.sections) {
      if (boundary >= section.start && boundary < section.end) return section.name;
    }

    return null;
  }

  NavPoint qualify(final NavPoint point) {
    final match = RegExp(r'#filepos(\d+)$').firstMatch(point.content);
    if (match == null) return point;

    final boundary = plan.boundaryByTarget[int.parse(match.group(1)!)];
    final section = boundary == null ? null : sectionContaining(boundary);
    if (section == null) return point;

    return NavPoint(
      classAttribute: point.classAttribute,
      id: point.id,
      playOrder: point.playOrder,
      label: point.label,
      content: '$section${point.content}',
      subNavPoints: <NavPoint>[for (final child in point.subNavPoints) qualify(child)],
    );
  }

  return Navigation(
    title: navigation.title,
    navPoints: <NavPoint>[for (final point in navigation.navPoints) qualify(point)],
  );
}

int? _coverRecordIndex(final PdbRecordAccess pdb, final MobiHeader header) {
  final base = header.firstImageIndex > 0 ? header.firstImageIndex : 1;
  final coverOffset = header.exth?.coverOffset;
  final candidates = <int>[if (coverOffset != null) base + coverOffset, base];
  for (final index in candidates) {
    if (index < 0 || index >= pdb.count) continue;
    if (sniffImageType(pdb.recordHead(index, 64)) != null) return index;
  }

  return null;
}

BinaryFile _coverFile(final PdbRandomAccess pdb, final int? index, final SessionPolicy policy) {
  if (index == null) return BinaryFile.empty();

  final data = pdb.record(index);
  final type = sniffImageType(data);
  if (type == null) return BinaryFile.empty();
  if (data.length > policy.coverMaxBytes) {
    // Oversized covers load like any other resource instead of riding
    // the header, the declared session delta.
    return BinaryFile.empty();
  }
  final name = 'cover.${type.fileExtension}';

  return BinaryFile(content: data, name: name, type: type.fileExtension, path: name);
}

/// What the engine serves from a MOBI session: the record source, the
/// decompression index, and the per-kind serving plans.
final class MobiSessionContent {
  MobiSessionContent._({
    required this.pdb,
    required this.layout,
    required this.counter,
    required this.store,
    required this.coverRecordIndex,
    required this.mobi6,
    required this.kf8,
  });

  /// The record source the session reads from.
  final PdbRandomAccess pdb;

  /// The resolved MOBI/KF8 payload layout.
  final MobiLayout layout;

  /// The shared session instrumentation counters.
  final SessionMetricsCounter counter;

  /// The decompression index and on-demand record decoder.
  final MobiTextStore store;

  /// The record the cover image lives in, when known.
  final int? coverRecordIndex;

  /// MOBI 6 serving plan; null on KF8 sessions.
  final Mobi6ServingPlan? mobi6;

  /// KF8 serving plan; null on MOBI 6 sessions.
  final Mobi8ServingPlan? kf8;

  /// The MOBI header governing the selected payload.
  MobiHeader get header => layout.header;

  final Map<String, MobiResourceSource> _resources = <String, MobiResourceSource>{};
  var _resourcesBuilt = false;

  /// One-based recindex numbering to image name, the MOBI 6 markup
  /// rewrite table; built alongside the resource map.
  Map<int, String> _recindexNames = const <int, String>{};

  /// Raw decoded bytes of a resource path, or null when unknown.
  Uint8List? resource(final String path) {
    _ensureResources();

    if (isKf8) {
      final flowNumber = kf8!.flowNumberByFilename(path);
      if (flowNumber != null && kf8!._descriptor(flowNumber).kind == 'svg') {
        return Uint8List.fromList(kf8!.flowContent(flowNumber).codeUnits);
      }
    }

    final source = _resources[path];
    if (source == null) return null;

    final data = pdb.record(source.record);
    final Uint8List? bytes = switch (source.kind) {
      ResourceKind.font => decodeFontRecord(data).data,
      ResourceKind.cresImage => _unwrapCres(source, data),
      ResourceKind.image || ResourceKind.cover => data,
    };
    counter.addMaterialized(bytes?.length ?? 0);

    return bytes;
  }

  /// Known inflated length of a resource path; null for generated
  /// documents.
  int? resourceLength(final String path) {
    _ensureResources();
    final source = _resources[path];
    if (source == null) return null;

    return pdb.recordLength(source.record);
  }

  /// The canonical [TextFile] of a section (MOBI 6), part or CSS flow
  /// (KF8), or null when the path does not exist.
  TextFile? textFile(final String path) {
    final file = isKf8 ? kf8!.textFile(path) : mobi6!.textFile(this, path);
    if (file != null) counter.addMaterialized(file.content.length * 2);

    return file;
  }

  /// Whether the session serves a KF8 (AZW3) payload.
  bool get isKf8 => kf8 != null;

  Uint8List? _unwrapCres(final MobiResourceSource source, final Uint8List data) {
    if (source.containerRecord == null) return null;
    if (data.length <= 12) return null;

    final container = MobiContainer(pdb.record(source.containerRecord!));
    if (!container.isImageContainer) return null;

    final unwrapped = Uint8List.sublistView(data, 12);

    return sniffImageType(unwrapped) != null ? unwrapped : null;
  }

  void _ensureResources() {
    if (_resourcesBuilt) return;
    _resourcesBuilt = true;

    final recindex = <int, String>{};
    if (isKf8) {
      kf8!._ensureResourceWalk();
      _resources.addAll(kf8!.sessionResources);
    } else {
      _buildMobi6ResourceMap(recindex);
    }
    _recindexNames = Map.unmodifiable(recindex);

    if (coverRecordIndex != null) {
      final name = _coverName;
      if (name != null) _resources[name] = MobiResourceSource.cover(coverRecordIndex!);
    }
  }

  String? get _coverName => coverRecordIndex == null
      ? null
      : 'cover.${sniffImageType(pdb.recordHead(coverRecordIndex!, 64))?.fileExtension}';

  void _buildMobi6ResourceMap(final Map<int, String> recindex) {
    final header = this.header;
    var start = header.firstImageIndex;
    if (start > pdb.count || start < 0) start = 0;
    final processed = <int>{0};
    for (var i = 1; i <= header.textRecordCount && i < pdb.count; i++) {
      processed.add(i);
    }
    if (header.compressionType == 0x4448) {
      for (
        var i = header.huffOffset;
        i < header.huffOffset + header.huffRecordCount && i < pdb.count;
        i++
      ) {
        processed.add(i);
      }
    }

    var imageIndex = 0;
    for (var i = start; i < pdb.count; i++) {
      if (processed.contains(i)) continue;

      processed.add(i);
      imageIndex += 1;
      final head = pdb.recordHead(i, 64);
      if (head.isNotEmpty && hasAsciiAt(head, 'FONT')) {
        final font = decodeFontRecord(pdb.record(i));
        _resources['font${_padded5(imageIndex)}.${font.extension}'] = MobiResourceSource.font(i);

        continue;
      }
      if (isMobi6NonImageRecord(head)) continue;

      final type = sniffImageType(head);
      if (type == null) continue;

      final name = 'image${_padded5(imageIndex)}.${type.fileExtension}';
      _resources[name] = MobiResourceSource.image(i);
      recindex[imageIndex] = name;
    }
  }
}

/// Serves MOBI 6 sections: materializes a section's raw slice with
/// its share of the global anchor chain, then applies the same markup
/// conversions the eager parse applies to the whole stream.
/// Removes `<html…>`, `</html>`, `<body…>`, `</body>` tags and
/// `<head…>…</head>` regions from a section slice, byte-exact for the
/// supported codecs.
Uint8List _stripDocumentWrappers(final Uint8List bytes) {
  final head = _indexOfTag(bytes, _headOpen, 0);
  if (head == -1) {
    final anyWrapper =
        _indexOfTag(bytes, _htmlOpen, 0) != -1 ||
        _indexOfTag(bytes, _bodyOpen, 0) != -1 ||
        _indexOf(bytes, _bodyClose, 0) != -1 ||
        _indexOf(bytes, _htmlClose, 0) != -1;
    if (!anyWrapper) return bytes;
  }

  final builder = BytesBuilder(copy: false);
  var pos = 0;
  var i = 0;
  while (i < bytes.length) {
    final headStart = _indexOfTag(bytes, _headOpen, i);
    if (headStart != -1) {
      final headEnd = _indexOf(bytes, _headClose, headStart);
      if (headEnd != -1) {
        builder.add(Uint8List.sublistView(bytes, pos, headStart));
        i = pos = headEnd + _headClose.length;
        continue;
      }
    }

    final tag = _firstWrapperTag(bytes, i);
    if (tag == null) break;

    builder.add(Uint8List.sublistView(bytes, pos, tag));
    final gt = indexOfByte(bytes, 0x3E, tag);
    if (gt == -1) {
      i = pos = bytes.length;
      break;
    }
    i = pos = gt + 1;
  }
  builder.add(Uint8List.sublistView(bytes, pos));

  return builder.takeBytes();
}

const List<int> _headOpen = <int>[0x3C, 0x68, 0x65, 0x61, 0x64];
const List<int> _headClose = <int>[0x3C, 0x2F, 0x68, 0x65, 0x61, 0x64, 0x3E];
const List<int> _htmlOpen = <int>[0x3C, 0x68, 0x74, 0x6D, 0x6C];
const List<int> _htmlClose = <int>[0x3C, 0x2F, 0x68, 0x74, 0x6D, 0x6C, 0x3E];
const List<int> _bodyOpen = <int>[0x3C, 0x62, 0x6F, 0x64, 0x79];
const List<int> _bodyClose = <int>[0x3C, 0x2F, 0x62, 0x6F, 0x64, 0x79, 0x3E];

int _indexOfTag(final Uint8List data, final List<int> marker, final int from) {
  // `<tag` must start a tag: the next byte is a markup space or `>`.
  var i = from;
  while (true) {
    final at = _indexOf(data, marker, i);
    if (at == -1 || at + marker.length >= data.length) return at;
    final next = data[at + marker.length];
    if (next == 0x3E || next == 0x20 || (next >= 0x09 && next <= 0x0D)) return at;

    i = at + 1;
  }
}

int? _firstWrapperTag(final Uint8List data, final int from) {
  var best = -1;
  for (final marker in [_htmlOpen, _bodyOpen]) {
    final at = _indexOfTag(data, marker, from);
    if (at != -1 && (best == -1 || at < best)) best = at;
  }
  for (final marker in [_bodyClose, _htmlClose]) {
    final at = _indexOf(data, marker, from);
    if (at != -1 && (best == -1 || at < best)) best = at;
  }

  return best == -1 ? null : best;
}

int _indexOf(final Uint8List data, final List<int> pattern, final int from) {
  outer:
  for (var i = from; i <= data.length - pattern.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) continue outer;
    }

    return i;
  }

  return -1;
}

/// Serves MOBI 6 sections: materializes a section's raw slice with
/// its share of the global anchor chain, then applies the same markup
/// conversions the eager parse applies to the whole stream.
final class Mobi6ServingPlan {
  /// Creates the serving plan from the section plan and navigation.
  const Mobi6ServingPlan({required this.sectionPlan, required this.navigation});

  /// The section table with its anchor insertion chain.
  final Mobi6SectionPlan sectionPlan;

  /// The derived navigation the header book carries.
  final Navigation navigation;

  /// The canonical [TextFile] of one section, or null when the path
  /// is not a section name.
  TextFile? textFile(final MobiSessionContent content, final String path) {
    for (final section in sectionPlan.sections) {
      if (section.name != path) continue;

      return _materialize(content, section);
    }

    return null;
  }

  TextFile _materialize(final MobiSessionContent content, final Mobi6Section section) {
    // Sections materialize within the document body range: a fragment
    // without the `</body>` close would otherwise scan the document
    // head, while the eager whole-document text never sees it. Outside
    // the range a section's canonical text is empty, matching the
    // whole-document scan exactly.
    final from = section.start > sectionPlan.bodyStart ? section.start : sectionPlan.bodyStart;
    final to = section.end < sectionPlan.bodyEnd ? section.end : sectionPlan.bodyEnd;
    var bytes = to > from ? content.store.slice(from, to) : Uint8List(0);
    // Splice this section's share of the global anchor chain first —
    // the offsets are raw-stream based, so they must apply before any
    // prefix is prepended. The chain state is global, so a
    // per-section re-scan would diverge wherever the eager chain
    // skipped an anchor.
    final splices = <(int, String)>[];
    for (final (at, anchor) in sectionPlan.insertions) {
      if (at >= from && at < to) splices.add((at - from, anchor));
    }
    if (splices.isNotEmpty) {
      final builder = BytesBuilder(copy: false);
      var pos = 0;
      for (final (at, anchor) in splices) {
        if (at < pos) continue;

        builder.add(Uint8List.sublistView(bytes, pos, at));
        builder.add(Uint8List.fromList(anchor.codeUnits));
        pos = at;
      }
      builder.add(Uint8List.sublistView(bytes, pos));
      bytes = builder.takeBytes();
    }
    // A section that starts at a navigation anchor carries that
    // anchor as a leading element: the eager parse embeds the anchor
    // inside the tag preceding the boundary, which belongs to the
    // previous section's tail. The element adds no canonical text, so
    // R1 parity is untouched, and every navigation target resolves in
    // its own section source.
    final leadingTargets = <int>[
      for (final entry in sectionPlan.boundaryByTarget.entries)
        if (entry.value == section.start && section.start != 0 && section.start >= from) entry.key,
    ];
    if (leadingTargets.isNotEmpty) {
      final builder = BytesBuilder(copy: false);
      for (final target in leadingTargets) {
        builder.add(Uint8List.fromList('<a id="filepos$target"></a>'.codeUnits));
      }
      builder.add(bytes);
      bytes = builder.takeBytes();
    }
    // Multi-record streams can repeat document wrappers mid-stream;
    // inside a section slice they would re-trigger the scanner's body
    // range and drop the section's own opening content. The wrappers
    // are pure structure — removing them changes no canonical text.
    bytes = _stripDocumentWrappers(bytes);

    final html = processMobi6Html(decodeBytes(bytes, content.header.codec), content._recindexNames);

    return TextFile(content: html, name: section.name, type: 'html', path: section.name);
  }
}

/// Serves KF8 parts, flows and resources: assembles one part at a
/// time through the shared per-part builder, resolves positions over
/// bounded built-byte windows, and walks resources on demand.
final class Mobi8ServingPlan {
  /// Creates the serving plan from the open-pass facts.
  Mobi8ServingPlan({
    required final PdbRandomAccess pdb,
    required final MobiHeader header,
    required final MobiTextStore store,
    required this.indexes,
    required final List<(int, int)> resourceOffsets,
    required this.scan,
    required this.flow0Start,
    required final int textOffset,
  }) : _pdb = pdb,
       _header = header,
       _store = store,
       _resourceOffsets = resourceOffsets,
       _textOffset = textOffset;

  final PdbRandomAccess _pdb;
  final MobiHeader _header;
  final MobiTextStore _store;

  /// The record-level KF8 index facts.
  final Mobi8Indexes indexes;
  final List<(int, int)> _resourceOffsets;

  /// The open-pass scan results: flow flags and pos:fid references.
  final Mobi8SessionScan scan;

  /// The first text record of the KF8 payload (index records are
  /// relative to it).
  final int _textOffset;

  /// Flow zero's start in the raw stream: FDST section offsets index
  /// the XHTML flow's own coordinates.
  final int flow0Start;

  /// The classified secondary flows, in FDST order.
  late final List<Mobi8FlowDescriptor> descriptors = _classifyFlows();

  /// The linked-aid set: every aid value the pos:fid resolutions
  /// discovered, complete before any part finalizes — the same set the
  /// eager step-1 pass accumulates across all parts before any part
  /// strips its aid attributes.
  late final Set<String> markupAids = _resolveMarkupAids();

  late final Map<String, int> _partIndexByPath = <String, int>{
    for (var i = 0; i < indexes.parts.length; i++) indexes.parts[i].filename: i,
  };

  late final Map<String, int> _flowNumberByFilename = <String, int>{
    for (final descriptor in descriptors)
      if (descriptor.filename != null) descriptor.filename!: descriptor.number,
  };

  final List<Mobi8Flow?> _flowCache = <Mobi8Flow?>[];
  final List<List<_BuiltSegment>> _segmentCache = <List<_BuiltSegment>>[];
  List<String?>? _embedNames;

  /// The number of rebuilt parts.
  int get partCount => indexes.parts.length;

  /// The output filename of [partIndex], or null out of range.
  String? filenameOf(final int partIndex) =>
      partIndex < indexes.parts.length ? indexes.parts[partIndex].filename : null;

  /// The 1-based FDST flow number a css/svg filename belongs to.
  int? flowNumberByFilename(final String filename) => _flowNumberByFilename[filename];

  Mobi8FlowDescriptor _descriptor(final int flowNumber) => descriptors[flowNumber - 1];

  List<Mobi8FlowDescriptor> _classifyFlows() {
    final result = <Mobi8FlowDescriptor>[];
    for (var i = 0; i < scan.flows.length; i++) {
      final flags = scan.flows[i];
      final number = i + 1;
      final padded = number.toString().padLeft(4, '0');
      if (flags.sawSvg && flags.sawGt) {
        result.add(
          flags.sawSvgImage
              ? Mobi8FlowDescriptor(number, 'svg', null, flags.svgStart)
              : Mobi8FlowDescriptor(number, 'svg', 'svg$padded.svg', flags.svgStart),
        );
      } else if (flags.sawCdata) {
        result.add(Mobi8FlowDescriptor(number, 'css', null, flags.start));
      } else {
        result.add(Mobi8FlowDescriptor(number, 'css', 'flow$padded.css', flags.start));
      }
      _flowCache.add(null);
    }

    return result;
  }

  /// Builds navigation and resolves NCX positions into part links,
  /// the eager `buildToc` decision over the bounded built-byte walks.
  Navigation buildToc() {
    Uint8List kf8Record(final int index) => _pdb.record(_textOffset - 1 + index);
    final entries = readNcx(
      kf8Record,
      _pdb.count - _textOffset + 1,
      _header.ncxIndex,
      _header.codec,
    );
    for (final entry in entries) {
      final posFid = entry.posFid;
      if (posFid != null && posFid.length >= 2) {
        final resolved = resolvePosReference(posFid[0], posFid[1]);
        if (resolved != null) {
          entry.href = resolved.filename;
          entry.idtag = resolved.tag;
          continue;
        }
      }
      if (entry.pos >= 0) {
        final partIndex = _partContaining(entry.pos);
        if (partIndex != null) {
          entry.href = indexes.parts[partIndex].filename;
          entry.idtag = idTagAt(partIndex, entry.pos - indexes.parts[partIndex].start).value;
        }
      }
    }

    return buildNavigation(entries);
  }

  // -- serving ------------------------------------------------------------

  /// The canonical [TextFile] of one part or CSS flow, or null when
  /// the path is unknown.
  TextFile? textFile(final String path) {
    final partIndex = _partIndexByPath[path];
    if (partIndex != null) return _partFile(partIndex, path);

    final flowNumber = _flowNumberByFilename[path];
    if (flowNumber != null && _descriptor(flowNumber).kind == 'css') {
      return TextFile(content: flowContent(flowNumber), name: path, type: 'css', path: path);
    }

    return null;
  }

  TextFile _partFile(final int partIndex, final String path) {
    final part = indexes.parts[partIndex];
    final built = assembleMobi8Part(
      part: part,
      elements: indexes.elements,
      elementOffset: indexes.elementOffsetFor(partIndex),
      divCount: indexes.divCounts[part.fileNumber] ?? 0,
      readSlice: _flow0Slice,
    );

    _ensureInlineFlows(built);
    final markup = _finalizer().finalizePart(partBytes: built, codec: _header.codec);

    return TextFile(content: markup, name: path, type: 'html', path: path);
  }

  Uint8List _flow0Slice(final int start, final int end) {
    final from = flow0Start + start;
    final to = flow0Start + end > _store.streamLength ? _store.streamLength : flow0Start + end;

    return _store.slice(from, to);
  }

  void _ensureInlineFlows(final Uint8List built) {
    final text = String.fromCharCodes(built);
    for (final match in mobi8FlowRefPattern.allMatches(text)) {
      try {
        final number = parseBase32(match.group(1)!);
        if (number < 1 || number > descriptors.length) continue;
        if (_flowCache[number - 1] != null) continue;
        if (_descriptor(number).filename != null) continue;

        flowContent(number);
      } on Object {
        // Unparseable reference: the finalizer keeps the raw tag, like
        // the eager parse's unknown-flow path.
      }
    }
  }

  /// Loads and link-rewrites a flow's content on demand.
  String flowContent(final int flowNumber) {
    final cached = _flowCache[flowNumber - 1];
    if (cached != null) return cached.content;

    final descriptor = _descriptor(flowNumber);
    final flags = scan.flows[flowNumber - 1];
    final start = descriptor.contentStart;
    final end = flags.end > _store.streamLength ? _store.streamLength : flags.end;
    var asText = String.fromCharCodes(_store.slice(start, end));
    if (descriptor.kind == 'css' && descriptor.filename == null) {
      asText = '<style type="text/css">\n$asText\n</style>\n';
    }
    final flow = Mobi8Flow(descriptor.number, descriptor.kind, descriptor.filename, asText);
    flow.content = _finalizer().rewriteFlowContent(flow.content);
    _flowCache[flowNumber - 1] = flow;

    return flow.content;
  }

  Mobi8MarkupFinalizer _finalizer() {
    return Mobi8MarkupFinalizer(
      flows: <Mobi8Flow>[
        for (var i = 0; i < descriptors.length; i++)
          Mobi8Flow(
            descriptors[i].number,
            descriptors[i].kind,
            descriptors[i].filename,
            _flowCache[i]?.content ?? '',
          ),
      ],
      resourceMap: _embedNameMap(),
      resolvePosFid: (final fid, final offset) => resolvePosReference(fid, offset)?.pair,
      linkedAids: markupAids,
    );
  }

  List<String?> _embedNameMap() {
    _ensureResourceWalk();

    return _embedNames ?? const <String?>[];
  }

  // -- position resolution ------------------------------------------------

  /// One `kindle:pos:fid` resolution: the containing part's file name,
  /// the anchor tag value at the position, and whether that value came
  /// from an `aid` attribute (only those join the linked set).
  Mobi8PosResolution? resolvePosReference(final int fid, final int offset) {
    if (fid < 0 || fid >= indexes.elements.length) return null;

    final pos = indexes.elements[fid].insertPos + offset;
    final partIndex = _partContaining(pos);
    if (partIndex == null) return null;

    final resolution = idTagAt(partIndex, pos - indexes.parts[partIndex].start);

    return Mobi8PosResolution(
      indexes.parts[partIndex].filename,
      resolution.value,
      resolution.isAid,
    );
  }

  int? _partContaining(final int pos) {
    for (var i = 0; i < indexes.parts.length; i++) {
      if (pos >= indexes.parts[i].start && pos < indexes.partRawEnds[i]) return i;
    }

    return null;
  }

  Set<String> _resolveMarkupAids() {
    final aids = <String>{};
    for (final (fid, offset) in scan.posReferences) {
      final resolved = resolvePosReference(fid, offset);
      if (resolved != null && resolved.isAid && resolved.tag.isNotEmpty) aids.add(resolved.tag);
    }

    return aids;
  }

  /// The eager `_idTagAt` walk over a part's built bytes, fetched in
  /// bounded windows from the store.
  Mobi8IdTag idTagAt(final int partIndex, final int offset) {
    final part = indexes.parts[partIndex];
    final builtLength = indexes.partRawEnds[partIndex] - part.start;
    var npos = offset;
    final gt = _builtIndexOfByte(partIndex, 0x3E, npos);
    final lt = _builtIndexOfByte(partIndex, 0x3C, npos);
    if (lt == npos || (gt != -1 && (lt == -1 || gt < lt))) npos = gt + 1;
    if (npos > builtLength) npos = builtLength;

    var end = npos;
    var budget = _idScanBudget;
    while (end > 0 && budget > 0) {
      final pgt = _builtLastIndexOfByte(partIndex, 0x3E, 0, end);
      if (pgt == -1) break;

      final plt = _builtLastIndexOfByte(partIndex, 0x3C, 0, pgt);
      if (plt == -1) break;

      budget -= end - plt;
      final tag = String.fromCharCodes(_builtWindow(partIndex, plt, pgt + 1));
      final id = mobi8IdAttrPattern.firstMatch(tag);
      if (id != null) return Mobi8IdTag(id.group(1)!, false);

      final name = mobi8NameAttrPattern.firstMatch(tag);
      if (name != null) return Mobi8IdTag(name.group(1)!, false);

      final aid = mobi8AidAttrPattern.firstMatch(tag);
      if (aid != null) return Mobi8IdTag(aid.group(1)!, true);

      end = plt;
    }

    return const Mobi8IdTag('', false);
  }

  // -- built-byte windows -------------------------------------------------

  List<_BuiltSegment> _segmentsFor(final int partIndex) {
    if (partIndex < _segmentCache.length) return _segmentCache[partIndex];

    final part = indexes.parts[partIndex];
    final elementOffset = indexes.elementOffsetFor(partIndex);
    final divCount = indexes.divCounts[part.fileNumber] ?? 0;
    final segments = <_BuiltSegment>[];
    var builtAt = 0;
    var skeletonAt = part.start;
    var fragmentAt = part.end;
    for (var e = 0; e < divCount && elementOffset + e < indexes.elements.length; e++) {
      final element = indexes.elements[elementOffset + e];
      final insertRel = element.insertPos - part.start;
      final skeletonPiece = insertRel - (skeletonAt - part.start);
      if (skeletonPiece > 0) {
        segments.add(_BuiltSegment(builtAt, skeletonAt, skeletonPiece));
        builtAt += skeletonPiece;
        skeletonAt += skeletonPiece;
      }
      segments.add(_BuiltSegment(builtAt, fragmentAt, element.length));
      builtAt += element.length;
      fragmentAt += element.length;
      skeletonAt = part.start + insertRel;
    }
    final remaining = part.end - skeletonAt;
    if (remaining > 0) {
      segments.add(_BuiltSegment(builtAt, skeletonAt, remaining));
      builtAt += remaining;
    }
    while (_segmentCache.length < partIndex) {
      _segmentCache.add(const <_BuiltSegment>[]);
    }
    if (_segmentCache.length == partIndex) {
      _segmentCache.add(segments);
    } else {
      _segmentCache[partIndex] = segments;
    }

    return segments;
  }

  int _builtLengthOf(final int partIndex) =>
      indexes.partRawEnds[partIndex] - indexes.parts[partIndex].start;

  Uint8List _builtWindow(final int partIndex, final int from, final int to) {
    final builder = BytesBuilder(copy: false);
    for (final segment in _segmentsFor(partIndex)) {
      final segEnd = segment.builtStart + segment.length;
      if (segEnd <= from) continue;
      if (segment.builtStart >= to) break;

      final sliceFrom = from > segment.builtStart ? from - segment.builtStart : 0;
      final sliceTo = to < segEnd ? to - segment.builtStart : segment.length;
      builder.add(_store.slice(segment.sourceStart + sliceFrom, segment.sourceStart + sliceTo));
    }

    return builder.takeBytes();
  }

  int _builtIndexOfByte(final int partIndex, final int byte, final int from) {
    const window = 32 << 10;
    var start = from;
    final length = _builtLengthOf(partIndex);
    while (start < length) {
      final end = start + window > length ? length : start + window;
      final at = indexOfByte(_builtWindow(partIndex, start, end), byte, 0);
      if (at != -1) return start + at;
      start = end;
    }

    return -1;
  }

  int _builtLastIndexOfByte(final int partIndex, final int byte, final int from, final int to) {
    const window = 32 << 10;
    var end = to;
    while (end > from) {
      final start = end - window < from ? from : end - window;
      final slice = _builtWindow(partIndex, start, end);
      final at = lastIndexOfByte(slice, byte, 0, slice.length);
      if (at != -1) return start + at;
      if (start == from) return -1;
      end = start;
    }

    return -1;
  }

  // -- resources ------------------------------------------------------------

  void _ensureResourceWalk() {
    if (_embedNames != null) return;

    final names = <String?>[];
    for (final (start, end) in _resourceOffsets) {
      int? containerRecord;
      for (var i = start; i < end && i < _pdb.count; i++) {
        final resourceNumber = names.length + 1;
        final head = _pdb.recordHead(i, 64);
        final type = head.length >= 4 ? String.fromCharCodes(head.sublist(0, 4)) : '';
        String? name;
        if (type == 'CONT') {
          containerRecord = hasAsciiAt(head, 'CONTBOUNDARY') ? null : i;
        } else if (type == 'FONT') {
          final font = decodeFontRecord(_pdb.record(i));
          name = _resourceName('font', resourceNumber, font.extension);
          _sessionResources[name] = MobiResourceSource.font(i);
        } else if (type == 'CRES') {
          if (containerRecord != null) {
            final extension = _cresHeadExtension(i, containerRecord);
            if (extension != null) {
              name = _resourceName('image', resourceNumber, extension);
              _sessionResources[name] = MobiResourceSource.cresImage(i, containerRecord);
            }
          }
        } else if (_ignoredKf8RecordTypes.contains(type) || _isUnknownMarkerHead(head)) {
          name = null;
        } else {
          final sniffed = sniffImageType(head);
          if (sniffed != null) {
            name = _resourceName('image', resourceNumber, sniffed.fileExtension);
            _sessionResources[name] = MobiResourceSource.image(i);
          }
        }

        names.add(name);
      }
    }
    _embedNames = names;
  }

  String? _cresHeadExtension(final int record, final int containerRecord) {
    final data = _pdb.record(record);
    if (data.length <= 12) return null;

    final container = MobiContainer(_pdb.record(containerRecord));
    if (!container.isImageContainer) return null;

    return sniffImageType(Uint8List.sublistView(data, 12))?.fileExtension;
  }

  final Map<String, MobiResourceSource> _sessionResources = <String, MobiResourceSource>{};

  /// The record sources the resource walk produced, keyed by output
  /// name.
  Map<String, MobiResourceSource> get sessionResources => _sessionResources;
}

/// One `kindle:pos:fid` resolution: the containing part's file name,
/// the anchor tag value at the position, and whether that value came
/// from an `aid` attribute.
final class Mobi8PosResolution {
  /// Creates the resolution from its fields.
  const Mobi8PosResolution(this.filename, this.tag, this.isAid);

  /// The (filename, tag) pair the markup finalizer consumes.
  (String, String) get pair => (filename, tag);

  /// The containing part's output filename.
  final String filename;

  /// The anchor tag value at the resolved position.
  final String tag;

  /// Whether the value came from an `aid` attribute.
  final bool isAid;
}

/// The value of the tag a built-space position resolves to, and which
/// attribute matched.
final class Mobi8IdTag {
  /// Creates the tag result from its fields.
  const Mobi8IdTag(this.value, this.isAid);

  /// The matched attribute value.
  final String value;

  /// Whether the matched attribute was `aid`.
  final bool isAid;
}

/// The completed session: header book plus resident content.
final class MobiSessionHeader {
  /// Creates the session from its header book and content state.
  const MobiSessionHeader({required this.book, required this.content});

  /// The structural header book: complete navigation, metadata, cover
  /// and reading order with an empty file set.
  final MobiBook book;

  /// The resident state the engine serves content from.
  final MobiSessionContent content;
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

String _resourceName(final String kind, final int number, final String extension) {
  return '$kind${number.toString().padLeft(5, '0')}.$extension';
}

String _padded5(final int value) => value.toString().padLeft(5, '0');

const Set<String> _ignoredKf8RecordTypes = <String>{
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
};

bool _isUnknownMarkerHead(final Uint8List head) {
  return head.length >= 4 &&
      head[0] == 0xE9 &&
      head[1] == 0x8E &&
      head[2] == 0x0D &&
      head[3] == 0x0A;
}

/// Where one named resource lives: its record and how to decode it.
final class MobiResourceSource {
  const MobiResourceSource._(this.record, this.kind, this.containerRecord);

  /// A direct image record.
  const MobiResourceSource.image(final int record) : this._(record, ResourceKind.image, null);

  /// A font record needing decode.
  const MobiResourceSource.font(final int record) : this._(record, ResourceKind.font, null);

  /// A CRES payload inside a CONT container.
  const MobiResourceSource.cresImage(final int record, final int container)
    : this._(record, ResourceKind.cresImage, container);

  /// The cover record.
  const MobiResourceSource.cover(final int record) : this._(record, ResourceKind.cover, null);

  /// The record holding the resource bytes.
  final int record;

  /// How the record decodes.
  final ResourceKind kind;

  /// The CONT record a CRES payload unwraps through.
  final int? containerRecord;
}

/// How a resource record decodes.
enum ResourceKind {
  /// A direct image record.
  image,

  /// A font record decoded through the font codec.
  font,

  /// A CRES payload unwrapped through its CONT container.
  cresImage,

  /// The cover record.
  cover,
}

/// A classified flow without its content: kind, output filename and
/// the stream offset its content starts at.
final class Mobi8FlowDescriptor {
  /// Creates the descriptor from its classification fields.
  const Mobi8FlowDescriptor(this.number, this.kind, this.filename, this.contentStart);

  /// The 1-based FDST flow number.
  final int number;

  /// Either `css` or `svg`.
  final String kind;

  /// The output filename, or null for inline flows.
  final String? filename;

  /// Stream offset the content strips to (the SVG opening, or the
  /// flow start).
  final int contentStart;
}

/// One built-part segment: a built-byte range backed by a raw-stream
/// slice (skeleton or fragment bytes).
final class _BuiltSegment {
  /// Creates a segment over [length] built bytes sourced at
  /// [sourceStart].
  const _BuiltSegment(this.builtStart, this.sourceStart, this.length);

  final int builtStart;
  final int sourceStart;
  final int length;
}
