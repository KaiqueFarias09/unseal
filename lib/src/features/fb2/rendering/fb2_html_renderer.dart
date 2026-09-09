import 'package:xml/xml.dart';

import '../../../foundation/entities/entities.dart';

/// Result of converting the FB2 bodies to XHTML.
class Fb2Bodies {
  /// Creates the converted XHTML, navigation and preserved CSS files.
  const Fb2Bodies(this.files, this.navigation, {this.css = const <TextFile>[]});

  /// Generated XHTML files: `index.html` (main body) plus one file
  /// per named body (`notes.html` for `body name="notes"`).
  final Map<String, String> files;

  /// Table of contents derived from section titles.
  final Navigation navigation;

  /// Stylesheets preserved from the FB2 document.
  final List<TextFile> css;
}

/// Converts FB2 `<body>` elements into XHTML files.
///
/// The main body becomes `index.html`; each named body (typically
/// `notes`) becomes `<name>.html`. Internal `l:href="#id"` links that
/// target ids living in another body are rewritten to that body's
/// file.
Fb2Bodies convertBodies(
  final List<XmlElement> bodies,
  final String title,
  final Map<String, String> binaryExtensions, {
  final List<TextFile> stylesheets = const <TextFile>[],
}) {
  final converter = _BodyConverter(binaryExtensions, stylesheets);

  return converter.convert(bodies, title);
}

/// Preserves root-level FB2 stylesheets as named CSS resources.
List<TextFile> extractFb2Stylesheets(final XmlElement root) {
  final stylesheets = <TextFile>[];
  var index = 0;
  for (final element in root.children.whereType<XmlElement>()) {
    if (element.name.local != 'stylesheet') continue;

    final name = index == 0 ? 'styles.css' : 'styles-$index.css';
    stylesheets.add(TextFile(name: name, type: 'css', path: name, content: element.innerText));
    index++;
  }

  return stylesheets;
}

class _BodyConverter {
  _BodyConverter(this._binaryExtensions, this._stylesheets);

  final Map<String, String> _binaryExtensions;
  final List<TextFile> _stylesheets;

  final Map<String, Set<String>> _idsByFile = <String, Set<String>>{};
  final Map<String, String> _fileByBodyName = <String, String>{};
  final List<XmlElement> _bodies = <XmlElement>[];
  final List<NavPoint> _navPoints = <NavPoint>[];
  final Map<int, List<NavPoint>> _pointsByDepth = <int, List<NavPoint>>{};

  int _playOrder = 0;
  int _sectionCounter = 0;

  late final List<TextFile> _normalizedStylesheets = _stylesheets
      .map(
        (final stylesheet) => TextFile(
          name: stylesheet.name,
          type: stylesheet.type,
          path: stylesheet.path,
          content: _normalizeStylesheetSelectors(stylesheet.content),
        ),
      )
      .toList();

  Fb2Bodies convert(final List<XmlElement> bodies, final String title) {
    _bodies.addAll(bodies);

    // First pass: collect generated ids per file for link resolution.
    final fileNames = <String>[];
    for (var i = 0; i < bodies.length; i++) {
      final name = i == 0 ? 'index.html' : '${_bodyName(bodies[i])}.html';
      _fileByBodyName[_bodyName(bodies[i])] = name;
      fileNames.add(name);
      _idsByFile[name] = <String>{};
      _collectIds(bodies[i], name);
    }
    final files = <String, String>{};
    for (var i = 0; i < bodies.length; i++) {
      final fileName = fileNames[i];
      final html = _convertBody(bodies[i], fileName, title);
      files[fileName] = html;
    }

    return Fb2Bodies(
      files,
      Navigation(title: title, navPoints: _navPoints),
      css: _normalizedStylesheets,
    );
  }

  String _bodyName(final XmlElement body) {
    final name = body.getAttribute('name');
    if (name == null || name.isEmpty || name == 'main') return 'notes';

    return name;
  }

  void _collectIds(final XmlElement element, final String fileName) {
    final id = element.getAttribute('id');
    if (id != null && id.isNotEmpty) _idsByFile[fileName]!.add(id);
    for (final child in element.children.whereType<XmlElement>()) {
      _collectIds(child, fileName);
    }
  }

  String _convertBody(final XmlElement body, final String fileName, final String title) {
    final buffer = StringBuffer();
    buffer.write('<!DOCTYPE html>\n<html>\n<head>');
    buffer.write('<meta charset="utf-8"/>');
    buffer.write('<title>${_escapeText(title)}</title>');
    for (final stylesheet in _normalizedStylesheets) {
      buffer.write(
        '<link rel="stylesheet" type="text/css" href="${_escapeAttr(stylesheet.name)}"/>',
      );
    }
    buffer.write('</head>\n<body>\n');
    if (fileName == 'index.html') {
      _convertChildren(body, buffer, fileName, 2, inToc: true);
    } else {
      buffer.write('<section class="body-notes">');
      _convertChildren(body, buffer, fileName, 3, inToc: false);
      buffer.write('</section>');
    }
    buffer.write('\n</body>\n</html>');

    return buffer.toString();
  }

