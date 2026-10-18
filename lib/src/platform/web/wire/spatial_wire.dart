import '../../../features/alto/bind_alto_snapshot.dart';
import '../../../features/djvu/djvu_page_structure.dart';
import '../../../features/djvu/djvu_text.dart';
import '../../../features/hocr/bind_hocr_snapshot.dart';
import '../../../features/page/bind_page_snapshot.dart';
import '../../../foundation/spatial/spatial_rect.dart';
import '../../../foundation/spatial/spatial_text_page.dart';
import '../../../foundation/spatial/spatial_text_zone.dart';
import '../../../foundation/spatial/spatial_unit.dart';
import '../../../foundation/text/publication_revision.dart';
import '../../../foundation/text/section_occurrence.dart';
import '../../../foundation/text/text_profile.dart';
import 'book_components_wire.dart';

/// Wire codecs for the spatial operations: one [DjvuPageStructure] and
/// one [AltoBoundSpatialText]. Every shape is structured-clone-safe;
/// the structure's page text travels as a wire blob.
///
/// Zone records encode as flat lists — `[type, x0, y0, x1, y1,
/// utf8Start, utf8Length, utf16Start, utf16End, childCount]` in
/// depth-first order, children directly after their parent — so a page's
/// hierarchy crosses the worker in one compact array.

Map<String, Object?> encodeDjvuPageStructureWire(
  final DjvuPageStructure structure,
  final List<Object> blobs,
) {
  final zones = <Object?>[];
  void walk(final DjvuTextZone zone) {
    zones.addAll(<Object?>[
      zone.type,
      zone.xmin,
      zone.ymin,
      zone.xmax,
      zone.ymax,
      zone.utf8Start,
      zone.utf8Length,
      zone.utf16Start,
      zone.utf16End,
      zone.children.length,
    ]);
    for (final child in zone.children) {
      walk(child);
    }
  }

  final root = structure.nativeRoot;
  if (root != null) walk(root);

  return <String, Object?>{
    'pageIndex': structure.pageIndex,
    'pageCount': structure.pageCount,
    'width': structure.width,
    'height': structure.height,
    'dpi': structure.dpi,
    'rotation': structure.rotation,
    'paths': <Object?>[
      for (final (path, isHtml) in structure.readingOrderPaths) <Object?>[path, isHtml],
    ],
    'text': structure.canonicalText.isEmpty ? null : pushWireBlob(blobs, structure.canonicalText),
    'zones': zones,
  };
}

/// Rebuilds the structure a [encodeDjvuPageStructureWire] payload
/// carries; null when the op reported a page without a text chunk.
DjvuPageStructure? decodeDjvuPageStructureWire(
  final Map<String, Object?>? json,
  final List<Object> blobs,
) {
  if (json == null) return null;
  final textBlob = json['text'] as int?;
  final text = textBlob == null ? '' : blobs[textBlob] as String;
  final flat = (json['zones'] as List<Object?>).cast<int>();
  final root = _restoreZoneTree(flat);
  final chunk = DjvuTextChunk.restore(
    text: text,
    zoneCount: root == null ? 0 : root.recordCount(),
    root: root,
  );

  return DjvuPageStructure.restore(
    pageIndex: json['pageIndex'] as int,
    pageCount: json['pageCount'] as int,
    width: json['width'] as int,
    height: json['height'] as int,
    dpi: json['dpi'] as int,
    rotation: json['rotation'] as int,
    chunk: chunk,
    readingOrderPaths: <(String, bool)>[
      for (final entry in (json['paths'] as List<Object?>).cast<List<Object?>>())
        (entry[0] as String, entry[1] as bool),
    ],
  );
}

/// Rebuilds the depth-first tree from the flat child-count encoding;
/// null for an empty payload.
DjvuTextZone? _restoreZoneTree(final List<int> flat) {
  if (flat.isEmpty) return null;
  const recordFields = 10;
  if (flat.length % recordFields != 0) {
    throw ArgumentError('DjVu structure zones are misaligned');
  }
  DjvuTextZone? root;
  final stack = <(DjvuTextZone, int)>[];
  var position = 0;
  while (position < flat.length) {
    final zone = DjvuTextZone.restore(
      type: flat[position],
      xmin: flat[position + 1],
      ymin: flat[position + 2],
      xmax: flat[position + 3],
      ymax: flat[position + 4],
      utf8Start: flat[position + 5],
      utf8Length: flat[position + 6],
      utf16Start: flat[position + 7],
      utf16End: flat[position + 8],
      children: <DjvuTextZone>[],
    );
    final children = flat[position + 9];
    position += recordFields;
    if (root == null) {
      root = zone;
    } else {
      if (stack.isEmpty) {
        throw ArgumentError('DjVu structure holds more than one root zone');
      }
      final (parent, remaining) = stack.removeLast();
      if (remaining < 1) {
        throw ArgumentError('DjVu structure declares more children than records');
      }
      parent.children.add(zone);
      if (remaining > 1) stack.add((parent, remaining - 1));
    }
    if (children > 0) stack.add((zone, children));
  }
  if (stack.isNotEmpty) {
    throw ArgumentError('DjVu structure zones end inside an unfinished subtree');
  }

  return root;
}

