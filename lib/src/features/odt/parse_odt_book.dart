import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/src/features/odt/exceptions/exceptions.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/utils/archive_utils.dart';
import 'package:e_livre/src/foundation/utils/document_helpers.dart';
import 'package:e_livre/src/foundation/utils/image_sniffer.dart';
import 'package:e_livre/src/foundation/utils/xml_encoding.dart';
import 'package:xml/xml.dart';

/// Parses an OpenDocument Text package into the common document model.
DocumentBook parseOdtBook(final Uint8List bytes) {
  if (bytes.isEmpty) throw const InvalidOdtPackageException('ODT package is empty.');

  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object catch (error) {
    throw InvalidOdtPackageException('ODT package is not a valid ZIP archive: $error');
  }

  return parseOdtArchive(archive);
}

/// Parses an already decoded ODT [archive].
DocumentBook parseOdtArchive(final Archive archive) {
  final package = _OdtPackage.fromArchive(archive);
  final metadata = _readMetadata(package.meta);
  final styles = _StyleCatalog.fromDocuments(package.styles, package.content);
  final referencedImages = <String>{};
  final xhtml = _renderContent(package.content, styles, referencedImages, metadata.title);
  final images = _readImages(archive, referencedImages);
  final fonts = _readFonts(archive);
  final others = _readOtherBinaryParts(archive, images, fonts);
  final cover = firstImageCover(images);
  final content = textFile('content.xhtml', xhtml, type: 'xhtml');

  return DocumentBook(
    format: BookFormat.odt,
    files: Files(
      images: images,
      css: const <TextFile>[],
      html: <TextFile>[content],
      fonts: fonts,
      others: others,
    ),
    metadata: metadata.copyWith(cover: coverFromBinary(cover)),
    navigation: htmlNavigation(xhtml, title: metadata.title ?? ''),
    cover: cover,
    archiveEntries: _archiveEntries(archive),
    order: <String>[content.path],
  );
}

/// Reads metadata from an ODT package without rendering the document body.
BookMetadata readOdtMetadata(final Uint8List bytes) {
  if (bytes.isEmpty) throw const InvalidOdtPackageException('ODT package is empty.');

  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object catch (error) {
    throw InvalidOdtPackageException('ODT package is not a valid ZIP archive: $error');
  }

  return readOdtMetadataFromArchive(archive);
}

/// Reads metadata from an already decoded ODT [archive].
BookMetadata readOdtMetadataFromArchive(final Archive archive) {
  final package = _OdtPackage.fromArchive(archive);
  return _readMetadata(package.meta);
}

final class _OdtPackage {
  _OdtPackage({required this.content, this.meta, this.styles});

  factory _OdtPackage.fromArchive(final Archive archive) {
    final contentEntry = findArchiveFile(archive, 'content.xml');
    if (contentEntry == null) throw const MissingOdtPartException('content.xml');

    final content = _parseRequiredXml(contentEntry);
    final root = content.rootElement;
    if (root.name.local != 'document-content') {
      throw InvalidOdtXmlException(
        contentEntry.name,
        'root element must be office:document-content, found ${root.name.qualified}',
      );
    }
    if (_findDescendant(root, 'body') == null) {
      throw InvalidOdtXmlException(contentEntry.name, 'document has no office:body element');
    }

    return _OdtPackage(
      content: content,
      meta: _optionalXml(archive, 'meta.xml'),
      styles: _optionalXml(archive, 'styles.xml'),
    );
  }

  final XmlDocument content;
  final XmlDocument? meta;
  final XmlDocument? styles;
}

XmlDocument _parseRequiredXml(final ArchiveFile entry) {
  try {
    return XmlDocument.parse(decodeXmlText(contentBytes(entry)));
  } on Object catch (error) {
    throw InvalidOdtXmlException(entry.name, error.toString());
  }
}

