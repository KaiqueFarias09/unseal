import 'dart:typed_data';

import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as path;

import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../../foundation/text/xml_encoding.dart';

const _maxMarkdownBytes = 16 * 1024 * 1024;
const _maxFrontMatterChars = 16 * 1024;
const _htmlPath = 'document.html';

/// Parses a standalone CommonMark document.
///
/// The optional initial front matter accepts simple `key: value` pairs and
/// dash lists for authors, languages, and tags. Relative resources remain
/// references in the HTML; this byte-only API cannot read neighboring files.
DocumentBook parseMarkdownBook(final Uint8List bytes, {final String? sourceName}) {
  final source = _readSource(bytes);
  final document = md.Document(extensionSet: md.ExtensionSet.commonMark);
  final nodes = document.parse(source.body);
  final headings = <_Heading>[];
  final usedIds = <String>{};
  final pending = <md.Node>[...nodes.reversed];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    if (node is! md.Element) continue;
    if (RegExp(r'^h[1-6]$').hasMatch(node.tag)) {
      final label = node.textContent.trim();
      var id = _slug(label);
      if (id.isEmpty) id = 'section';
      final base = id;
      var suffix = 2;
      while (!usedIds.add(id)) {
        id = '$base-${suffix++}';
      }
      node.attributes['id'] = id;
      headings.add(_Heading(level: int.parse(node.tag.substring(1)), label: label, id: id));
    }
    pending.addAll((node.children ?? const <md.Node>[]).reversed);
  }

  final metadata = _metadata(
    source,
    sourceName: sourceName,
    firstHeading: headings.firstOrNull?.label,
  );
  final title = metadata.title ?? 'Document';
  final html =
      '<!DOCTYPE html><html><head><meta charset="utf-8"><title>'
      '${_escape(title)}</title></head><body>${md.renderToHtml(nodes)}</body></html>';
  final points = _navigation(headings, title);

  return DocumentBook(
    format: BookFormat.markdown,
    files: Files(
      images: const <BinaryFile>[],
      css: const <TextFile>[],
      html: <TextFile>[TextFile(name: _htmlPath, type: 'html', path: _htmlPath, content: html)],
      fonts: const <BinaryFile>[],
      others: const <BinaryFile>[],
    ),
    metadata: metadata,
    navigation: Navigation(title: title, navPoints: points),
    order: const <String>[_htmlPath],
  );
}

/// Reads standalone Markdown metadata without converting its body to HTML.
BookMetadata readMarkdownMetadata(final Uint8List bytes, {final String? sourceName}) {
  final source = _readSource(bytes);
  String? heading;
  final declaredTitle = source.frontMatter['title'];
  if (declaredTitle is! String || declaredTitle.trim().isEmpty) {
    final nodes = md.Document(extensionSet: md.ExtensionSet.commonMark).parse(source.body);
    final pending = <md.Node>[...nodes.reversed];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node is! md.Element) continue;
      if (RegExp(r'^h[1-6]$').hasMatch(node.tag)) {
        heading = node.textContent.trim();
        break;
      }
      pending.addAll((node.children ?? const <md.Node>[]).reversed);
    }
  }
  return _metadata(source, sourceName: sourceName, firstHeading: heading);
}

final class _Heading {
  const _Heading({required this.level, required this.label, required this.id});
  final int level;
  final String label;
  final String id;
}

List<NavPoint> _navigation(final List<_Heading> headings, final String title) {
  if (headings.isEmpty) {
    return <NavPoint>[
      NavPoint(classAttribute: '', id: 'nav-1', playOrder: '1', label: title, content: _htmlPath),
    ];
  }
  final roots = <NavPoint>[];
  final levels = <int>[];
  final parents = <NavPoint>[];
  for (var i = 0; i < headings.length; i++) {
    final heading = headings[i];
    while (levels.isNotEmpty && levels.last >= heading.level) {
      levels.removeLast();
      parents.removeLast();
    }
    final point = NavPoint(
      classAttribute: '',
      id: 'nav-${i + 1}',
      playOrder: '${i + 1}',
      label: heading.label,
      content: '$_htmlPath#${heading.id}',
      subNavPoints: <NavPoint>[],
    );
    if (parents.isEmpty) {
      roots.add(point);
    } else {
      parents.last.subNavPoints.add(point);
    }
    levels.add(heading.level);
    parents.add(point);
  }
  return roots;
}

final class _MarkdownSource {
  const _MarkdownSource({required this.body, required this.frontMatter});
  final String body;
  final Map<String, Object> frontMatter;
}

_MarkdownSource _readSource(final Uint8List bytes) {
  if (bytes.length > _maxMarkdownBytes) {
    throw const InvalidBookException('Markdown exceeds the 16 MiB input limit.');
  }
  final input = decodeXmlText(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (!input.startsWith('---\n')) {
    return _MarkdownSource(body: input, frontMatter: const <String, Object>{});
  }
  final end = input.indexOf('\n---\n', 4);
  if (end < 0 || end > _maxFrontMatterChars) {
    throw const InvalidBookException(
      'Markdown front matter is missing a closing delimiter or is too large.',
    );
  }
  final header = input.substring(4, end);
  final values = <String, Object>{};
  String? listKey;
  for (final line in header.split('\n')) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    if (line.startsWith('  - ') || line.startsWith('- ')) {
      if (listKey == null) {
        throw const InvalidBookException('Markdown front matter list has no key.');
      }
      (values[listKey] as List<String>).add(_unquote(line.trimLeft().substring(2).trim()));
      continue;
    }
    final match = RegExp(r'^([A-Za-z][A-Za-z0-9_-]*):(?:\s*(.*))?$').firstMatch(line);
    if (match == null) {
      throw const InvalidBookException('Unsupported Markdown front matter syntax.');
    }
    final key = match.group(1)!.toLowerCase();
    final value = (match.group(2) ?? '').trim();
    if (value.isEmpty) {
      listKey = key;
      values[key] = <String>[];
    } else {
      listKey = null;
      values[key] = _unquote(value);
    }
  }
  return _MarkdownSource(body: input.substring(end + 5), frontMatter: values);
}

String _unquote(final String value) {
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

BookMetadata _metadata(
  final _MarkdownSource source, {
  required final String? sourceName,
  required final String? firstHeading,
}) {
  final values = source.frontMatter;
  String? scalar(final String key) {
    final value = values[key];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  List<String> list(final String singular, final String plural) {
    final value = values[plural] ?? values[singular];
    if (value is List<String>) return value.where((final item) => item.isNotEmpty).toList();
    if (value is String && value.trim().isNotEmpty) {
      return value
          .split(',')
          .map((final item) => item.trim())
          .where((final item) => item.isNotEmpty)
          .toList();
    }
    return const <String>[];
  }

  final filename = sourceName == null ? null : path.basenameWithoutExtension(sourceName).trim();
  final title =
      scalar('title') ??
      (firstHeading?.trim().isNotEmpty ?? false ? firstHeading!.trim() : null) ??
      (filename?.isNotEmpty ?? false ? filename : null);
  return BookMetadata(
    format: BookFormat.markdown,
    title: title,
    authors: list('author', 'authors'),
    languages: list('language', 'languages'),
    subjects: list('tag', 'tags'),
    description: scalar('description'),
  );
}

String _slug(final String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

String _escape(final String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
