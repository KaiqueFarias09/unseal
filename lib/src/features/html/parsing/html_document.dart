part of '../parse_html_book.dart';

/// The decoded HTML content and the values needed by a document book.
final class _HtmlDocument {
  /// Creates parsed HTML data.
  const _HtmlDocument({required this.file, required this.metadata, required this.navigation});

  /// The source content retained as a reader-facing HTML file.
  final TextFile file;

  /// Metadata read from the HTML document.
  final _HtmlMetadata metadata;

  /// Navigation generated from the document headings.
  final Navigation navigation;
}

/// Decodes and analyzes an HTML/HTM/XHTML source without rewriting its body.
_HtmlDocument _parseHtmlDocument(final List<int> bytes, {required final String path}) {
  final source = _decodeHtmlSource(bytes);
  final metadata = _metadataFromHtml(source.document);
  final navigation = _navigationFromHtmlDocument(source.document, path, metadata.title);
  final name = path.split('/').last;
  final extension = _htmlExtension(name);

  return _HtmlDocument(
    file: TextFile(name: name, type: extension, path: path, content: source.content),
    metadata: metadata,
    navigation: navigation,
  );
}

/// Creates a heading-based navigation tree using h1-h6 levels.
Navigation _navigationFromHtmlDocument(
  final dom.Document document,
  final String path,
  final String? title,
) {
  final roots = <NavPoint>[];
  final stack = <_HeadingFrame>[];
  var playOrder = 0;
  for (final heading in document.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
    final label = heading.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (label.isEmpty) continue;

    final level = int.parse(heading.localName!.substring(1));
    final id = heading.id.trim();
    final content = id.isEmpty ? path : '$path#$id';
    final point = NavPoint(
      classAttribute: 'heading-$level',
      id: id,
      playOrder: '${++playOrder}',
      label: label,
      content: content,
      subNavPoints: <NavPoint>[],
    );

    while (stack.isNotEmpty && stack.last.level >= level) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      roots.add(point);
    } else {
      stack.last.point.subNavPoints.add(point);
    }
    stack.add(_HeadingFrame(level, point));
  }

  return Navigation(title: title ?? '', navPoints: roots);
}

({String content, dom.Document document}) _decodeHtmlSource(final List<int> bytes) {
  final content = decodeXmlText(bytes);

  return (content: content, document: html_parser.parse(content));
}

String _htmlExtension(final String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return 'html';

  return name.substring(dot + 1).toLowerCase();
}

final class _HeadingFrame {
  const _HeadingFrame(this.level, this.point);

  final int level;
  final NavPoint point;
}
