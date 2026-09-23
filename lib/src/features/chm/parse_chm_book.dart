import 'dart:typed_data';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../../foundation/text/xml_encoding.dart';
import 'chm_archive.dart';

/// Reads an ITSF/CHM help book, including LZX-compressed HTML and resources.
DocumentBook parseChmBook(final Uint8List bytes) {
  final archive = ChmArchive(bytes);
  final system = _system(archive);
  final htmlEntries = archive.entries.values
      .where((final entry) {
        return _isNormal(entry.name) && _isHtml(_extension(entry.name));
      })
      .toList(growable: false);
  if (htmlEntries.isEmpty) {
    throw const InvalidBookException('CHM has no readable HTML topics.');
  }

  final toc = _readContents(archive, system.contentsPath, system.encoding);
  final orderedPaths = <String>[];
  final seen = <String>{};
  void add(final String path) {
    final key = path.toLowerCase();
    if (seen.add(key) && archive.entry('/$path') != null && _isHtml(_extension(path))) {
      orderedPaths.add(path);
    }
  }

  for (final path in toc.paths) {
    add(path);
  }
  if (system.homePath != null) add(system.homePath!);
  for (final entry in htmlEntries) {
    add(_normalPath(entry.name));
  }
  if (orderedPaths.isEmpty) throw const InvalidBookException('CHM has no safe HTML topics.');

  final html = <TextFile>[];
  final css = <TextFile>[];
  final images = <BinaryFile>[];
  final fonts = <BinaryFile>[];
  final others = <BinaryFile>[];
  var materialized = 0;
  for (final path in orderedPaths) {
    final entry = archive.entry('/$path')!;
    materialized += entry.length;
    if (materialized > 128 * 1024 * 1024) {
      throw const InvalidBookException('CHM topics exceed extraction limit.');
    }
    html.add(
      TextFile(
        name: path.split('/').last,
        type: _extension(path),
        path: path,
        content: decodeXmlText(archive.read(entry), defaultEncoding: system.encoding),
      ),
    );
  }
  for (final entry in archive.entries.values) {
    if (!_isNormal(entry.name) || entry.name.endsWith('/')) continue;
    final path = _normalPath(entry.name);
    final extension = _extension(path);
    if (_isHtml(extension) || extension == 'hhc' || extension == 'hhk') continue;
    // Resources are bounded by the container reader before decompression.
    materialized += entry.length;
    if (materialized > 128 * 1024 * 1024) {
      throw const InvalidBookException('CHM resources exceed extraction limit.');
    }
    if (extension == 'css') {
      css.add(
        TextFile(
          name: path.split('/').last,
          type: extension,
          path: path,
          content: decodeXmlText(archive.read(entry), defaultEncoding: system.encoding),
        ),
      );
    } else {
      final file = BinaryFile(
        name: path.split('/').last,
        type: extension,
        path: path,
        content: archive.read(entry),
      );
      if (const {'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'}.contains(extension)) {
        images.add(file);
      } else if (const {'ttf', 'otf', 'woff', 'woff2'}.contains(extension)) {
        fonts.add(file);
      } else {
        others.add(file);
      }
    }
  }
  final title = system.title ?? _htmlTitle(html.first.content) ?? 'CHM document';
  return DocumentBook(
    format: BookFormat.chm,
    metadata: BookMetadata(format: BookFormat.chm, title: title, bookProducer: system.generator),
    navigation: Navigation(title: title, navPoints: toc.points),
    files: Files(images: images, css: css, html: html, fonts: fonts, others: others),
    archiveEntries: <ArchiveEntry>[
      for (final entry in archive.entries.values)
        ArchiveEntry(path: entry.name, size: entry.length),
    ],
    order: orderedPaths,
  );
}

/// Reads CHM metadata from the uncompressed #SYSTEM stream only.
BookMetadata readChmMetadata(final Uint8List bytes) {
  final archive = ChmArchive(bytes);
  final system = _system(archive);
  return BookMetadata(format: BookFormat.chm, title: system.title, bookProducer: system.generator);
}

_ChmSystem _system(final ChmArchive archive) {
  final entry = archive.entry('/#SYSTEM');
  if (entry == null || entry.section != 0 || entry.length < 4) {
    archive.applyTextEncoding(XmlEncoding.utf8);
    return const _ChmSystem();
  }
  final bytes = archive.read(entry);
  final view = ByteData.sublistView(bytes);
  var at = 4;
  String? contents;
  String? home;
  String? title;
  String? generator;
  final records = <(int kind, Uint8List data)>[];
  while (at + 4 <= bytes.length) {
    final kind = view.getUint16(at, Endian.little);
    final length = view.getUint16(at + 2, Endian.little);
    at += 4;
    if (at + length > bytes.length) break;
    records.add((kind, Uint8List.sublistView(bytes, at, at + length)));
    at += length;
  }

  final lcid = records
      .where((final record) => record.$1 == 4 && record.$2.length >= 4)
      .map((final record) => ByteData.sublistView(record.$2).getUint32(0, Endian.little))
      .firstOrNull;
  final encoding = lcid == null ? null : _encodingForChmLcid(lcid);
  archive.applyTextEncoding(encoding ?? XmlEncoding.utf8);

  for (final record in records) {
    final kind = record.$1;
    if (kind == 0 || kind == 2 || kind == 3 || kind == 9) {
      final source = decodeXmlText(
        record.$2,
        defaultEncoding: encoding,
      ).replaceAll('\u0000', '').trim();
      if (kind == 0) contents = _safePath(source);
      if (kind == 2) home = _safePath(source);
      if (kind == 3 && source.isNotEmpty) title = source;
      if (kind == 9 && source.isNotEmpty) generator = source;
    }
  }
  return _ChmSystem(contents, home, title, generator, encoding);
}

