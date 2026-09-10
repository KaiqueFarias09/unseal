import 'package:html/parser.dart' as html_parser;

import '../entities/entities.dart';

/// Creates heading navigation from an HTML document, preserving nested heading levels through
/// [NavPoint.subNavPoints].
Navigation htmlNavigation(final String source, {final String title = ''}) {
  final document = html_parser.parse(source);
  final headings = document.querySelectorAll('h1,h2,h3,h4,h5,h6');
  if (headings.isEmpty) return Navigation(title: title, navPoints: const <NavPoint>[]);

  final roots = <NavPoint>[];
  final stack = <(int, NavPoint)>[];
  var order = 0;

  for (final heading in headings) {
    final label = heading.text.trim();
    if (label.isEmpty) continue;

    final level = int.tryParse(heading.localName?.substring(1) ?? '') ?? 1;
    final id = heading.id.isEmpty ? 'heading-${order + 1}' : heading.id;
    final point = NavPoint(
      classAttribute: heading.localName ?? 'h$level',
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