  void _convertChildren(
    final XmlElement element,
    final StringBuffer out,
    final String fileName,
    final int headingLevel, {
    required final bool inToc,
  }) {
    for (final child in element.children.whereType<XmlElement>()) {
      _convertElement(child, out, fileName, headingLevel, inToc);
    }
  }

  // The FB2 vocabulary is intentionally handled in one dispatch so every
  // block element shares the same link, image and inline conversion context.
  // ignore: cyclomatic_complexity
  void _convertElement(
    final XmlElement element,
    final StringBuffer out,
    final String fileName,
    final int headingLevel,
    final bool inToc,
  ) {
    final name = element.name.local;
    switch (name) {
      case 'section':
        _sectionCounter++;
        final id = element.getAttribute('id') ?? 'fb2-section-$_sectionCounter';
        out.write('<section id="${_escapeAttr(id)}">');
        var childLevel = headingLevel + 1;
        if (childLevel > 6) childLevel = 6;
        _convertWithToc(element, out, fileName, childLevel, id, inToc);
        out.write('</section>');
      case 'title':
        final level = headingLevel.clamp(1, 6);
        var id = '';
        final parent = element.parent;
        if (parent is XmlElement && parent.name.local == 'section') {
          id = parent.getAttribute('id') ?? '';
        }
        final anchor = id.isEmpty ? '' : ' id="title-$id"';
        out.write('<h$level$anchor class="title">');
        _convertInlineChildren(element, out, fileName);
        out.write('</h$level>');
      case 'subtitle':
        out.write('<p class="subtitle"><b>');
        _convertInlineChildren(element, out, fileName);
        out.write('</b></p>');
      case 'epigraph':
        out.write('<blockquote class="epigraph">');
        _convertChildren(element, out, fileName, headingLevel, inToc: inToc);
        out.write('</blockquote>');
      case 'cite':
        out.write('<blockquote>');
        _convertChildren(element, out, fileName, headingLevel, inToc: inToc);
        out.write('</blockquote>');
      case 'text-author':
        out.write('<p class="text-author">');
        _convertInlineChildren(element, out, fileName);
        out.write('</p>');
      case 'poem':
        out.write('<blockquote class="poem">');
        _convertChildren(element, out, fileName, headingLevel, inToc: inToc);
        out.write('</blockquote>');
      case 'stanza':
        out.write('<p class="stanza">');
        for (final child in element.children.whereType<XmlElement>()) {
          if (child.name.local == 'v') {
            _convertInlineChildren(child, out, fileName);
            out.write('<br/>');
            continue;
          }

          _convertElement(child, out, fileName, headingLevel, inToc);
        }
        out.write('</p>');
      case 'empty-line':
        out.write('<br/>');
      case 'p':
        out.write('<p>');
        _convertInlineChildren(element, out, fileName);
        out.write('</p>');
      case 'image':
        _writeImage(element, out);
      case 'table':
        out.write('<table>');
        _convertChildren(element, out, fileName, headingLevel, inToc: inToc);
        out.write('</table>');
      case 'tr':
        out.write('<tr>');
        _convertChildren(element, out, fileName, headingLevel, inToc: inToc);
        out.write('</tr>');
      case 'td':
        out.write('<td>');
        _convertChildren(element, out, fileName, headingLevel, inToc: inToc);
        out.write('</td>');
      case 'th':
        out.write('<th>');
        _convertChildren(element, out, fileName, headingLevel, inToc: inToc);
        out.write('</th>');
      case 'style':
        _writeStyle(element, out, fileName);
      default:
        // Unknown block-ish elements: keep their text content.
        if (element.children.whereType<XmlElement>().isEmpty) {
          out.write('<p>');
          out.write(_escapeText(element.innerText));
          out.write('</p>');
        } else {
          _convertChildren(element, out, fileName, headingLevel, inToc: inToc);
        }
    }
  }

  void _convertInline(final XmlElement element, final StringBuffer out, final String fileName) {
    switch (element.name.local) {
      case 'emphasis':
        out.write('<em>');
        _convertInlineChildren(element, out, fileName);
        out.write('</em>');
      case 'strong':
        out.write('<strong>');
        _convertInlineChildren(element, out, fileName);
        out.write('</strong>');
      case 'strikethrough':
        out.write('<s>');
        _convertInlineChildren(element, out, fileName);
        out.write('</s>');
      case 'sub':
        out.write('<sub>');
        _convertInlineChildren(element, out, fileName);
        out.write('</sub>');
      case 'sup':
        out.write('<sup>');
        _convertInlineChildren(element, out, fileName);
        out.write('</sup>');
      case 'code':
        out.write('<code>');
        _convertInlineChildren(element, out, fileName);
        out.write('</code>');
      case 'a':
        _writeLink(element, out, fileName);
      case 'image':
        _writeImage(element, out);
      case 'style':
        _writeStyle(element, out, fileName);
      default:
        _convertInlineChildren(element, out, fileName);
    }
  }

