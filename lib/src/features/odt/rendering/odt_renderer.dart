import 'package:e_livre/src/features/odt/container/odt_package.dart';
import 'package:e_livre/src/features/odt/exceptions/exceptions.dart';
import 'package:e_livre/src/features/odt/styles/odt_styles.dart';
import 'package:e_livre/src/foundation/text/document_encoding.dart';
import 'package:xml/xml.dart';

import '../../../foundation/archive/archive_access.dart';

/// XHTML output and the package image paths referenced by it.
final class OdtRenderResult {
  /// Creates a completed ODT render result.
  const OdtRenderResult({required this.xhtml, required this.referencedImages});

  /// Complete XHTML document body.
  final String xhtml;

  /// Normalized package paths referenced by rendered image elements.
  final Set<String> referencedImages;
}

/// Renders the document body of [package] using its resolved [styles].
OdtRenderResult renderOdtContent(
  final OdtPackage package,
  final OdtStyleCatalog styles, {
  final String? title,
}) {
  final body = odtFindDescendant(package.content.rootElement, 'body');
  final text = odtFindChild(body, 'text');
  if (text == null) {
    throw const InvalidOdtXmlException('content.xml', 'office:body has no office:text');
  }

  final referencedImages = <String>{};
  final context = _RenderContext(styles, referencedImages);
  final output = StringBuffer()
    ..write('<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head>')
    ..write('<meta charset="utf-8"/>')
    ..write('<title>${escapeHtml(title ?? '')}</title>')
    ..write('</head><body>');

  for (final child in text.children.whereType<XmlElement>()) {
    output.write(_renderBlock(child, context));
  }
  output.write('</body></html>');

  return OdtRenderResult(xhtml: output.toString(), referencedImages: referencedImages);
}

String _renderBlock(final XmlElement element, final _RenderContext context) {
  switch (element.name.local) {
    case 'h':
      final level = _headingLevel(element, context.styles);
      return '<h$level>${_renderInlineChildren(element, context)}</h$level>';
    case 'p':
      return '<p>${_renderInlineChildren(element, context)}</p>';
    case 'list':
      return _renderList(element, context);
    case 'table':
      return _renderTable(element, context);
    case 'section':
    case 'tracked-changes':
    case 'change-start':
    case 'change-end':
    case 'annotation':
      return _renderBlockChildren(element, context);
    default:
      return _renderBlockChildren(element, context);
  }
}

String _renderBlockChildren(final XmlElement parent, final _RenderContext context) {
  final output = StringBuffer();
  for (final child in parent.children.whereType<XmlElement>()) {
    output.write(_renderBlock(child, context));
  }

  return output.toString();
}

String _renderList(final XmlElement list, final _RenderContext context) {
  final kind = context.styles.listKind(odtAttribute(list, 'style-name'));
  final output = StringBuffer('<$kind>');
  for (final item in list.children.whereType<XmlElement>()) {
    if (item.name.local != 'list-item') continue;
    output.write('<li>');
    for (final child in item.children.whereType<XmlElement>()) {
      output.write(_renderBlock(child, context));
    }
    output.write('</li>');
  }
  output.write('</$kind>');

  return output.toString();
}

String _renderTable(final XmlElement table, final _RenderContext context) {
  final output = StringBuffer('<table><tbody>');
  for (final row in table.children.whereType<XmlElement>()) {
    if (row.name.local != 'table-row') continue;
    output.write('<tr>');
    for (final cell in row.children.whereType<XmlElement>()) {
      if (cell.name.local != 'table-cell') continue;
      final span = int.tryParse(odtAttribute(cell, 'number-columns-spanned') ?? '');
      final attributes = span != null && span > 1 ? ' colspan="$span"' : '';
      output.write('<td$attributes>');
      for (final child in cell.children.whereType<XmlElement>()) {
        output.write(_renderBlock(child, context));
      }
      output.write('</td>');
    }
    output.write('</tr>');
  }
  output.write('</tbody></table>');

  return output.toString();
}

String _renderInlineChildren(final XmlElement parent, final _RenderContext context) {
  final output = StringBuffer();
  for (final child in parent.children) {
    if (child is XmlElement) {
      output.write(_renderInline(child, context));
    } else if (child is XmlText) {
      output.write(escapeHtml(child.value));
    }
  }

  return output.toString();
}

String _renderInline(final XmlElement element, final _RenderContext context) {
  switch (element.name.local) {
    case 'span':
      final content = _renderInlineChildren(element, context);
      return context.styles.wrap(odtAttribute(element, 'style-name'), content);
    case 'a':
      final content = _renderInlineChildren(element, context);
      final href = odtAttribute(element, 'href');
      return href == null || href.isEmpty
          ? content
          : '<a href="${_escapeAttribute(href)}">$content</a>';
    case 's':
      final count = int.tryParse(odtAttribute(element, 'c') ?? '1') ?? 1;
      return escapeHtml(' ' * (count < 1 ? 1 : count));
    case 'tab':
      return '&#9;';
    case 'line-break':
      return '<br/>';
    case 'soft-page-break':
      return '<hr/>';
    case 'frame':
      return _renderFrame(element, context);
    case 'annotation':
    case 'change-start':
    case 'change-end':
      return '';
    default:
      return _renderInlineChildren(element, context);
  }
}

String _renderFrame(final XmlElement frame, final _RenderContext context) {
  final image = odtFindDescendant(frame, 'image');
  if (image == null) return _renderInlineChildren(frame, context);
  final href = odtAttribute(image, 'href');
  if (href == null || href.isEmpty) return '';
  final path = normalizeZipPath(_decodeResourcePath(href));
  if (path.isEmpty) return '';
  context.referencedImages.add(path);
  final title = odtAttribute(frame, 'name') ?? 'Image';

  return '<img src="${_escapeAttribute(path)}" alt="${escapeHtml(title)}" />';
}

String _decodeResourcePath(final String href) {
  try {
    return Uri.decodeComponent(href);
  } on FormatException {
    return href;
  }
}

int _headingLevel(final XmlElement element, final OdtStyleCatalog styles) {
  final outline = int.tryParse(odtAttribute(element, 'outline-level') ?? '');
  if (outline != null) return _clampHeading(outline);
  final styleName = odtAttribute(element, 'style-name');
  final match = RegExp(
    r'heading\s*([1-9])',
    caseSensitive: false,
  ).firstMatch(styles.textStyleName(styleName) ?? styleName ?? '');
  if (match != null) return _clampHeading(int.parse(match.group(1)!));

  return 1;
}

int _clampHeading(final int value) => value < 1
    ? 1
    : value > 6
    ? 6
    : value;

String _escapeAttribute(final String value) => escapeHtml(value).replaceAll('&#47;', '/');

final class _RenderContext {
  const _RenderContext(this.styles, this.referencedImages);

  final OdtStyleCatalog styles;
  final Set<String> referencedImages;
}
