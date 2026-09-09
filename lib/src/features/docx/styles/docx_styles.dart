import 'package:e_livre/src/features/docx/container/docx_package.dart';
import 'package:xml/xml.dart';

/// Paragraph style information needed by the DOCX renderer.
final class DocxStyle {
  /// Creates the subset of a paragraph style used during rendering.
  const DocxStyle({required this.name, this.outlineLevel});

  /// The declared style name.
  final String name;

  /// The optional zero-based outline level.
  final int? outlineLevel;
}

/// Numbering formats needed to choose ordered or unordered XHTML lists.
final class DocxNumbering {
  /// Creates numbering definitions keyed by numbering and nesting level.
  const DocxNumbering(this._formats);

  /// Creates an empty numbering definition.
  const DocxNumbering.empty() : _formats = const <int, Map<int, String>>{};

  final Map<int, Map<int, String>> _formats;

  /// Returns the numbering format for [numId] at [level].
  String format(final int numId, final int level) => _formats[numId]?[level] ?? 'decimal';
}

/// Reads paragraph styles used by headings and other structural content.
Map<String, DocxStyle> readDocxStyles(final XmlDocument? document) {
  if (document == null) return const <String, DocxStyle>{};

  final result = <String, DocxStyle>{};
  for (final element in document.rootElement.children.whereType<XmlElement>()) {
    if (element.name.local != 'style') continue;
    final id = docxAttribute(element, 'styleId');
    if (id == null || id.isEmpty) continue;
    final name = docxAttribute(docxChild(element, 'name'), 'val') ?? id;
    final outline = int.tryParse(
      docxAttribute(docxChild(docxChild(element, 'pPr'), 'outlineLvl'), 'val') ?? '',
    );
    result[id] = DocxStyle(name: name, outlineLevel: outline);
  }

  return result;
}

/// Reads list numbering formats used by paragraph list properties.
DocxNumbering readDocxNumbering(final XmlDocument? document) {
  if (document == null) return const DocxNumbering.empty();

  final abstractFormats = <String, Map<int, String>>{};
  for (final abstractNum in document.rootElement.children.whereType<XmlElement>()) {
    if (abstractNum.name.local != 'abstractNum') continue;
    final abstractId = docxAttribute(abstractNum, 'abstractNumId');
    if (abstractId == null) continue;
    final levels = <int, String>{};
    for (final level in abstractNum.children.whereType<XmlElement>()) {
      if (level.name.local != 'lvl') continue;
      final ilvl = int.tryParse(docxAttribute(level, 'ilvl') ?? '');
      final numFmt = docxChild(level, 'numFmt');
      final format = docxAttribute(numFmt, 'val');
      if (ilvl != null && format != null) levels[ilvl] = format;
    }
    abstractFormats[abstractId] = levels;
  }

  final numFormats = <int, Map<int, String>>{};
  for (final num in document.rootElement.children.whereType<XmlElement>()) {
    if (num.name.local != 'num') continue;
    final numId = int.tryParse(docxAttribute(num, 'numId') ?? '');
    final abstractId = docxAttribute(docxChild(num, 'abstractNumId'), 'val');
    if (numId == null || abstractId == null) continue;
    numFormats[numId] = abstractFormats[abstractId] ?? const <int, String>{};
  }

  return DocxNumbering(numFormats);
}
