import '../../../features/pdf/entities/pdf_layout.dart';
import '../../../features/pdf/entities/pdf_page_text.dart';
import '../../../features/pdf/layout/pdf_page_structure.dart';
import '../../../foundation/text/text_profile.dart';

/// Encodes one PDF page's [PdfPageStructure] for the
/// `sessionPdfStructure` reply: geometry, source lines, words, blocks,
/// columns, tables, the canonical text and the alignment arrays the
/// mapping needs. Everything is structured-clone-safe JSON — geometry
/// and revisions survive the trip unchanged.
///
/// JSON null is the caller's signal for "no such page"; out-of-range
/// indexes arrive as typed errors instead.
Map<String, Object?> encodePdfPageStructureWire(final PdfPageStructure structure) {
  return <String, Object?>{
    'pageIndex': structure.pageIndex,
    'pageCount': structure.pageCount,
    'geometry': <String, Object?>{
      'width': structure.geometry.width,
      'height': structure.geometry.height,
      'rotation': structure.geometry.rotation,
      'transform': structure.geometry.transform,
    },
    'sourceLines': <Object?>[
      for (final line in structure.sourceLines)
        <String, Object?>{
          'text': line.text,
          'x': line.x,
          'y': line.y,
          'width': line.width,
          'height': line.height,
          'fontSize': line.fontSize,
          'rotated': line.rotated,
        },
    ],
    'words': <Object?>[
      for (final word in structure.words)
        <String, Object?>{
          'text': word.text,
          'x': word.x,
          'y': word.y,
          'width': word.width,
          'height': word.height,
          'fontSize': word.fontSize,
          'rotated': word.rotated,
          'directionX': word.directionX,
          'directionY': word.directionY,
        },
    ],
    'wordLineIndexes': <Object?>[
      for (var i = 0; i < structure.words.length; i++) structure.wordSourceLine(i),
    ],
    'wordRanges': <Object?>[
      for (var i = 0; i < structure.words.length; i++)
        _encodeWordRange(structure.wordSourceRange(i)),
    ],
    'blocks': <Object?>[
      for (final block in structure.blocks)
        <String, Object?>{
          'index': block.index,
          'text': block.text,
          'x': block.x,
          'y': block.y,
          'width': block.width,
          'height': block.height,
          'role': block.role.name,
          'sourceLineIndexes': block.sourceLineIndexes,
        },
    ],
    'columns': <Object?>[
      for (final column in structure.columns)
        <String, Object?>{
          'x': column.x,
          'width': column.width,
          'blockIndexes': column.blockIndexes,
        },
    ],
    'tableRegion': structure.tableRegion == null
        ? null
        : _encodeTableRegion(structure.tableRegion!),
    'tableUnsupported': structure.tableUnsupported == null
        ? null
        : <String, Object?>{
            'x': structure.tableUnsupported!.x,
            'y': structure.tableUnsupported!.y,
            'width': structure.tableUnsupported!.width,
            'height': structure.tableUnsupported!.height,
            'reason': structure.tableUnsupported!.reason,
          },
    'canonicalText': structure.canonicalText,
    'canonicalProfile': <String, Object?>{
      'id': structure.canonicalProfile.id,
      'algorithm': structure.canonicalProfile.algorithm,
      'options': <String, Object?>{
        for (final entry in structure.canonicalProfile.options.entries) entry.key: entry.value,
      },
      'planRevision': structure.canonicalProfile.planRevision,
    },
    'canonicalLineSources': structure.canonicalLineSources,
    'readingOrder': <Object?>[
      for (final (path, isHtml) in structure.readingOrderPaths) <Object?>[path, isHtml],
    ],
  };
}

Object? _encodeWordRange(final (int, int)? range) {
  if (range == null) return null;

  return <int>[range.$1, range.$2];
}

Map<String, Object?> _encodeTableRegion(final PdfTableRegion region) {
  return <String, Object?>{
    'x': region.x,
    'y': region.y,
    'width': region.width,
    'height': region.height,
    'hasRulingLines': region.hasRulingLines,
    'algorithm': region.algorithm,
    'rows': <Object?>[
      for (final row in region.rows)
        <Object?>[
          for (final cell in row)
            <String, Object?>{
              'row': cell.row,
              'column': cell.column,
              'text': cell.text,
              'x': cell.x,
              'y': cell.y,
              'width': cell.width,
              'height': cell.height,
              'ranges': <Object?>[
                for (final range in cell.ranges) <int>[range.lineIndex, range.start, range.end],
              ],
            },
        ],
    ],
  };
}