XmlDocument? _optionalXml(final Archive archive, final String path) {
  final entry = findArchiveFile(archive, path);
  if (entry == null) return null;

  try {
    return XmlDocument.parse(decodeXmlText(contentBytes(entry)));
  } on Object {
    return null;
  }
}

BookMetadata _readMetadata(final XmlDocument? document) {
  if (document == null) return const BookMetadata(format: BookFormat.odt);

  final root = document.rootElement;
  final title = _firstText(root, const {'title'});
  final creator = _firstText(root, const {'initial-creator', 'creator'});
  final subject = _firstText(root, const {'subject'});
  final description = _firstText(root, const {'description'});
  final language = _firstText(root, const {'language'});
  final publisher = _firstText(root, const {'publisher'});
  final rights = _firstText(root, const {'rights'});
  final identifier = _firstText(root, const {'identifier'});
  final date = _firstText(root, const {'creation-date', 'date', 'created'});
  final producer = _firstText(root, const {'generator', 'producer'});
  final keywords = _allText(root, 'keyword');
  final userDefined = _userDefined(root);
  final subjects = <String>[if (subject != null) ..._splitValues(subject), ...keywords];

  return BookMetadata(
    format: BookFormat.odt,
    title: title,
    authors: creator == null ? const <String>[] : _splitAuthors(creator),
    bookProducer: producer,
    languages: language == null ? const <String>[] : _splitValues(language),
    publisher: publisher,
    description: description,
    subjects: subjects,
    publishedAt: DateTime.tryParse(date ?? ''),
    rights: rights,
    series: userDefined['series'],
    seriesIndex: double.tryParse(userDefined['series_index'] ?? ''),
    identifiers: identifier == null
        ? const <String, String>{}
        : <String, String>{'identifier': identifier},
  );
}

String? _firstText(final XmlElement root, final Set<String> names) {
  for (final element in root.descendants.whereType<XmlElement>()) {
    if (!names.contains(element.name.local.toLowerCase())) continue;
    final value = element.innerText.trim();
    if (value.isNotEmpty) return value;
  }

  return null;
}

List<String> _allText(final XmlElement root, final String name) {
  return <String>[
    for (final element in root.descendants.whereType<XmlElement>())
      if (element.name.local.toLowerCase() == name && element.innerText.trim().isNotEmpty)
        element.innerText.trim(),
  ];
}

Map<String, String> _userDefined(final XmlElement root) {
  final result = <String, String>{};
  for (final element in root.descendants.whereType<XmlElement>()) {
    if (element.name.local.toLowerCase() != 'user-defined') continue;
    final name = _attribute(element, 'name')?.trim().toLowerCase();
    final value = element.innerText.trim();
    if (name != null && name.isNotEmpty && value.isNotEmpty) result[name] = value;
  }

  return result;
}

List<String> _splitAuthors(final String value) =>
    _splitList(value, RegExp(r'\s*(?:;|&|\band\b)\s*'));

List<String> _splitValues(final String value) => _splitList(value, RegExp(r'\s*(?:;|,)\s*'));

List<String> _splitList(final String value, final Pattern separator) => value
    .split(separator)
    .map((final item) => item.trim())
    .where((final item) => item.isNotEmpty)
    .toList(growable: false);

String _renderContent(
  final XmlDocument document,
  final _StyleCatalog styles,
  final Set<String> referencedImages,
  final String? title,
) {
  final body = _findDescendant(document.rootElement, 'body');
  final text = _findChild(body, 'text');
  if (text == null) {
    throw const InvalidOdtXmlException('content.xml', 'office:body has no office:text');
  }

  final context = _RenderContext(styles, referencedImages);
  final output = StringBuffer()
    ..write('<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head>')
    ..write('<meta charset="utf-8"/>')
    ..write('<title>${escapeHtml(title ?? '')}</title>')
    ..write('</head><body>');

  for (final child in text.children.whereType<XmlElement>()) {
    output.write(_renderBlock(child, context));
  }
  output.write('</body></html>');

  return output.toString();
}

