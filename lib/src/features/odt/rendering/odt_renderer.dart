part of '../parse_odt_book.dart';

final class _RenderedOdt {
  const _RenderedOdt({required this.xhtml, required this.navigation});

  final String xhtml;

  final Navigation navigation;
}

/// Renders the document body of [package] using its resolved [styles].
_RenderedOdt _renderOdtContent(
  final _OdtPackage package,
  final _OdtStyleCatalog styles, {
  final String? title,
}) {
  final body = _odtFindDescendant(package.content.rootElement, 'body');
  final text = _odtFindChild(body, 'text');
  if (text == null) {
    throw const InvalidOdtXmlException('content.xml', 'office:body has no office:text');
  }

  final context = _RenderContext(styles);
  final output = StringBuffer()
    ..write('<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head>')
    ..write('<meta charset="utf-8"/>')
    ..write('<title>${escapeHtml(title ?? '')}</title>')
    ..write('</head><body>');
  for (final child in text.children.whereType<XmlElement>()) {
    output.write(_renderBlock(child, context));
  }
  output.write('</body></html>');

  return _RenderedOdt(
    xhtml: output.toString(),
    navigation: Navigation(title: title ?? '', navPoints: context.navigation),
  );
}

String _renderBlock(final XmlElement element, final _RenderContext context) {
  switch (element.name.local) {
    case 'h':
      final level = _headingLevel(element, context.styles);
      final content = _renderInlineChildren(element, context);
      final id = context.addHeading(level, element.innerText.trim());

      return '<h$level id="$id">$content</h$level>';
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
  final kind = context.styles.listKind(_odtAttribute(list, 'style-name'));
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

      final span = int.tryParse(_odtAttribute(cell, 'number-columns-spanned') ?? '');
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

      return context.styles.wrap(_odtAttribute(element, 'style-name'), content);
    case 'a':
      final content = _renderInlineChildren(element, context);
      final href = _odtAttribute(element, 'href');

      return href == null || href.isEmpty
          ? content
          : '<a href="${_escapeAttribute(href)}">$content</a>';
    case 's':
      final count = int.tryParse(_odtAttribute(element, 'c') ?? '1') ?? 1;

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
  final image = _odtFindDescendant(frame, 'image');
  if (image == null) return _renderInlineChildren(frame, context);

  final href = _odtAttribute(image, 'href');
  if (href == null || href.isEmpty) return '';

  final path = normalizeZipPath(_decodeResourcePath(href));
  if (path.isEmpty) return '';

  final title = _odtAttribute(frame, 'name') ?? 'Image';

  return '<img src="${_escapeAttribute(path)}" alt="${_escapeAttribute(title)}" />';
}

String _decodeResourcePath(final String href) {
  try {
    return Uri.decodeComponent(href);
  } on FormatException {
    return href;
  }
}

int _headingLevel(final XmlElement element, final _OdtStyleCatalog styles) {
  final outline = int.tryParse(_odtAttribute(element, 'outline-level') ?? '');
  if (outline != null) return _clampHeading(outline);

  final styleName = _odtAttribute(element, 'style-name');
  final match = RegExp(
    r'heading(?:\s|_20_)*([1-9])',
    caseSensitive: false,
  ).firstMatch(styles.textStyleName(styleName) ?? styleName ?? '');
  if (match != null) return _clampHeading(int.parse(match.group(1)!));

  return 1;
}

int _clampHeading(final int value) {
  if (value < 1) return 1;
  if (value > 6) return 6;

  return value;
}

String _escapeAttribute(final String value) => escapeHtml(value).replaceAll('&#47;', '/');

final class _RenderContext {
  _RenderContext(this.styles);

  final _OdtStyleCatalog styles;
  final List<NavPoint> navigation = <NavPoint>[];
  final List<(int, NavPoint)> _navigationStack = <(int, NavPoint)>[];
  var _headingCount = 0;

  String addHeading(final int level, final String label) {
    _headingCount++;
    final id = 'heading-$_headingCount';
    if (label.isEmpty) return id;

    final point = NavPoint(
      classAttribute: 'h$level',
      id: id,
      playOrder: '$_headingCount',
      label: label,
      content: '#$id',
      subNavPoints: <NavPoint>[],
    );
    while (_navigationStack.isNotEmpty && _navigationStack.last.$1 >= level) {
      _navigationStack.removeLast();
    }
    if (_navigationStack.isEmpty) {
      navigation.add(point);
    } else {
      _navigationStack.last.$2.subNavPoints.add(point);
    }
    _navigationStack.add((level, point));

    return id;
  }
}