/// The wire map of a publication identity.
Map<String, Object?> encodePublicationRevisionWire(final PublicationRevision identity) {
  return <String, Object?>{
    'publicationId': identity.publicationId,
    'editionId': identity.editionId,
    'sourceRevision': identity.sourceRevision,
    'sourceEvidence': identity.sourceEvidence.name,
  };
}

/// Rebuilds a publication identity from its wire map.
PublicationRevision decodePublicationRevisionWire(final Object? wire) {
  if (wire is! Map<String, Object?>) {
    throw ArgumentError('Spatial identity payload must be an object');
  }

  return PublicationRevision(
    publicationId: wire['publicationId'] as String,
    editionId: wire['editionId'] as String?,
    sourceRevision: wire['sourceRevision'] as String?,
    sourceEvidence: SourceEvidence.values.byName(wire['sourceEvidence'] as String),
  );
}

/// The wire map of one bound ALTO spatial text.
Map<String, Object?> encodeAltoBoundTextWire(final AltoBoundSpatialText bound) {
  return <String, Object?>{
    'pages': <Object?>[for (final page in bound.pages) _encodeSpatialPage(page)],
    'resolved': bound.wordsResolved,
    'ambiguous': bound.wordsAmbiguous,
    'missing': bound.wordsMissing,
    'amb': <Object?>[
      for (final word in bound.ambiguousWords)
        <String, Object?>{
          'p': word.pageIndex,
          'b': word.blockIndex,
          'l': word.lineIndex,
          'w': word.wordIndex,
          'content': word.content,
          'cands': <Object?>[
            for (final (start, end) in word.candidates) <Object?>[start, end],
          ],
          'chosen': <Object?>[word.chosen.$1, word.chosen.$2],
        },
    ],
    'identity': encodePublicationRevisionWire(bound.targetIdentity),
    'occurrence': <String, Object?>{
      'sectionIndex': bound.targetOccurrence.sectionIndex,
      'resourcePath': bound.targetOccurrence.resourcePath,
      'readingOrderRevision': bound.targetOccurrence.readingOrderRevision,
    },
    'profile': _encodeProfileWire(bound.targetProfile),
    'textRevision': bound.targetTextRevision,
  };
}

/// Rebuilds the bound spatial text a [encodeAltoBoundTextWire] payload
/// carries.
AltoBoundSpatialText decodeAltoBoundTextWire(final Map<String, Object?> json) {
  return AltoBoundSpatialText(
    pages: <SpatialTextPage>[
      for (final page in (json['pages'] as List<Object?>))
        _decodeSpatialPage(page as Map<String, Object?>),
    ],
    wordsResolved: json['resolved'] as int,
    wordsAmbiguous: json['ambiguous'] as int,
    wordsMissing: json['missing'] as int,
    ambiguousWords: <AltoAmbiguousWord>[
      for (final word in (json['amb'] as List<Object?>).cast<Map<String, Object?>>())
        AltoAmbiguousWord(
          pageIndex: word['p'] as int,
          blockIndex: word['b'] as int,
          lineIndex: word['l'] as int,
          wordIndex: word['w'] as int,
          content: word['content'] as String,
          candidates: <(int, int)>[
            for (final pair in (word['cands'] as List<Object?>).cast<List<Object?>>())
              (pair[0] as int, pair[1] as int),
          ],
          chosen: (
            (word['chosen'] as List<Object?>)[0] as int,
            (word['chosen'] as List<Object?>)[1] as int,
          ),
        ),
    ],
    targetIdentity: decodePublicationRevisionWire(json['identity']),
    targetOccurrence: SectionOccurrence(
      sectionIndex: (json['occurrence'] as Map<String, Object?>)['sectionIndex'] as int,
      resourcePath: (json['occurrence'] as Map<String, Object?>)['resourcePath'] as String,
      readingOrderRevision:
          (json['occurrence'] as Map<String, Object?>)['readingOrderRevision'] as String?,
    ),
    targetProfile: _decodeProfileWire(json['profile'] as Map<String, Object?>),
    targetTextRevision: json['textRevision'] as String,
  );
}

