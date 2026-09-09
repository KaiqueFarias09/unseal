import 'package:e_livre/src/features/docx/container/docx_package.dart';
import 'package:e_livre/src/features/docx/container/docx_relationships.dart';
import 'package:e_livre/src/features/docx/exceptions/exceptions.dart';
import 'package:e_livre/src/features/docx/styles/docx_styles.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

/// XHTML, navigation, and referenced images produced from a DOCX document.
final class DocxRenderedDocument {
  /// Creates the complete rendering result consumed by the DOCX façade.
  const DocxRenderedDocument({
    required this.xhtml,
    required this.navigation,
    required this.referencedImages,
  });

  /// The generated XHTML document.
  final String xhtml;

  /// Heading navigation derived from [xhtml].
  final Navigation navigation;

  /// Normalized package paths for images referenced by the document body.
  final Set<String> referencedImages;
}

/// Renders the main WordprocessingML document and its derived navigation.
DocxRenderedDocument renderDocxDocument(
  final XmlDocument document,
  final String documentPath,
  final Map<String, DocxRelationship> relationships,
  final Map<String, DocxStyle> styles,
  final DocxNumbering numbering,
  final String? title,
) {
  final body = docxChild(document.rootElement, 'body');
  if (body == null) {
    throw InvalidDocxXmlException(document.rootElement.name.qualified, 'w:document has no w:body');
  }

  final referencedImages = <String>{};
  final context = _RenderContext(
    documentPath: documentPath,
    relationships: relationships,
    referencedImages: referencedImages,
  );
  final output = StringBuffer()
    ..write('<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head>')
    ..write('<meta charset="utf-8"/>')
    ..write('<title>${_escapeHtml(title ?? '')}</title>')
    ..write('</head><body>');

  String? listKind;
  int? listId;
  void closeList() {
    if (listKind == null) return;
    output.write('</$listKind>');
    listKind = null;
    listId = null;
  }

  for (final element in body.children.whereType<XmlElement>()) {
    if (element.name.local == 'p') {
      final list = _listInfo(element, numbering);
      if (list != null) {
        if (listKind != list.kind || listId != list.numId) {
          closeList();
          listKind = list.kind;
          listId = list.numId;
          output.write('<$listKind>');
        }
        output.write(
          '<li data-list-level="${list.level}">${_renderParagraphContent(element, context, styles)}</li>',
        );
      } else {
        closeList();
        output.write(_renderParagraph(element, context, styles));
      }
    } else if (element.name.local == 'tbl') {
      closeList();
      output.write(_renderTable(element, context, styles));
    }
  }
  closeList();

  output.write('</body></html>');
  final xhtml = output.toString();

  return DocxRenderedDocument(
    xhtml: xhtml,
    navigation: _htmlNavigation(xhtml, title: title ?? ''),
    referencedImages: referencedImages,
  );
}

String _renderParagraph(
  final XmlElement paragraph,
  final _RenderContext context,
  final Map<String, DocxStyle> styles,
) {
  final level = _headingLevel(paragraph, styles);
  final content = _renderParagraphContent(paragraph, context, styles);
  if (level != null) {
    context.headingCount++;
    return '<h$level id="heading-${context.headingCount}">$content</h$level>';
  }

  return '<p>$content</p>';
}

String _renderParagraphContent(
  final XmlElement paragraph,
  final _RenderContext context,
  final Map<String, DocxStyle> styles,
) {
  final output = StringBuffer();
  for (final child in paragraph.children.whereType<XmlElement>()) {
    if (child.name.local == 'pPr') continue;
    output.write(_renderInline(child, context, styles));
  }

  return output.isEmpty ? '&nbsp;' : output.toString();
}

String _renderInline(
  final XmlElement element,
  final _RenderContext context,
  final Map<String, DocxStyle> styles,
) {
  switch (element.name.local) {
    case 'r':
      return _renderRun(element, context);
    case 'hyperlink':
      final content = _renderChildren(element, context, styles);
      final relationshipId = docxAttribute(element, 'id');
      final relationship = relationshipId == null ? null : context.relationships[relationshipId];
      if (relationship == null || relationship.external == false) return content;
      return '<a href="${_escapeHtml(relationship.target)}">$content</a>';
    case 'fldSimple':
    case 'smartTag':
    case 'sdt':
    case 'customXml':
    case 'ins':
    case 'moveFrom':
    case 'moveTo':
      return _renderChildren(element, context, styles);
    case 'proofErr':
    case 'bookmarkStart':
    case 'bookmarkEnd':
      return '';
    default:
      return _renderChildren(element, context, styles);
  }
}

