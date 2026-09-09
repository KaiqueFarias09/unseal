import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import '../../foundation/archive/archive_access.dart';
import '../../foundation/images/image_type_sniffer.dart';
import '../../foundation/text/xml_encoding.dart';

import 'exceptions/html_exception.dart';
import 'metadata/html_metadata.dart';
import 'parsing/html_document.dart';

/// Parses a standalone HTML, HTM or XHTML document.
DocumentBook parseHtmlBook(final List<int> bytes, {final String fileName = 'index.html'}) {
  final path = _safePath(fileName, fallback: 'index.html');
  final data = parseHtmlDocument(bytes, path: path);
  final metadata = buildHtmlMetadata(data.metadata, BookFormat.html);

  return DocumentBook(
    format: BookFormat.html,
    files: Files(
      images: const <BinaryFile>[],
      css: const <TextFile>[],
      html: <TextFile>[data.file],
      fonts: const <BinaryFile>[],
      others: const <BinaryFile>[],
    ),
    metadata: metadata,
    navigation: data.navigation,
    order: <String>[data.file.path],
  );
}

/// Reads only standalone HTML metadata and headings are not retained.
BookMetadata readHtmlMetadata(final List<int> bytes, {final String fileName = 'index.html'}) {
  final path = _safePath(fileName, fallback: 'index.html');
  final data = parseHtmlDocument(bytes, path: path);
  return buildHtmlMetadata(data.metadata, BookFormat.html);
}

/// Parses an HTMLZ ZIP archive following Calibre's top-level convention.
DocumentBook parseHtmlzBook(final List<int> bytes) {
  if (bytes.isEmpty) throw const HtmlException('HTMLZ archive is empty');
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object catch (error) {
    throw HtmlException('Invalid HTMLZ ZIP archive: $error');
  }
  return parseHtmlzArchive(archive);
}

/// Parses an already decoded HTMLZ archive.
DocumentBook parseHtmlzArchive(final Archive archive) {
  final selection = _selectHtmlzEntries(archive);
  final htmlBytes = contentBytes(selection.html);
  if (htmlBytes.isEmpty) {
    throw HtmlException('HTMLZ top-level HTML file "${selection.htmlPath}" is empty');
  }

  final data = parseHtmlDocument(htmlBytes, path: selection.htmlPath);
  final opfValues = selection.opf == null
      ? const HtmlMetadataValues()
      : _tryReadOpf(selection.opf!);
  final merged = mergeMetadataValues(data.metadata, opfValues);
  final cover = _readCover(archive, selection.opfPath, merged.coverHref);
  final metadata = buildHtmlMetadata(merged, BookFormat.htmlz, cover: cover);
  final files = _extractFiles(archive, data.file, selection.opfPath);

  return DocumentBook(
    format: BookFormat.htmlz,
    files: files,
    metadata: metadata,
    navigation: data.navigation,
    cover: cover,
    archiveEntries: _archiveEntries(archive),
    order: <String>[selection.htmlPath],
  );
}

/// Reads only the selected HTML and top-level OPF from an HTMLZ archive.
BookMetadata readHtmlzMetadata(final List<int> bytes) {
  if (bytes.isEmpty) throw const HtmlException('HTMLZ archive is empty');
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object catch (error) {
    throw HtmlException('Invalid HTMLZ ZIP archive: $error');
  }
  return readHtmlzMetadataFromArchive(archive);
}

/// Reads HTMLZ metadata from an already decoded archive without extracting
/// CSS, images, fonts or unrelated resources.
BookMetadata readHtmlzMetadataFromArchive(final Archive archive) {
  final selection = _selectHtmlzEntries(archive);
  final bytes = contentBytes(selection.html);
  if (bytes.isEmpty) {
    throw HtmlException('HTMLZ top-level HTML file "${selection.htmlPath}" is empty');
  }
  final htmlValues = parseHtmlDocument(bytes, path: selection.htmlPath).metadata;
  final opfValues = selection.opf == null
      ? const HtmlMetadataValues()
      : _tryReadOpf(selection.opf!);
  final merged = mergeMetadataValues(htmlValues, opfValues);
  final cover = _readCover(archive, selection.opfPath, merged.coverHref);
  return buildHtmlMetadata(merged, BookFormat.htmlz, cover: cover);
}