  void _convertInlineChildren(
    final XmlElement element,
    final StringBuffer out,
    final String fileName,
  ) {
    for (final child in element.children) {
      if (child is XmlText) {
        out.write(_escapeText(child.value));
      } else if (child is XmlElement) {
        _convertInline(child, out, fileName);
      } else if (child is XmlCDATA) {
        out.write(_escapeText(child.value));
      }
    }
  }

  void _convertWithToc(
    final XmlElement section,
    final StringBuffer out,
    final String fileName,
    final int headingLevel,
    final String sectionId,
    final bool inToc,
  ) {
    // Register the point before converting children so nested
    // sections find their parent (pre-order traversal).
    if (inToc) {
      final titleElement = _firstDescendant(section, 'title');
      if (titleElement != null) {
        final label = titleElement.innerText.trim();
        if (label.isNotEmpty) {
          _playOrder++;
          final point = NavPoint(
            classAttribute: 'section',
            id: sectionId,
            playOrder: '$_playOrder',
            label: label,
            content: '$fileName#$sectionId',
            subNavPoints: <NavPoint>[],
          );
          final depth = headingLevel - 3 < 0 ? 0 : headingLevel - 3;

          if (depth == 0 || _pointsByDepth[depth - 1] == null) {
            _navPoints.add(point);
          } else {
            _pointsByDepth[depth - 1]!.last.subNavPoints.add(point);
          }
          _pointsByDepth.putIfAbsent(depth, () => <NavPoint>[]).add(point);
        }
      }
    }
    final buffer = StringBuffer();
    _convertChildren(section, buffer, fileName, headingLevel, inToc: inToc);
    out.write(buffer);
  }

  XmlElement? _firstDescendant(final XmlElement root, final String localName) {
    for (final child in root.children.whereType<XmlElement>()) {
      if (child.name.local == localName) return child;

      final nested = _firstDescendant(child, localName);
      if (nested != null) return nested;
    }

    return null;
  }

  String _resolveInternalLink(final String fromFile, final String target) {
    if (_idsByFile[fromFile]?.contains(target) == true) return '#$target';

    for (final entry in _idsByFile.entries) {
      if (entry.key != fromFile && entry.value.contains(target)) return '${entry.key}#$target';
    }

    return '#$target';
  }

  void _writeImage(final XmlElement element, final StringBuffer out) {
    final href =
        element.getAttribute('href', namespace: 'http://www.w3.org/1999/xlink') ??
        element.getAttribute('l:href') ??
        '';
    if (!href.startsWith('#') || href.length < 2) return;

    final id = href.substring(1);
    final name = _binaryExtensions[id] ?? id;
    out.write('<img src="${_escapeAttr(name)}" alt="${_escapeAttr(id)}"/>');
  }

  void _writeStyle(final XmlElement element, final StringBuffer out, final String fileName) {
    final className = _fb2StyleClassName(element.getAttribute('name'));
    if (className == null) {
      _convertInlineChildren(element, out, fileName);

      return;
    }

    out.write('<span class="${_escapeAttr(className)}">');
    _convertInlineChildren(element, out, fileName);
    out.write('</span>');
  }

  void _writeLink(final XmlElement element, final StringBuffer out, final String fileName) {
    final href =
        element.getAttribute('href', namespace: 'http://www.w3.org/1999/xlink') ??
        element.getAttribute('l:href') ??
        element.getAttribute('href') ??
        '';
    if (href.startsWith('#') && href.length > 1) {
      final target = href.substring(1);
      final resolved = _resolveInternalLink(fileName, target);

      out.write('<a href="${_escapeAttr(resolved)}">');
      _convertInlineChildren(element, out, fileName);
      out.write('</a>');
    } else if (href.isNotEmpty) {
      out.write('<a href="${_escapeAttr(href)}">');
      _convertInlineChildren(element, out, fileName);
      out.write('</a>');
    } else {
      final type = element.getAttribute('type') ?? '';
      out.write('<span class="fb2-a" data-type="${_escapeAttr(type)}">');
      _convertInlineChildren(element, out, fileName);
      out.write('</span>');
    }
  }
}

String _escapeText(final String raw) =>
    raw.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _escapeAttr(final String raw) => _escapeText(raw).replaceAll('"', '&quot;');

final RegExp _namedStyleSelector = RegExp(
  r'''style\s*\[\s*name\s*=\s*(?:(['"])([^'"]*)\1|([^\]\s]+))\s*\]''',
  caseSensitive: false,
);

String _normalizeStylesheetSelectors(final String css) {
  return css.replaceAllMapped(_namedStyleSelector, (final match) {
    final name = match.group(2) ?? match.group(3) ?? '';
    final className = _fb2StyleClassName(name);

    return className == null ? match.group(0)! : '.$className';
  });
}

String? _fb2StyleClassName(final String? rawName) {
  final name = rawName?.trim() ?? '';
  if (name.isEmpty) return null;

  final sanitized = name.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-');
  if (sanitized.isEmpty) return null;
  if (RegExp(r'^[A-Za-z_-]').hasMatch(sanitized)) return sanitized;

  return 'fb2-style-$sanitized';
}
