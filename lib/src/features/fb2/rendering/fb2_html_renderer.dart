part of '../parse_fb2_book.dart';

/// Result of converting the FB2 bodies to XHTML.
final class _Fb2Bodies {
  /// Creates the converted XHTML, navigation and preserved CSS files.
  const _Fb2Bodies(this.files, this.navigation, {this.css = const <TextFile>[]});

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
_Fb2Bodies _convertBodies(
  final List<XmlElement> bodies,
  final String title,
  final Map<String, String> binaryExtensions, {
  final List<TextFile> stylesheets = const <TextFile>[],
}) {
  final converter = _BodyConverter(binaryExtensions, stylesheets);

  return converter.convert(bodies, title);
}

/// Preserves root-level FB2 stylesheets as named CSS resources.
List<TextFile> _extractFb2Stylesheets(final XmlElement root) {
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
  final List<NavPoint> _navPoints = <NavPoint>[];
  final List<NavPoint> _navigationStack = <NavPoint>[];

  int _playOrder = 0;
  int _sectionCounter = 0;

  late final List<TextFile> _normalizedStylesheets = _stylesheets.map((final stylesheet) {
    return TextFile(
      name: stylesheet.name,
      type: stylesheet.type,
      path: stylesheet.path,
      content: _normalizeStylesheetSelectors(stylesheet.content),
    );
  }).toList();

  _Fb2Bodies convert(final List<XmlElement> bodies, final String title) {
    // First pass: collect generated ids per file for link resolution.
    final fileNames = _bodyFileNames(bodies);
    for (var i = 0; i < bodies.length; i++) {
      final fileName = fileNames[i];
      _idsByFile[fileName] = <String>{};
      _collectIds(bodies[i], fileName);
    }

    final files = <String, String>{};
    for (var i = 0; i < bodies.length; i++) {
      final fileName = fileNames[i];
      final html = _convertBody(bodies[i], fileName, title);
      files[fileName] = html;
    }

    return _Fb2Bodies(
      files,
      Navigation(title: title, navPoints: _navPoints),
      css: _normalizedStylesheets,
    );
  }

  List<String> _bodyFileNames(final List<XmlElement> bodies) {
    final names = <String>['index.html'];
    final used = <String>{'index.html'};
    for (var i = 1; i < bodies.length; i++) {
      final rawName = bodies[i].getAttribute('name');
      final stem = _safeBodyFileStem(rawName);
      var fileName = '$stem.html';
      var suffix = 2;
      while (!used.add(fileName)) {
        fileName = '$stem-$suffix.html';
        suffix++;
      }
      names.add(fileName);
    }

    return names;
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
    switch (element.name.local) {
      case 'section':
        _convertSection(element, out, fileName, headingLevel, inToc);
      case 'title':
        _convertTitle(element, out, fileName, headingLevel);
      case 'subtitle':
        _convertSubtitle(element, out, fileName);
      case 'epigraph':
        _convertWrappedChildren(
          element,
          out,
          fileName,
          headingLevel,
          inToc,
          '<blockquote class="epigraph">',
          '</blockquote>',
        );
      case 'cite':
        _convertWrappedChildren(
          element,
          out,
          fileName,
          headingLevel,
          inToc,
          '<blockquote>',
          '</blockquote>',
        );
      case 'text-author':
        _convertInlineWrapped(element, out, fileName, '<p class="text-author">', '</p>');
      case 'poem':
        _convertWrappedChildren(
          element,
          out,
          fileName,
          headingLevel,
          inToc,
          '<blockquote class="poem">',
          '</blockquote>',
        );
      case 'stanza':
        _convertStanza(element, out, fileName, headingLevel, inToc);
      case 'empty-line':
        out.write('<br/>');
      case 'p':
        _convertInlineWrapped(element, out, fileName, '<p>', '</p>');
      case 'image':
        _writeImage(element, out);
      case 'table':
        _convertWrappedChildren(element, out, fileName, headingLevel, inToc, '<table>', '</table>');
      case 'tr':
        _convertWrappedChildren(element, out, fileName, headingLevel, inToc, '<tr>', '</tr>');
      case 'td':
        _convertWrappedChildren(element, out, fileName, headingLevel, inToc, '<td>', '</td>');
      case 'th':
        _convertWrappedChildren(element, out, fileName, headingLevel, inToc, '<th>', '</th>');
      case 'style':
        _writeStyle(element, out, fileName);
      default:
        _convertUnknown(element, out, fileName, headingLevel, inToc);
    }
  }

  void _convertSection(
    final XmlElement element,
    final StringBuffer out,
    final String fileName,
    final int headingLevel,
    final bool inToc,
  ) {
    final id = element.getAttribute('id') ?? _nextSectionId(fileName);
    out.write('<section id="${_escapeAttr(id)}">');
    final childLevel = (headingLevel + 1).clamp(1, 6);
    _convertWithToc(element, out, fileName, childLevel, id, inToc);
    out.write('</section>');
  }

  void _convertTitle(
    final XmlElement element,
    final StringBuffer out,
    final String fileName,
    final int headingLevel,
  ) {
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
  }

  void _convertSubtitle(final XmlElement element, final StringBuffer out, final String fileName) {
    _convertInlineWrapped(element, out, fileName, '<p class="subtitle"><b>', '</b></p>');
  }

  void _convertInlineWrapped(
    final XmlElement element,
    final StringBuffer out,
    final String fileName,
    final String opening,
    final String closing,
  ) {
    out.write(opening);
    _convertInlineChildren(element, out, fileName);
    out.write(closing);
  }

  void _convertWrappedChildren(
    final XmlElement element,
    final StringBuffer out,
    final String fileName,
    final int headingLevel,
    final bool inToc,
    final String opening,
    final String closing,
  ) {
    out.write(opening);
    _convertChildren(element, out, fileName, headingLevel, inToc: inToc);
    out.write(closing);
  }

  void _convertStanza(
    final XmlElement element,
    final StringBuffer out,
    final String fileName,
    final int headingLevel,
    final bool inToc,
  ) {
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
  }

  void _convertUnknown(
    final XmlElement element,
    final StringBuffer out,
    final String fileName,
    final int headingLevel,
    final bool inToc,
  ) {
    // Unknown block-ish elements: keep their text content.
    if (element.children.whereType<XmlElement>().isEmpty) {
      out.write('<p>');
      out.write(_escapeText(element.innerText));
      out.write('</p>');
    } else {
      _convertChildren(element, out, fileName, headingLevel, inToc: inToc);
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
    NavPoint? point;
    if (inToc) {
      final titleElement = section.findElements('title').firstOrNull;
      if (titleElement != null) {
        final label = titleElement.innerText.trim();
        if (label.isNotEmpty) {
          _playOrder++;
          point = NavPoint(
            classAttribute: 'section',
            id: sectionId,
            playOrder: '$_playOrder',
            label: label,
            content: '$fileName#$sectionId',
            subNavPoints: <NavPoint>[],
          );

          if (_navigationStack.isEmpty) {
            _navPoints.add(point);
          } else {
            _navigationStack.last.subNavPoints.add(point);
          }
          _navigationStack.add(point);
        }
      }
    }

    _convertChildren(section, out, fileName, headingLevel, inToc: inToc);
    if (point != null) _navigationStack.removeLast();
  }

  String _nextSectionId(final String fileName) {
    final ids = _idsByFile[fileName]!;
    String id;
    do {
      _sectionCounter++;
      id = 'fb2-section-$_sectionCounter';
    } while (ids.contains(id));
    ids.add(id);

    return id;
  }

  String _resolveInternalLink(final String fromFile, final String target) {
    if (_idsByFile[fromFile]?.contains(target) == true) return '#$target';

    for (final entry in _idsByFile.entries) {
      if (entry.key != fromFile && entry.value.contains(target)) return '${entry.key}#$target';
    }

    return '#$target';
  }

  void _writeImage(final XmlElement element, final StringBuffer out) {
    final href = _xlinkHref(element) ?? '';
    if (!href.startsWith('#') || href.length < 2) return;

    final id = href.substring(1);
    final name = _binaryExtensions[id];
    if (name == null) return;

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
    final href = _xlinkHref(element) ?? '';
    if (href.startsWith('#') && href.length > 1) {
      final target = href.substring(1);
      final resolved = _resolveInternalLink(fileName, target);

      out.write('<a href="${_escapeAttr(resolved)}">');
      _convertInlineChildren(element, out, fileName);
      out.write('</a>');
    } else if (_isSafeExternalHref(href)) {
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

String _safeBodyFileStem(final String? rawName) {
  final normalized = rawName?.trim().toLowerCase() ?? '';
  final sanitized = normalized
      .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'^[._-]+|[._-]+$'), '');
  if (sanitized.isEmpty || sanitized == 'main') return 'notes';

  return sanitized;
}

bool _isSafeExternalHref(final String href) {
  if (href.isEmpty) return false;

  final uri = Uri.tryParse(href);
  if (uri == null) return false;
  if (!uri.hasScheme) return true;

  return uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'mailto';
}

String _escapeText(final String raw) {
  return raw.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

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