Map<String, Object?> _encodeSpatialPage(final SpatialTextPage page) {
  return <String, Object?>{
    'w': page.width,
    'h': page.height,
    'unit': page.unit.index,
    'rot': page.rotation,
    'textLength': page.textLength,
    'prov': <String, Object?>{
      'origin': page.provenance.origin.index,
      'confidence': page.provenance.hasConfidence,
      'software': page.provenance.softwareName,
      'version': page.provenance.softwareVersion,
    },
    'zones': <Object?>[
      for (final zone in page.zones)
        <Object?>[
          zone.kind.index,
          zone.rect.x,
          zone.rect.y,
          zone.rect.width,
          zone.rect.height,
          zone.textStart,
          zone.textEnd,
          zone.confidence,
        ],
    ],
  };
}

SpatialTextPage _decodeSpatialPage(final Map<String, Object?> json) {
  final prov = json['prov'] as Map<String, Object?>;

  return SpatialTextPage(
    width: json['w'] as double,
    height: json['h'] as double,
    unit: SpatialUnit.values[json['unit'] as int],
    rotation: json['rot'] as int,
    textLength: json['textLength'] as int,
    provenance: SpatialTextProvenance(
      origin: SpatialTextOrigin.values[prov['origin'] as int],
      hasConfidence: prov['confidence'] as bool,
      softwareName: prov['software'] as String?,
      softwareVersion: prov['version'] as String?,
    ),
    zones: <SpatialTextZone>[
      for (final zone in (json['zones'] as List<Object?>).cast<List<Object?>>())
        SpatialTextZone(
          kind: SpatialZoneKind.values[zone[0] as int],
          rect: SpatialRect(
            x: (zone[1] as num).toDouble(),
            y: (zone[2] as num).toDouble(),
            width: (zone[3] as num).toDouble(),
            height: (zone[4] as num).toDouble(),
          ),
          textStart: zone[5] as int,
          textEnd: zone[6] as int,
          confidence: zone[7] as double?,
        ),
    ],
  );
}

Map<String, Object?> _encodeProfileWire(final TextProfile profile) {
  return <String, Object?>{
    'id': profile.id,
    'algorithm': profile.algorithm,
    'planRevision': profile.planRevision,
    'options': <String, Object?>{...profile.options},
  };
}

TextProfile _decodeProfileWire(final Map<String, Object?> json) {
  return TextProfile.of(
    algorithm: json['algorithm'] as String,
    options: (json['options'] as Map<String, Object?>).cast<String, String>(),
    planRevision: json['planRevision'] as String,
  );
}

/// The wire map of one bound PAGE spatial text. Shares the spatial-page
/// encoding with ALTO; ambiguous units address the parsed document by
/// their region/line/word indexes.
Map<String, Object?> encodePageXmlBoundTextWire(final PageXmlBoundSpatialText bound) {
  return <String, Object?>{
    'pages': <Object?>[for (final page in bound.pages) _encodeSpatialPage(page)],
    'resolved': bound.wordsResolved,
    'ambiguous': bound.wordsAmbiguous,
    'missing': bound.wordsMissing,
    'amb': <Object?>[
      for (final unit in bound.ambiguousWords)
        <String, Object?>{
          'r': unit.place.regionIndex,
          'l': unit.place.lineIndex,
          'w': unit.place.wordIndex,
          'content': unit.content,
          'cands': <Object?>[
            for (final (start, end) in unit.candidates) <Object?>[start, end],
          ],
          'chosen': <Object?>[unit.chosen.$1, unit.chosen.$2],
        },
    ],
    'identity': encodePublicationRevisionWire(bound.targetIdentity),
    'occurrence': <String, Object?>{
      'sectionIndex': bound.targetOccurrence.sectionIndex,
      'resourcePath': bound.targetOccurrence.resourcePath,
      'readingOrderRevision': bound.targetOccurrence.readingOrderRevision,
    },
    'profile': _encodeProfileWire(bound.targetProfile),
    'textRevision': bound.targetTextRevision,
  };
}