String _renderChildren(
  final XmlElement parent,
  final _RenderContext context,
  final Map<String, DocxStyle> styles,
) {
  final output = StringBuffer();
  for (final child in parent.children.whereType<XmlElement>()) {
    output.write(_renderInline(child, context, styles));
  }

  return output.toString();
}

String _renderRun(final XmlElement run, final _RenderContext context) {
  final properties = docxChild(run, 'rPr');
  final output = StringBuffer();
  for (final child in run.children.whereType<XmlElement>()) {
    switch (child.name.local) {
      case 'rPr':
        break;
      case 't':
      case 'delText':
        output.write(_escapeHtml(child.innerText));
      case 'tab':
        output.write('&#9;');
      case 'br':
      case 'cr':
        output.write('<br/>');
      case 'noBreakHyphen':
        output.write('&#8209;');
      case 'softHyphen':
        output.write('&#173;');
      case 'drawing':
      case 'pict':
      case 'object':
        output.write(_renderImage(child, context));
      case 'sym':
        final char = docxAttribute(child, 'char');
        if (char != null && char.length >= 4) {
          final value = int.tryParse(char.substring(char.length - 4), radix: 16);
          if (value != null) output.write(_escapeHtml(String.fromCharCode(value)));
        }
    }
  }

  if (output.isEmpty) return '';

  var content = output.toString();
  if (_onOff(properties, 'b')) content = '<strong>$content</strong>';
  if (_onOff(properties, 'i')) content = '<em>$content</em>';
  if (_onOff(properties, 'u')) content = '<u>$content</u>';
  if (_onOff(properties, 'strike')) content = '<del>$content</del>';

  final vertical = docxAttribute(docxChild(properties, 'vertAlign'), 'val');
  if (vertical == 'superscript') content = '<sup>$content</sup>';
  if (vertical == 'subscript') content = '<sub>$content</sub>';

  final styles = <String>[];
  final color = docxAttribute(docxChild(properties, 'color'), 'val');
  if (color != null && color.toLowerCase() != 'auto' && _isHexColor(color)) {
    styles.add('color:#${color.toLowerCase()}');
  }
  final highlight = docxAttribute(docxChild(properties, 'highlight'), 'val');
  if (highlight != null) styles.add('background-color:${_highlightColor(highlight)}');
  final size = double.tryParse(docxAttribute(docxChild(properties, 'sz'), 'val') ?? '');
  if (size != null && size > 0) styles.add('font-size:${size / 2}pt');
  if (_onOff(properties, 'smallCaps')) styles.add('font-variant:small-caps');

  final rtl = _onOff(properties, 'rtl');
  if (styles.isNotEmpty || rtl) {
    final attributes = <String>[];
    if (styles.isNotEmpty) attributes.add('style="${_escapeHtml(styles.join(';'))}"');
    if (rtl) attributes.add('dir="rtl"');
    content = '<span ${attributes.join(' ')}>$content</span>';
  }

  return content;
}

String _renderImage(final XmlElement container, final _RenderContext context) {
  String? relationshipId;
  for (final element in container.descendants.whereType<XmlElement>()) {
    if (element.name.local != 'blip' && element.name.local != 'imagedata') continue;
    relationshipId = docxAttribute(element, 'embed') ?? docxAttribute(element, 'id');
    if (relationshipId != null) break;
  }
  if (relationshipId == null) return '';

  final relationship = context.relationships[relationshipId];
  if (relationship == null || relationship.external) return '';
  context.referencedImages.add(relationship.target);
  final source = relativeDocxPartPath(context.documentPath, relationship.target);
  final alt = _imageAlt(container);

  return '<img src="${_escapeHtml(source)}" alt="${_escapeHtml(alt)}" />';
}

String _imageAlt(final XmlElement container) {
  for (final element in container.descendants.whereType<XmlElement>()) {
    if (element.name.local != 'docPr') continue;
    final descr = docxAttribute(element, 'descr');
    if (descr != null && descr.isNotEmpty) return descr;
    final name = docxAttribute(element, 'name');
    if (name != null && name.isNotEmpty) return name;
  }

  return 'Image';
}

String _renderTable(
  final XmlElement table,
  final _RenderContext context,
  final Map<String, DocxStyle> styles,
) {
  final output = StringBuffer('<table class="docx-table"><tbody>');
  for (final row in table.children.whereType<XmlElement>()) {
    if (row.name.local != 'tr') continue;
    output.write('<tr>');
    for (final cell in row.children.whereType<XmlElement>()) {
      if (cell.name.local != 'tc') continue;
      final cellProperties = docxChild(cell, 'tcPr');
      final span = int.tryParse(docxAttribute(docxChild(cellProperties, 'gridSpan'), 'val') ?? '');
      final attributes = span != null && span > 1 ? ' colspan="$span"' : '';
      output.write('<td$attributes>');
      var rendered = false;
      for (final child in cell.children.whereType<XmlElement>()) {
        if (child.name.local == 'tcPr') continue;
        if (child.name.local == 'p') {
          output.write(_renderParagraph(child, context, styles));
          rendered = true;
        } else if (child.name.local == 'tbl') {
          output.write(_renderTable(child, context, styles));
          rendered = true;
        }
      }
      if (!rendered) output.write('&nbsp;');
      output.write('</td>');
    }
    output.write('</tr>');
  }
  output.write('</tbody></table>');

  return output.toString();
}