_HtmlzSelection _selectHtmlzEntries(final Archive archive) {
  final files = archive.files.where((final entry) => entry.isFile).toList(growable: false);
  final topLevel = files.where((final entry) => !_normalized(entry.name).contains('/')).toList();
  final htmlFiles = topLevel.where((final entry) => _isHtmlPath(entry.name)).toList();
  ArchiveFile? html;
  for (final preferred in const ['index.html', 'index.xhtml', 'index.htm']) {
    html = htmlFiles.cast<ArchiveFile?>().firstWhere(
      (final entry) => _normalized(entry!.name).toLowerCase() == preferred,
      orElse: () => null,
    );
    if (html != null) break;
  }
  html ??= htmlFiles.isEmpty ? null : htmlFiles.first;
  if (html == null) {
    throw const HtmlException('HTMLZ archive has no top-level HTML file');
  }

  ArchiveFile? opf;
  for (final entry in topLevel) {
    final name = _normalized(entry.name).toLowerCase();
    if (name == 'metadata.opf') {
      opf = entry;
      break;
    }
    if (opf == null && _extension(name) == 'opf') opf = entry;
  }

  return _HtmlzSelection(
    html: html,
    htmlPath: _normalized(html.name),
    opf: opf,
    opfPath: opf == null ? null : _normalized(opf.name),
  );
}

HtmlMetadataValues _tryReadOpf(final ArchiveFile entry) {
  try {
    return metadataValuesFromOpf(contentBytes(entry));
  } on Object {
    // A malformed optional metadata sidecar must not make readable HTMLZ
    // content unusable.
    return const HtmlMetadataValues();
  }
}

BinaryFile? _readCover(final Archive archive, final String? opfPath, final String? coverHref) {
  if (coverHref == null || coverHref.trim().isEmpty) return null;
  final path = resolveItemPath(opfPath, _decodeUri(coverHref));
  final entry = archive.files.cast<ArchiveFile?>().firstWhere(
    (final candidate) =>
        candidate!.isFile && _normalized(candidate.name).toLowerCase() == path.toLowerCase(),
    orElse: () => null,
  );
  if (entry == null) return null;
  final name = _normalized(entry.name).split('/').last;
  return BinaryFile(
    name: name,
    type: _extension(name),
    path: _normalized(entry.name),
    content: contentBytes(entry),
  );
}

Files _extractFiles(final Archive archive, final TextFile htmlFile, final String? opfPath) {
  final images = <BinaryFile>[];
  final css = <TextFile>[];
  final fonts = <BinaryFile>[];
  final others = <BinaryFile>[];
  final normalizedHtml = htmlFile.path.toLowerCase();
  final normalizedOpf = opfPath?.toLowerCase();

  for (final entry in archive.files.where((final candidate) => candidate.isFile)) {
    final path = _normalized(entry.name);
    final lower = path.toLowerCase();
    if (lower == normalizedHtml || lower == normalizedOpf) continue;

    final name = path.split('/').last;
    final type = _extension(name);
    if (type == 'css') {
      css.add(
        TextFile(name: name, type: type, path: path, content: decodeXmlText(contentBytes(entry))),
      );
      continue;
    }

    final content = contentBytes(entry);
    if (_isImagePath(path, content)) {
      images.add(BinaryFile(name: name, type: type, path: path, content: content));
    } else if (_isFontType(type)) {
      fonts.add(BinaryFile(name: name, type: type, path: path, content: content));
    } else {
      // Non-selected HTML files are retained in the physical resource set;
      // Calibre still uses only one top-level HTML spine item for HTMLZ.
      others.add(BinaryFile(name: name, type: type, path: path, content: content));
    }
  }

  return Files(images: images, css: css, html: <TextFile>[htmlFile], fonts: fonts, others: others);
}

List<ArchiveEntry> _archiveEntries(final Archive archive) {
  return <ArchiveEntry>[
    for (final entry in archive.files)
      if (entry.isFile) ArchiveEntry(path: _normalized(entry.name), size: entry.size),
  ];
}

bool _isHtmlPath(final String path) {
  final extension = _extension(path);
  return extension == 'html' || extension == 'htm' || extension == 'xhtml';
}

bool _isImagePath(final String path, final Uint8List content) {
  if (sniffImageType(content) != null) return true;
  return const {
    'avif',
    'gif',
    'jpeg',
    'jpg',
    'png',
    'svg',
    'webp',
    'bmp',
    'tif',
    'tiff',
  }.contains(_extension(path));
}

bool _isFontType(final String type) => const {'eot', 'otf', 'ttf', 'woff', 'woff2'}.contains(type);

String _safePath(final String path, {required final String fallback}) {
  final normalized = _normalized(path);
  return normalized.isEmpty ? fallback : normalized;
}

String _normalized(final String path) => normalizeZipPath(path.replaceAll('\\', '/'));

String _extension(final String path) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

String _decodeUri(final String value) {
  try {
    return Uri.decodeComponent(value);
  } on FormatException {
    return value;
  }
}

final class _HtmlzSelection {
  const _HtmlzSelection({required this.html, required this.htmlPath, this.opf, this.opfPath});

  final ArchiveFile html;
  final String htmlPath;
  final ArchiveFile? opf;
  final String? opfPath;
}