/// Maps the Windows language IDs used by the CHM `#SYSTEM` LCID record to
/// the legacy codepages Unseal can decode without platform APIs.
///
/// The mapping deliberately covers Western Windows, Cyrillic, and Arabic
/// codepages. Other LCIDs continue through the shared encoding detector.
XmlEncoding? _encodingForChmLcid(final int lcid) {
  final language = lcid & 0x3ff;
  return switch (language) {
    // Arabic, Urdu, and Persian.
    0x01 || 0x20 || 0x29 => XmlEncoding.cp1256,
    // Bulgarian, Russian, Ukrainian, and Belarusian.
    0x02 || 0x19 || 0x22 || 0x23 || 0x28 => XmlEncoding.cp1251,
    // Western European locales that use Windows-1252.
    0x06 ||
    0x09 ||
    0x07 ||
    0x0a ||
    0x0b ||
    0x0c ||
    0x0f ||
    0x10 ||
    0x13 ||
    0x14 ||
    0x16 ||
    0x17 ||
    0x1d ||
    0x21 ||
    0x36 ||
    0x38 => XmlEncoding.cp1252,
    _ => null,
  };
}

_ChmContents _readContents(
  final ChmArchive archive,
  final String? preferred,
  final XmlEncoding? encoding,
) {
  ChmEntry? entry;
  if (preferred != null) entry = archive.entry('/$preferred');
  entry ??= archive.entries.values.cast<ChmEntry?>().firstWhere(
    (final candidate) =>
        candidate != null &&
        _isNormal(candidate.name) &&
        candidate.name.toLowerCase().endsWith('.hhc'),
    orElse: () => null,
  );
  if (entry == null) return const _ChmContents([], []);
  final document = html_parser.parse(decodeXmlText(archive.read(entry), defaultEncoding: encoding));
  final body = document.body;
  if (body == null) return const _ChmContents([], []);
  final roots = body.children.where((final child) => child.localName == 'ul');
  final paths = <String>[];
  final points = <NavPoint>[];
  var playOrder = 0;

  List<NavPoint> walk(final dom.Element list, final int depth) {
    if (depth > 64) throw const InvalidBookException('CHM contents nesting exceeds limit.');
    final result = <NavPoint>[];
    for (final item in list.children.where((final child) => child.localName == 'li')) {
      String? label;
      String? path;
      String? href;
      final object = item.children.where((final child) => child.localName == 'object').firstOrNull;
      for (final param
          in object?.children.where((final child) => child.localName == 'param') ??
              const <dom.Element>[]) {
        final key = param.attributes['name']?.toLowerCase();
        if (key == 'name') label = param.attributes['value'];
        if (key == 'local') {
          final local = param.attributes['value'] ?? '';
          path = _safePath(local);
          final hash = local.indexOf('#');
          if (path != null &&
              hash >= 0 &&
              hash + 1 < local.length &&
              local.length - hash <= 257 &&
              !local.substring(hash + 1).contains('\u0000')) {
            href = '$path${local.substring(hash)}';
          }
        }
      }
      final valid = path != null && archive.entry('/$path') != null && _isHtml(_extension(path));
      if (valid) {
        paths.add(path);
        playOrder++;
      }
      final ordinal = playOrder;
      final children = <NavPoint>[];
      for (final nested in item.children.where((final child) => child.localName == 'ul')) {
        children.addAll(walk(nested, depth + 1));
      }
      if (valid) {
        result.add(
          NavPoint(
            classAttribute: '',
            id: 'chm-$ordinal',
            playOrder: '$ordinal',
            label: label?.trim().isNotEmpty == true ? label!.trim() : path,
            content: href ?? path,
            subNavPoints: children,
          ),
        );
      } else {
        result.addAll(children);
      }
    }
    return result;
  }

  for (final root in roots) {
    points.addAll(walk(root, 0));
  }
  return _ChmContents(points, paths);
}

String? _safePath(final String value) {
  final clean = value.split('#').first.split('?').first.replaceAll('\\', '/').trim();
  if (clean.isEmpty || clean.contains('://') || clean.contains('\u0000')) return null;
  final pieces = clean.split('/').where((final piece) => piece.isNotEmpty).toList();
  if (pieces.any((final piece) => piece == '.' || piece == '..')) return null;
  return pieces.isEmpty ? null : pieces.join('/');
}

bool _isNormal(final String path) {
  return path.startsWith('/') &&
      !path.startsWith('/#') &&
      !path.startsWith('/\$') &&
      _safePath(path) != null;
}

String _normalPath(final String path) => _safePath(path)!;
String _extension(final String path) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
}

bool _isHtml(final String extension) => const {'html', 'htm', 'xhtml'}.contains(extension);

String? _htmlTitle(final String html) {
  final text = html_parser.parse(html).querySelector('title')?.text.trim();
  return text == null || text.isEmpty ? null : text;
}

final class _ChmSystem {
  const _ChmSystem([this.contentsPath, this.homePath, this.title, this.generator, this.encoding]);
  final String? contentsPath;
  final String? homePath;
  final String? title;
  final String? generator;
  final XmlEncoding? encoding;
}

final class _ChmContents {
  const _ChmContents(this.points, this.paths);
  final List<NavPoint> points;
  final List<String> paths;
}
