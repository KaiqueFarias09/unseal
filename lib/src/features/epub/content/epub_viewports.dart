import '../../../foundation/entities/file/text_file.dart';
import '../entities/entities.dart';

/// The viewport declaration sits in the document head (XHTML) or on the
/// root element (SVG), so a bounded prefix scan is enough for real books.
const _prefixCharacters = 8192;

/// Files at most this large are scanned in full when the prefix scan
/// finds nothing; whitespace-heavy small documents can push their head
/// past the prefix.
const _fullScanCharacters = 65536;

/// Largest accepted dimension, in CSS pixels. Anything above this is
/// treated as a malformed declaration rather than a page size.
const _maxDimension = 20000;

final _metaTagPattern = RegExp('<meta\\b[^>]*>', caseSensitive: false, dotAll: true);
final _viewportNamePattern = RegExp(
  r'''name\s*=\s*(?:"viewport"|'viewport'|viewport(?![\w:-]))''',
  caseSensitive: false,
);
final _metaContentPattern = RegExp(
  r'''content\s*=\s*(?:"([^"]*)"|'([^']*)')''',
  caseSensitive: false,
  dotAll: true,
);
final _viewportPropertyPattern = RegExp(
  r'''(width|height)\s*=\s*("[^"]*"|'[^']*'|[^\s,;]+)''',
  caseSensitive: false,
);
final _svgOpenTagPattern = RegExp(r'<svg\b[^>]*>', caseSensitive: false, dotAll: true);
final _svgAttributePattern = RegExp(
  r'''(viewBox|width|height)\s*=\s*(?:"([^"]*)"|'([^']*)')''',
  caseSensitive: false,
);
final _prologPattern = RegExp(r'^\s*(?:<\?[^>]*\?>|<!--.*?-->|<![^>]*>)', dotAll: true);

/// Extracts the declared page dimensions of [spinePaths] content
/// documents from the extracted [contentFiles].
///
/// XHTML documents contribute their `<meta name="viewport">` width and
/// height; standalone SVG documents contribute the root `<svg>` element's
/// explicit `width`/`height` (preferred) or `viewBox` size. Documents
/// with a malformed, fractional, non-positive, or oversized declaration
/// simply have no viewport; parsing never fails. The result is keyed by
/// the file path space of [contentFiles] and only holds documents that
/// declare a usable viewport.
Map<String, EpubViewport> extractContentViewports(
  final List<TextFile> contentFiles,
  final List<String> spinePaths,
) {
  if (spinePaths.isEmpty) return const <String, EpubViewport>{};

  final spinePathSet = <String>{for (final path in spinePaths) path.toLowerCase()};
  final viewports = <String, EpubViewport>{};
  for (final file in contentFiles) {
    if (!spinePathSet.contains(file.path.toLowerCase())) continue;

    final viewport = _viewportOf(file.content);
    if (viewport != null) viewports[file.path] = viewport;
  }

  return viewports;
}

/// The declared viewport of one content document, or `null` when the
/// document declares none or declares one that fails validation.
EpubViewport? _viewportOf(final String content) {
  final prefix = content.length <= _prefixCharacters
      ? content
      : content.substring(0, _prefixCharacters);

  final viewport = _isSvgDocument(prefix) ? _svgViewportOf(prefix) : _xhtmlViewportOf(prefix);
  if (viewport != null) return viewport;

  if (content.length > _prefixCharacters && content.length <= _fullScanCharacters) {
    return _isSvgDocument(content) ? _svgViewportOf(content) : _xhtmlViewportOf(content);
  }

  return null;
}

/// Whether the document's root element is `<svg>` (a standalone SVG
/// content document) as opposed to an XHTML page that may embed inline
/// SVG.
bool _isSvgDocument(final String prefix) {
  var rest = prefix;
  while (true) {
    final match = _prologPattern.firstMatch(rest);
    if (match == null) break;

    rest = rest.substring(match.end);
  }

  final rootStart = rest.indexOf('<');
  if (rootStart < 0 || rootStart + 1 >= rest.length) return false;

  final after = rest.substring(rootStart + 1);
  final nameMatch = RegExp(r'^[A-Za-z]+').firstMatch(after);

  return nameMatch?.group(0)?.toLowerCase() == 'svg';
}

/// `<meta name="viewport" content="width=W, height=H">` of an XHTML page.
EpubViewport? _xhtmlViewportOf(final String prefix) {
  for (final tag in _metaTagPattern.allMatches(prefix)) {
    final tagText = tag.group(0)!;
    if (!_viewportNamePattern.hasMatch(tagText)) continue;

    final content = _metaContentPattern.firstMatch(tagText);
    if (content == null) continue;

    final viewport = _viewportFromProperties(content.group(1) ?? content.group(2) ?? '');
    if (viewport != null) return viewport;
  }

  return null;
}

/// Root `<svg viewBox="minx miny W H" width="W" height="H">` attributes.
/// Explicit width and height win over the `viewBox` size.
EpubViewport? _svgViewportOf(final String prefix) {
  final tag = _svgOpenTagPattern.firstMatch(prefix);
  if (tag == null) return null;

  final attributes = <String, String>{};
  for (final match in _svgAttributePattern.allMatches(tag.group(0)!)) {
    attributes.putIfAbsent(match.group(1)!.toLowerCase(), () => match.group(2)!);
  }

  final width = _dimensionOf(attributes['width']);
  final height = _dimensionOf(attributes['height']);
  if (width != null && height != null) return EpubViewport(width: width, height: height);

  final box = attributes['viewBox']?.split(RegExp(r'[\s,]+')) ?? const <String>[];
  if (box.length != 4) return null;

  final boxWidth = _dimensionOf(box[2]);
  final boxHeight = _dimensionOf(box[3]);
  if (boxWidth == null || boxHeight == null) return null;

  return EpubViewport(width: boxWidth, height: boxHeight);
}

/// `width=W, height=H` declarations of a viewport `content` attribute.
EpubViewport? _viewportFromProperties(final String content) {
  int? width;
  int? height;
  for (final match in _viewportPropertyPattern.allMatches(content)) {
    final value = _dimensionOf(match.group(2)!);
    if (value == null) continue;

    if (match.group(1)!.toLowerCase() == 'width') {
      width ??= value;
    } else {
      height ??= value;
    }
  }

  if (width == null || height == null) return null;

  return EpubViewport(width: width, height: height);
}

/// Parses one declared dimension: a positive integer of at most
/// [_maxDimension], with an optional `px` unit and surrounding spaces.
int? _dimensionOf(final String? raw) {
  if (raw == null) return null;

  var value = raw.trim();
  if (value.length > 2 && value.toLowerCase().endsWith('px')) {
    value = value.substring(0, value.length - 2).trim();
  }
  if (value.isEmpty) return null;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit < 0x30 || unit > 0x39) return null;
  }

  final parsed = int.tryParse(value);
  if (parsed == null || parsed < 1 || parsed > _maxDimension) return null;

  return parsed;
}