String _renderBlock(final XmlElement element, final _RenderContext context) {
  switch (element.name.local) {
    case 'h':
      final level = _headingLevel(element, context.styles);
      return '<h$level>${_renderInlineChildren(element, context)}</h$level>';
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
  final kind = context.styles.listKind(_attribute(list, 'style-name'));
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
      final span = int.tryParse(_attribute(cell, 'number-columns-spanned') ?? '');
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
      return context.styles.wrap(_attribute(element, 'style-name'), content);
    case 'a':
      final content = _renderInlineChildren(element, context);
      final href = _attribute(element, 'href');
      return href == null || href.isEmpty
          ? content
          : '<a href="${_escapeAttribute(href)}">$content</a>';
    case 's':
      final count = int.tryParse(_attribute(element, 'c') ?? '1') ?? 1;
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
  final image = _findDescendant(frame, 'image');
  if (image == null) return _renderInlineChildren(frame, context);
  final href = _attribute(image, 'href');
  if (href == null || href.isEmpty) return '';
  final path = normalizeZipPath(_decodeResourcePath(href));
  if (path.isEmpty) return '';
  context.referencedImages.add(path);
  final title = _attribute(frame, 'name') ?? 'Image';

  return '<img src="${_escapeAttribute(path)}" alt="${escapeHtml(title)}" />';
}

String _decodeResourcePath(final String href) {
  try {
    return Uri.decodeComponent(href);
  } on FormatException {
    return href;
  }
}

int _headingLevel(final XmlElement element, final _StyleCatalog styles) {
  final outline = int.tryParse(_attribute(element, 'outline-level') ?? '');
  if (outline != null) return _clampHeading(outline);
  final styleName = _attribute(element, 'style-name');
  final style = styles.textStyle(styleName);
  final match = RegExp(
    r'heading\s*([1-9])',
    caseSensitive: false,
  ).firstMatch(style?.name ?? styleName ?? '');
  if (match != null) return _clampHeading(int.parse(match.group(1)!));

  return 1;
}

int _clampHeading(final int value) => value < 1
    ? 1
    : value > 6
    ? 6
    : value;

List<BinaryFile> _readImages(final Archive archive, final Set<String> referencedImages) {
  final result = <BinaryFile>[];
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final path = normalizeZipPath(entry.name);
    final lower = path.toLowerCase();
    final content = contentBytes(entry);
    final isImage =
        lower.startsWith('pictures/') &&
        (sniffImageType(content) != null || _imageExtensions.contains(_extension(path)));
    if (!isImage) continue;
    if (referencedImages.isNotEmpty &&
        !_containsPath(referencedImages, path) &&
        !lower.startsWith('pictures/')) {
      continue;
    }
    result.add(binaryFile(path, content));
  }

  return result;
}

List<BinaryFile> _readFonts(final Archive archive) {
  final result = <BinaryFile>[];
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final path = normalizeZipPath(entry.name);
    if (!path.toLowerCase().startsWith('fonts/')) continue;
    result.add(binaryFile(path, contentBytes(entry)));
  }

  return result;
}

List<BinaryFile> _readOtherBinaryParts(
  final Archive archive,
  final List<BinaryFile> images,
  final List<BinaryFile> fonts,
) {
  final known = <String>{
    ...images.map((final file) => file.path.toLowerCase()),
    ...fonts.map((final file) => file.path.toLowerCase()),
  };
  final result = <BinaryFile>[];
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final path = normalizeZipPath(entry.name);
    final lower = path.toLowerCase();
    if (known.contains(lower) || lower.endsWith('.xml') || lower == 'mimetype') continue;
    result.add(binaryFile(path, contentBytes(entry)));
  }

  return result;
}

List<ArchiveEntry> _archiveEntries(final Archive archive) => <ArchiveEntry>[
  for (final entry in archive.files)
    if (entry.isFile) ArchiveEntry(path: normalizeZipPath(entry.name), size: entry.size),
];