/// Decodes a [PdfPageStructure] from [encodePdfPageStructureWire].
/// Numbers cross as JSON, so geometry comes back through [num].
PdfPageStructure decodePdfPageStructureWire(final Map<String, Object?> json) {
  final geometry = json['geometry'] as Map<String, Object?>;
  final profile = json['canonicalProfile'] as Map<String, Object?>;
  final options = <String, String>{
    for (final entry in (profile['options'] as Map<Object?, Object?>).entries)
      entry.key as String: entry.value as String,
  };
  final rebuiltProfile = TextProfile.of(
    algorithm: profile['algorithm'] as String,
    options: options,
    planRevision: profile['planRevision'] as String,
  );
  if (rebuiltProfile.id != profile['id']) {
    throw ArgumentError('Wire canonical profile id does not match its parts');
  }

  return PdfPageStructure.restore(
    pageIndex: json['pageIndex'] as int,
    pageCount: json['pageCount'] as int,
    geometry: PdfPageGeometry.raw(
      width: (geometry['width'] as num).toDouble(),
      height: (geometry['height'] as num).toDouble(),
      rotation: geometry['rotation'] as int,
      transform: List<double>.of(
        (geometry['transform'] as List<Object?>).cast<num>().map<double>(numToDouble),
      ),
    ),
    sourceLines: <PdfTextLine>[
      for (final line in json['sourceLines'] as List<Object?>)
        (line as Map<String, Object?>)._sourceLine(),
    ],
    words: <PdfWord>[
      for (final word in json['words'] as List<Object?>) (word as Map<String, Object?>)._word(),
    ],
    blocks: <PdfTextBlock>[
      for (final block in json['blocks'] as List<Object?>) (block as Map<String, Object?>)._block(),
    ],
    columns: <PdfColumnRegion>[
      for (final column in json['columns'] as List<Object?>)
        (column as Map<String, Object?>)._column(),
    ],
    tableRegion: json['tableRegion'] == null
        ? null
        : _decodeTableRegion(json['tableRegion'] as Map<String, Object?>),
    tableUnsupported: json['tableUnsupported'] == null
        ? null
        : _decodeTableUnsupported(json['tableUnsupported'] as Map<String, Object?>),
    canonicalText: json['canonicalText'] as String,
    canonicalProfile: rebuiltProfile,
    canonicalLineSources: List<int>.of((json['canonicalLineSources'] as List<Object?>).cast<int>()),
    wordLineIndexes: <int?>[
      for (final value in json['wordLineIndexes'] as List<Object?>) value as int?,
    ],
    wordRanges: <(int, int)?>[
      for (final value in json['wordRanges'] as List<Object?>) _decodeWordRange(value),
    ],
    readingOrderPaths: <(String, bool)>[
      for (final entry in json['readingOrder'] as List<Object?>)
        ((entry as List<Object?>)[0] as String, entry[1] as bool),
    ],
  );
}

(int, int)? _decodeWordRange(final Object? value) {
  if (value == null) return null;
  final parts = value as List<Object?>;

  return (parts[0] as int, parts[1] as int);
}

PdfTableRegion _decodeTableRegion(final Map<String, Object?> json) {
  return PdfTableRegion(
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
    hasRulingLines: json['hasRulingLines'] as bool,
    algorithm: json['algorithm'] as String,
    rows: <List<PdfTableCell>>[
      for (final row in json['rows'] as List<Object?>)
        <PdfTableCell>[
          for (final cell in row as List<Object?>) (cell as Map<String, Object?>)._tableCell(),
        ],
    ],
  );
}

PdfTableUnsupported _decodeTableUnsupported(final Map<String, Object?> json) {
  return PdfTableUnsupported(
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
    reason: json['reason'] as String,
  );
}

extension _StructureWire on Map<String, Object?> {
  PdfTextLine _sourceLine() => PdfTextLine(
    text: this['text'] as String,
    x: (this['x'] as num).toDouble(),
    y: (this['y'] as num).toDouble(),
    width: (this['width'] as num).toDouble(),
    height: (this['height'] as num).toDouble(),
    fontSize: (this['fontSize'] as num).toDouble(),
    rotated: this['rotated'] as bool,
  );

  PdfWord _word() => PdfWord(
    text: this['text'] as String,
    x: (this['x'] as num).toDouble(),
    y: (this['y'] as num).toDouble(),
    width: (this['width'] as num).toDouble(),
    height: (this['height'] as num).toDouble(),
    fontSize: (this['fontSize'] as num).toDouble(),
    rotated: this['rotated'] as bool,
    directionX: (this['directionX'] as num).toDouble(),
    directionY: (this['directionY'] as num).toDouble(),
  );

  PdfTextBlock _block() => PdfTextBlock(
    index: this['index'] as int,
    text: this['text'] as String,
    x: (this['x'] as num).toDouble(),
    y: (this['y'] as num).toDouble(),
    width: (this['width'] as num).toDouble(),
    height: (this['height'] as num).toDouble(),
    role: PdfBlockRole.values.byName(this['role'] as String),
    sourceLineIndexes: List<int>.of((this['sourceLineIndexes'] as List<Object?>).cast<int>()),
  );

  PdfColumnRegion _column() => PdfColumnRegion(
    x: (this['x'] as num).toDouble(),
    width: (this['width'] as num).toDouble(),
    blockIndexes: List<int>.of((this['blockIndexes'] as List<Object?>).cast<int>()),
  );

  PdfTableCell _tableCell() => PdfTableCell(
    row: this['row'] as int,
    column: this['column'] as int,
    text: this['text'] as String,
    x: (this['x'] as num).toDouble(),
    y: (this['y'] as num).toDouble(),
    width: (this['width'] as num).toDouble(),
    height: (this['height'] as num).toDouble(),
    ranges: <PdfCellRange>[
      for (final range in this['ranges'] as List<Object?>)
        () {
          final parts = range as List<Object?>;

          return PdfCellRange(
            lineIndex: parts[0] as int,
            start: parts[1] as int,
            end: parts[2] as int,
          );
        }(),
    ],
  );
}

/// Identity helper keeping the list conversions single-expression.
double numToDouble(final num value) => value.toDouble();