int? _headingLevel(final XmlElement paragraph, final Map<String, DocxStyle> styles) {
  final properties = docxChild(paragraph, 'pPr');
  final styleId = docxAttribute(docxChild(properties, 'pStyle'), 'val');
  final style = styleId == null ? null : styles[styleId];
  final styleName = style?.name ?? styleId ?? '';
  final match = RegExp(r'heading\s*([1-9])', caseSensitive: false).firstMatch(styleName);
  if (match != null) return _clampHeading(int.parse(match.group(1)!));
  if (style?.outlineLevel != null) return _clampHeading(style!.outlineLevel! + 1);

  final directOutline = int.tryParse(
    docxAttribute(docxChild(properties, 'outlineLvl'), 'val') ?? '',
  );
  if (directOutline != null) return _clampHeading(directOutline + 1);

  return null;
}

int _clampHeading(final int value) => value < 1
    ? 1
    : value > 6
    ? 6
    : value;

_ListInfo? _listInfo(final XmlElement paragraph, final DocxNumbering numbering) {
  final properties = docxChild(paragraph, 'pPr');
  final numProperties = docxChild(properties, 'numPr');
  if (numProperties == null) return null;
  final numId = int.tryParse(docxAttribute(docxChild(numProperties, 'numId'), 'val') ?? '');
  if (numId == null) return null;
  final level = int.tryParse(docxAttribute(docxChild(numProperties, 'ilvl'), 'val') ?? '') ?? 0;
  final format = numbering.format(numId, level);
  final kind = format == 'bullet' || format == 'none' ? 'ul' : 'ol';

  return _ListInfo(numId: numId, level: level, kind: kind);
}

bool _onOff(final XmlElement? parent, final String localName) {
  final value = docxAttribute(docxChild(parent, localName), 'val');
  if (value == null) return docxChild(parent, localName) != null;
  return value != '0' && value.toLowerCase() != 'false' && value.toLowerCase() != 'off';
}

bool _isHexColor(final String value) => RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value);

String _highlightColor(final String value) {
  const colors = <String, String>{
    'black': '#000000',
    'blue': '#0000ff',
    'cyan': '#00ffff',
    'darkBlue': '#00008b',
    'darkCyan': '#008b8b',
    'darkGray': '#a9a9a9',
    'darkGreen': '#006400',
    'darkMagenta': '#8b008b',
    'darkRed': '#8b0000',
    'darkYellow': '#b8860b',
    'gray': '#808080',
    'green': '#008000',
    'lightGray': '#d3d3d3',
    'magenta': '#ff00ff',
    'red': '#ff0000',
    'white': '#ffffff',
    'yellow': '#ffff00',
  };

  return colors[value] ?? value;
}

String _escapeHtml(final String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

Navigation _htmlNavigation(final String source, {required final String title}) {
  final document = html_parser.parse(source);
  final headings = document.querySelectorAll('h1,h2,h3,h4,h5,h6');
  final roots = <NavPoint>[];
  final stack = <(int, NavPoint)>[];
  var order = 0;
  for (final heading in headings) {
    final label = heading.text.trim();
    if (label.isEmpty) continue;
    final localName = heading.localName ?? 'h1';
    final level = int.tryParse(localName.substring(1)) ?? 1;
    final id = heading.attributes['id'] ?? 'heading-${order + 1}';
    final point = NavPoint(
      classAttribute: localName,
      id: id,
      playOrder: '${order + 1}',
      label: label,
      content: '#$id',
      subNavPoints: <NavPoint>[],
    );
    order++;
    while (stack.isNotEmpty && stack.last.$1 >= level) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      roots.add(point);
    } else {
      stack.last.$2.subNavPoints.add(point);
    }
    stack.add((level, point));
  }

  return Navigation(title: title, navPoints: roots);
}

final class _ListInfo {
  const _ListInfo({required this.numId, required this.level, required this.kind});

  final int numId;
  final int level;
  final String kind;
}

final class _RenderContext {
  _RenderContext({
    required this.documentPath,
    required this.relationships,
    required this.referencedImages,
  });

  final String documentPath;
  final Map<String, DocxRelationship> relationships;
  final Set<String> referencedImages;
  int headingCount = 0;
}
