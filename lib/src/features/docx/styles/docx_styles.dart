part of '../parse_docx_book.dart';

/// Paragraph style information needed by the DOCX renderer.
final class _DocxStyle {
  /// Creates the subset of a paragraph style used during rendering.
  const _DocxStyle({required this.name, this.outlineLevel});

  /// The declared style name.
  final String name;

  /// The optional zero-based outline level.
  final int? outlineLevel;
}

/// Numbering formats needed to choose ordered or unordered XHTML lists.
final class _DocxNumbering {
  /// Creates numbering definitions keyed by numbering and nesting level.
  const _DocxNumbering(this._formats);

  /// Creates an empty numbering definition.
  const _DocxNumbering.empty() : _formats = const <int, Map<int, String>>{};

  final Map<int, Map<int, String>> _formats;

  /// Returns the numbering format for [numId] at [level].
  String format(final int numId, final int level) => _formats[numId]?[level] ?? 'decimal';
}

/// Reads paragraph styles used by headings and other structural content.
Map<String, _DocxStyle> _readDocxStyles(final XmlDocument? document) {
  if (document == null) return const <String, _DocxStyle>{};

  final result = <String, _DocxStyle>{};
  for (final element in document.rootElement.children.whereType<XmlElement>()) {
    if (element.name.local != 'style') continue;

    final id = _docxAttribute(element, 'styleId');
    if (id == null || id.isEmpty) continue;

    final name = _docxAttribute(_docxChild(element, 'name'), 'val') ?? id;
    final outline = int.tryParse(
      _docxAttribute(_docxChild(_docxChild(element, 'pPr'), 'outlineLvl'), 'val') ?? '',
    );
    result[id] = _DocxStyle(name: name, outlineLevel: outline);
  }

  return result;
}

/// Reads list numbering formats used by paragraph list properties.
_DocxNumbering _readDocxNumbering(final XmlDocument? document) {
  if (document == null) return const _DocxNumbering.empty();

  final abstractFormats = <String, Map<int, String>>{};
  for (final abstractNum in document.rootElement.children.whereType<XmlElement>()) {
    if (abstractNum.name.local != 'abstractNum') continue;

    final abstractId = _docxAttribute(abstractNum, 'abstractNumId');
    if (abstractId == null) continue;

    final levels = <int, String>{};
    for (final level in abstractNum.children.whereType<XmlElement>()) {
      if (level.name.local != 'lvl') continue;

      final ilvl = int.tryParse(_docxAttribute(level, 'ilvl') ?? '');
      final numFmt = _docxChild(level, 'numFmt');
      final format = _docxAttribute(numFmt, 'val');
      if (ilvl != null && format != null) levels[ilvl] = format;
    }
    abstractFormats[abstractId] = levels;
  }

  final numFormats = <int, Map<int, String>>{};
  for (final num in document.rootElement.children.whereType<XmlElement>()) {
    if (num.name.local != 'num') continue;

    final numId = int.tryParse(_docxAttribute(num, 'numId') ?? '');
    final abstractId = _docxAttribute(_docxChild(num, 'abstractNumId'), 'val');
    if (numId == null || abstractId == null) continue;

    numFormats[numId] = abstractFormats[abstractId] ?? const <int, String>{};
  }

  return _DocxNumbering(numFormats);
}
