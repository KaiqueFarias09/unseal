import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/utils/xml_encoding.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'html_metadata.dart';

/// The decoded HTML content and the values needed by a document book.
final class HtmlDocumentData {
  /// Creates parsed HTML data.
  const HtmlDocumentData({required this.file, required this.metadata, required this.navigation});

  /// The source content retained as a reader-facing HTML file.
  final TextFile file;

  /// Metadata read from the HTML document.
  final HtmlMetadataValues metadata;

  /// Navigation generated from the document headings.
  final Navigation navigation;
}

/// Decodes and analyzes an HTML/HTM/XHTML source without rewriting its body.
HtmlDocumentData parseHtmlDocument(final List<int> bytes, {required final String path}) {
  final content = decodeXmlText(bytes);
  final metadata = metadataValuesFromHtml(content);
  final document = html_parser.parse(content);
  final navigation = navigationFromHtmlDocument(document, path, metadata.title);
  final name = path.split('/').last;
  final extension = _extension(name);

  return HtmlDocumentData(
    file: TextFile(name: name, type: extension, path: path, content: content),
    metadata: metadata,
    navigation: navigation,
  );
}

/// Creates a heading-based navigation tree using h1-h6 levels.
Navigation navigationFromHtmlDocument(
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

String _extension(final String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return 'html';
  return name.substring(dot + 1).toLowerCase();
}

final class _HeadingFrame {
  const _HeadingFrame(this.level, this.point);

  final int level;
  final NavPoint point;
}