bool _containsPath(final Set<String> paths, final String path) =>
    paths.any((final candidate) => normalizeZipPath(candidate).toLowerCase() == path.toLowerCase());

XmlElement? _findDescendant(final XmlElement root, final String localName) {
  for (final element in root.descendants.whereType<XmlElement>()) {
    if (element.name.local == localName) return element;
  }

  return null;
}

XmlElement? _findChild(final XmlElement? root, final String localName) {
  if (root == null) return null;
  for (final child in root.children.whereType<XmlElement>()) {
    if (child.name.local == localName) return child;
  }

  return null;
}

String? _attribute(final XmlElement? element, final String localName) {
  if (element == null) return null;
  for (final attribute in element.attributes) {
    if (attribute.name.local == localName) return attribute.value;
  }

  return null;
}

String _extension(final String path) {
  final name = path.split('/').last;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

const _imageExtensions = <String>{
  'avif',
  'bmp',
  'gif',
  'jpeg',
  'jpg',
  'png',
  'svg',
  'tif',
  'tiff',
  'webp',
};

final class _RenderContext {
  const _RenderContext(this.styles, this.referencedImages);

  final _StyleCatalog styles;
  final Set<String> referencedImages;
}

final class _OdtStyle {
  const _OdtStyle({
    required this.name,
    this.bold = false,
    this.italic = false,
    this.underline = false,
  });

  final String name;
  final bool bold;
  final bool italic;
  final bool underline;
}

final class _StyleCatalog {
  const _StyleCatalog(this._styles, this._listKinds);

  factory _StyleCatalog.fromDocuments(final XmlDocument? styles, final XmlDocument content) {
    final values = <String, _OdtStyle>{};
    final listKinds = <String, String>{};
    final roots = <XmlElement>[if (styles != null) styles.rootElement, content.rootElement];
    for (final root in roots) {
      for (final element in root.descendants.whereType<XmlElement>()) {
        final local = element.name.local;
        if (local == 'style') {
          final name = _attribute(element, 'name');
          if (name == null || name.isEmpty) continue;
          final properties = _findDescendant(element, 'text-properties');
          values[name] = _OdtStyle(
            name: _attribute(_findChild(element, 'name'), 'name') ?? name,
            bold: _isBold(_attribute(properties, 'font-weight')),
            italic: _isItalic(_attribute(properties, 'font-style')),
            underline: _attribute(properties, 'text-underline-style') != null,
          );
        } else if (local == 'list-style') {
          final name = _attribute(element, 'name');
          if (name == null || name.isEmpty) continue;
          final isNumbered = element.descendants.whereType<XmlElement>().any(
            (final child) =>
                child.name.local == 'level-style-number' ||
                child.name.local == 'list-level-style-number',
          );
          listKinds[name] = isNumbered ? 'ol' : 'ul';
        }
      }
    }

    return _StyleCatalog(values, listKinds);
  }

  final Map<String, _OdtStyle> _styles;
  final Map<String, String> _listKinds;

  _OdtStyle? textStyle(final String? name) => name == null ? null : _styles[name];

  String listKind(final String? name) => name == null ? 'ul' : _listKinds[name] ?? 'ul';

  String wrap(final String? name, final String content) {
    final style = textStyle(name);
    if (style == null || content.isEmpty) return content;
    var wrapped = content;
    if (style.bold) wrapped = '<strong>$wrapped</strong>';
    if (style.italic) wrapped = '<em>$wrapped</em>';
    if (style.underline) wrapped = '<u>$wrapped</u>';
    return wrapped;
  }
}

bool _isBold(final String? value) => value != null && value.toLowerCase() == 'bold';

bool _isItalic(final String? value) => value != null && value.toLowerCase() == 'italic';

String _escapeAttribute(final String value) => escapeHtml(value).replaceAll('&#47;', '/');