/// Rebuilds the bound PAGE spatial text an
/// [encodePageXmlBoundTextWire] payload carries.
PageXmlBoundSpatialText decodePageXmlBoundTextWire(final Map<String, Object?> json) {
  return PageXmlBoundSpatialText(
    pages: <SpatialTextPage>[
      for (final page in (json['pages'] as List<Object?>))
        _decodeSpatialPage(page as Map<String, Object?>),
    ],
    wordsResolved: json['resolved'] as int,
    wordsAmbiguous: json['ambiguous'] as int,
    wordsMissing: json['missing'] as int,
    ambiguousWords: <PageXmlAmbiguousWord>[
      for (final unit in (json['amb'] as List<Object?>).cast<Map<String, Object?>>())
        PageXmlAmbiguousWord(
          place: PageXmlWordPlace(
            regionIndex: unit['r'] as int,
            lineIndex: unit['l'] as int?,
            wordIndex: unit['w'] as int?,
          ),
          content: unit['content'] as String,
          candidates: <(int, int)>[
            for (final pair in (unit['cands'] as List<Object?>).cast<List<Object?>>())
              (pair[0] as int, pair[1] as int),
          ],
          chosen: (
            (unit['chosen'] as List<Object?>)[0] as int,
            (unit['chosen'] as List<Object?>)[1] as int,
          ),
        ),
    ],
    targetIdentity: decodePublicationRevisionWire(json['identity']),
    targetOccurrence: SectionOccurrence(
      sectionIndex: (json['occurrence'] as Map<String, Object?>)['sectionIndex'] as int,
      resourcePath: (json['occurrence'] as Map<String, Object?>)['resourcePath'] as String,
      readingOrderRevision:
          (json['occurrence'] as Map<String, Object?>)['readingOrderRevision'] as String?,
    ),
    targetProfile: _decodeProfileWire(json['profile'] as Map<String, Object?>),
    targetTextRevision: json['textRevision'] as String,
  );
}

/// The wire map of one bound hOCR spatial text. Shares the spatial-page
/// encoding with ALTO and PAGE; `pageIndexes` names the document page of
/// each spatial page, and ambiguous units address the parsed document by
/// page/line/word indexes.
Map<String, Object?> encodeHocrBoundTextWire(final HocrBoundSpatialText bound) {
  return <String, Object?>{
    'pages': <Object?>[for (final page in bound.pages) _encodeSpatialPage(page)],
    'pageIndexes': <Object?>[...bound.pageIndexes],
    'resolved': bound.wordsResolved,
    'ambiguous': bound.wordsAmbiguous,
    'missing': bound.wordsMissing,
    'amb': <Object?>[
      for (final unit in bound.ambiguousUnits)
        <String, Object?>{
          'p': unit.place.pageIndex,
          'l': unit.place.lineIndex,
          'w': unit.place.wordIndex,
          'content': unit.content,
          'cands': <Object?>[
            for (final (start, end) in unit.candidates) <Object?>[start, end],
          ],
          'chosen': <Object?>[unit.chosen.$1, unit.chosen.$2],
        },
    ],
    'identity': encodePublicationRevisionWire(bound.targetIdentity),
    'occurrence': <String, Object?>{
      'sectionIndex': bound.targetOccurrence.sectionIndex,
      'resourcePath': bound.targetOccurrence.resourcePath,
      'readingOrderRevision': bound.targetOccurrence.readingOrderRevision,
    },
    'profile': _encodeProfileWire(bound.targetProfile),
    'textRevision': bound.targetTextRevision,
  };
}

/// Rebuilds the bound hOCR spatial text an [encodeHocrBoundTextWire]
/// payload carries.
HocrBoundSpatialText decodeHocrBoundTextWire(final Map<String, Object?> json) {
  return HocrBoundSpatialText(
    pages: <SpatialTextPage>[
      for (final page in (json['pages'] as List<Object?>))
        _decodeSpatialPage(page as Map<String, Object?>),
    ],
    pageIndexes: (json['pageIndexes'] as List<Object?>).cast<int>(),
    wordsResolved: json['resolved'] as int,
    wordsAmbiguous: json['ambiguous'] as int,
    wordsMissing: json['missing'] as int,
    ambiguousUnits: <HocrAmbiguousUnit>[
      for (final unit in (json['amb'] as List<Object?>).cast<Map<String, Object?>>())
        HocrAmbiguousUnit(
          place: HocrUnitPlace(
            pageIndex: unit['p'] as int,
            lineIndex: unit['l'] as int,
            wordIndex: unit['w'] as int?,
          ),
          content: unit['content'] as String,
          candidates: <(int, int)>[
            for (final pair in (unit['cands'] as List<Object?>).cast<List<Object?>>())
              (pair[0] as int, pair[1] as int),
          ],
          chosen: (
            (unit['chosen'] as List<Object?>)[0] as int,
            (unit['chosen'] as List<Object?>)[1] as int,
          ),
        ),
    ],
    targetIdentity: decodePublicationRevisionWire(json['identity']),
    targetOccurrence: SectionOccurrence(
      sectionIndex: (json['occurrence'] as Map<String, Object?>)['sectionIndex'] as int,
      resourcePath: (json['occurrence'] as Map<String, Object?>)['resourcePath'] as String,
      readingOrderRevision:
          (json['occurrence'] as Map<String, Object?>)['readingOrderRevision'] as String?,
    ),
    targetProfile: _decodeProfileWire(json['profile'] as Map<String, Object?>),
    targetTextRevision: json['textRevision'] as String,
  );
}
