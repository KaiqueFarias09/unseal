import 'dart:typed_data';

import 'package:e_livre/src/features/mobi/header/mobi_header.dart';
import 'package:e_livre/src/features/mobi/index/indx_reader.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';

/// A single NCX (KF8 table of contents) index entry.
class NcxEntry {
  /// The entry ident.
  String name = '';

  /// Ordinal position in the index.
  int num = 0;

  /// Raw position in the flow (when present).
  int pos = -1;

  /// Length at the position.
  int len = 0;

  /// Display text offset into CNCX.
  int nameOffset = -1;

  /// Display text.
  String text = 'Unknown Text';

  /// Hierarchy level.
  int hlvl = -1;

  /// Kind text offset into CNCX.
  int kindOffset = -1;

  /// Kind text.
  String kind = 'Unknown Class';

  /// `(fid, offset)` pair from tag 6, when present.
  List<int>? posFid;

  /// Parent entry num.
  int parent = -1;

  /// First child entry num.
  int child1 = -1;

  /// Last child entry num.
  int childN = -1;

  /// Resolved target href (set by the KF8 assembler).
  String href = '';

  /// Resolved target fragment id (set by the KF8 assembler).
  String idtag = '';
}

/// Reads the KF8 NCX index at [ncxIndex].
///
/// [recordAt] accesses PDB records; index record positions are
/// relative to the KF8 header record, so callers pass an accessor
/// already shifted to the KF8 half of joint files.
List<NcxEntry> readNcx(
  final Uint8List Function(int) recordAt,
  final int recordCount,
  final int ncxIndex,
  final String codec,
) {
  final entries = <NcxEntry>[];
  if (ncxIndex == nullIndex) return entries;

  final (table, cncx) = readIndex(recordAt, recordCount, ncxIndex, codec);
  var num = 0;
  for (final ident in table.keys) {
    final tagMap = table[ident]!;
    final entry = NcxEntry()
      ..name = ident
      ..num = num++;
    for (final tagId in tagMap.keys) {
      final values = tagMap[tagId]!;
      if (values.isEmpty) continue;
      switch (tagId) {
        case 1:
          entry.pos = values.first;
        case 2:
          entry.len = values.first;
        case 3:
          entry.nameOffset = values.first;
          entry.text = cncx.get(values.first) ?? entry.text;
        case 4:
          entry.hlvl = values.first;
        case 5:
          entry.kindOffset = values.first;
          entry.kind = cncx.get(values.first) ?? entry.kind;
        case 6:
          entry.posFid = values;
        case 21:
          entry.parent = values.first;
        case 22:
          entry.child1 = values.first;
        case 23:
          entry.childN = values.first;
      }
    }
    entries.add(entry);
  }

  return entries;
}

/// Builds a [Navigation] from enriched NCX [entries].
///
/// Mirrors Calibre's `build_toc`: entries are grouped by hierarchy
/// level and attached to the node identified by their parent num.
Navigation buildNavigation(final List<NcxEntry> entries) {
  final levels = entries.map((final e) => e.hlvl).toSet().toList()..sort();
  final roots = <NavPoint>[];
  final nodes = <int, List<NavPoint>>{-1: roots};
  var playOrder = 0;

  for (final level in levels) {
    for (final entry in entries.where((final e) => e.hlvl == level)) {
      final parentChildren = nodes[entry.parent] ?? roots;
      final target = entry.idtag.isEmpty ? entry.href : '${entry.href}#${entry.idtag}';
      playOrder++;
      final point = NavPoint(
        classAttribute: entry.kind,
        id: 'toc-${entry.num}',
        playOrder: '$playOrder',
        label: entry.text,
        content: target,
      );
      parentChildren.add(point);
      nodes.putIfAbsent(entry.num, () => <NavPoint>[]).add(point);
    }
  }

  return Navigation(title: '', navPoints: roots);
}
