import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/src/features/docx/exceptions/exceptions.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/utils/document_helpers.dart';
import 'package:e_livre/src/foundation/utils/xml_encoding.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

/// Parses a DOCX package into the common document-backed book model.
///
/// The parser intentionally supports the interoperable WordprocessingML
/// surface used by ordinary Word/LibreOffice documents: paragraphs, basic
/// run formatting, heading styles, numbering, tables, line breaks and images
/// referenced through `word/_rels/document.xml.rels`. Unsupported Word
/// extensions remain absent from the generated XHTML instead of making the
/// complete document unreadable.
DocumentBook parseDocxBook(final Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const InvalidDocxPackageException('DOCX package is empty.');
  }

  final archive = _decodeZip(bytes);

  return parseDocxArchive(archive);
}

/// Parses an already decoded DOCX [archive].
DocumentBook parseDocxArchive(final Archive archive) {
  final package = _DocxPackage.fromArchive(archive);
  final metadata = _readMetadata(package.coreProperties);
  final relationships = _readRelationships(package.documentRelationships, package.document.name);
  final styles = _readStyles(package.styles);
  final numbering = _readNumbering(package.numbering);
  final referencedImages = <String>{};
  final xhtml = _renderDocument(
    package.documentXml,
    package.document.name,
    relationships,
    styles,
    numbering,
    referencedImages,
    metadata.title,
  );
  final images = _readImages(package.archive, referencedImages);
  final cover = firstImageCover(images);
  final fonts = _readFonts(package.archive);
  final others = _readOtherBinaryParts(package.archive, images, fonts);
  final html = _textFile('word/document.xhtml', xhtml, type: 'xhtml');
  final navigation = _htmlNavigation(xhtml, title: metadata.title ?? '');

  return DocumentBook(
    format: BookFormat.docx,
    files: Files(
      images: images,
      css: const <TextFile>[],
      html: <TextFile>[html],
      fonts: fonts,
      others: others,
    ),
    metadata: metadata.copyWith(cover: coverFromBinary(cover)),
    navigation: navigation,
    cover: cover,
    archiveEntries: _archiveEntries(package.archive),
    order: <String>[html.path],
  );
}

/// Reads only the metadata from a DOCX package.
///
/// The required `word/document.xml` part is still validated so callers do
/// not accidentally accept a random ZIP containing a core-properties file.
BookMetadata readDocxMetadata(final Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const InvalidDocxPackageException('DOCX package is empty.');
  }

  return _readMetadata(_DocxPackage.fromArchive(_decodeZip(bytes)).coreProperties);
}

/// Reads only the metadata from an already decoded DOCX [archive].
BookMetadata readDocxMetadataFromArchive(final Archive archive) {
  return _readMetadata(_DocxPackage.fromArchive(archive).coreProperties);
}

Archive _decodeZip(final Uint8List bytes) {
  try {
    return ZipDecoder().decodeBytes(bytes);
  } on Object catch (error) {
    throw InvalidDocxPackageException('DOCX package is not a valid ZIP archive: $error');
  }
}

final class _DocxPackage {
  _DocxPackage({
    required this.archive,
    required this.document,
    required this.documentXml,
    this.documentRelationships,
    this.styles,
    this.numbering,
    this.coreProperties,
  });

  factory _DocxPackage.fromArchive(final Archive archive) {
    final document = _findEntry(archive, 'word/document.xml');
    if (document == null) {
      throw const MissingDocxPartException('word/document.xml');
    }

    final documentXml = _parseRequiredXml(document);
    final root = documentXml.rootElement;
    if (root.name.local != 'document') {
      throw InvalidDocxXmlException(
        document.name,
        'root element must be w:document, found ${root.name.qualified}',
      );
    }
    if (_child(root, 'body') == null) {
      throw InvalidDocxXmlException(document.name, 'w:document has no w:body element');
    }

    return _DocxPackage(
      archive: archive,
      document: document,
      documentXml: documentXml,
      documentRelationships: _optionalXml(archive, _relationshipPath(document.name)),
      styles: _optionalXml(archive, 'word/styles.xml'),
      numbering: _optionalXml(archive, 'word/numbering.xml'),
      coreProperties: _optionalXml(archive, 'docProps/core.xml'),
    );
  }

  final Archive archive;
  final ArchiveFile document;
  final XmlDocument documentXml;
  final XmlDocument? documentRelationships;
  final XmlDocument? styles;
  final XmlDocument? numbering;
  final XmlDocument? coreProperties;
}

XmlDocument _parseRequiredXml(final ArchiveFile entry) {
  try {
    return XmlDocument.parse(decodeXmlText(_entryBytes(entry)));
  } on Object catch (error) {
    throw InvalidDocxXmlException(entry.name, error.toString());
  }
}

XmlDocument? _optionalXml(final Archive archive, final String path) {
  final entry = _findEntry(archive, path);
  if (entry == null) return null;

  try {
    return XmlDocument.parse(decodeXmlText(_entryBytes(entry)));
  } on Object {
    // Styles, numbering, relationships and core properties are optional for
    // the useful subset of DOCX packages. A malformed optional part should
    // not hide the readable document body.
    return null;
  }
}

BookMetadata _readMetadata(final XmlDocument? document) {
  if (document == null) return const BookMetadata(format: BookFormat.docx);

  final root = document.rootElement;
  final title = _firstText(root, 'title');
  final creator = _firstText(root, 'creator');
  final subject = _firstText(root, 'subject');
  final description = _firstText(root, 'description');
  final language = _firstText(root, 'language');
  final identifier = _firstText(root, 'identifier');
  final created = _firstText(root, 'created');
  final modified = _firstText(root, 'modified');
  final rights = _firstText(root, 'rights');

  return BookMetadata(
    format: BookFormat.docx,
    title: title,
    authors: _splitAuthors(creator),
    subjects: _splitValues(subject),
    description: description,
    languages: language == null ? const <String>[] : <String>[language],
    publishedAt: DateTime.tryParse(created ?? '') ?? DateTime.tryParse(modified ?? ''),
    identifiers: identifier == null
        ? const <String, String>{}
        : <String, String>{'identifier': identifier},
    rights: rights,
  );
}

List<String> _splitAuthors(final String? value) {
  if (value == null || value.trim().isEmpty) return const <String>[];

  return value
      .split(RegExp(r'\s*(?:;|&|\band\b)\s*', caseSensitive: false))
      .map((final author) => author.trim())
      .where((final author) => author.isNotEmpty)
      .toList(growable: false);
}

List<String> _splitValues(final String? value) {
  if (value == null || value.trim().isEmpty) return const <String>[];

  return value
      .split(RegExp(r'\s*(?:;|,)\s*'))
      .map((final item) => item.trim())
      .where((final item) => item.isNotEmpty)
      .toList(growable: false);
}

String? _firstText(final XmlElement root, final String localName) {
  for (final element in root.descendants.whereType<XmlElement>()) {
    if (element.name.local != localName) continue;
    final value = element.innerText.trim();
    if (value.isNotEmpty) return value;
  }

  return null;
}

Map<String, _DocxRelationship> _readRelationships(
  final XmlDocument? document,
  final String documentPath,
) {
  if (document == null) return const <String, _DocxRelationship>{};

  final result = <String, _DocxRelationship>{};
  final basePath = _dirname(documentPath);
  for (final element in document.rootElement.children.whereType<XmlElement>()) {
    if (element.name.local != 'Relationship') continue;
    final id = _attribute(element, 'Id');
    final target = _attribute(element, 'Target');
    if (id == null || target == null || id.isEmpty || target.isEmpty) continue;
    final external = (_attribute(element, 'TargetMode') ?? '').toLowerCase() == 'external';
    result[id] = _DocxRelationship(
      target: external ? target : _resolvePartPath(basePath, target),
      external: external,
    );
  }

  return result;
}

Map<String, _DocxStyle> _readStyles(final XmlDocument? document) {
  if (document == null) return const <String, _DocxStyle>{};

  final result = <String, _DocxStyle>{};
  for (final element in document.rootElement.children.whereType<XmlElement>()) {
    if (element.name.local != 'style') continue;
    final id = _attribute(element, 'styleId');
    if (id == null || id.isEmpty) continue;
    final name = _attribute(_child(element, 'name'), 'val') ?? id;
    final outline = int.tryParse(
      _attribute(_child(_child(element, 'pPr'), 'outlineLvl'), 'val') ?? '',
    );
    result[id] = _DocxStyle(name: name, outlineLevel: outline);
  }

  return result;
}

_DocxNumbering _readNumbering(final XmlDocument? document) {
  if (document == null) return const _DocxNumbering.empty();

  final abstractFormats = <String, Map<int, String>>{};
  for (final abstractNum in document.rootElement.children.whereType<XmlElement>()) {
    if (abstractNum.name.local != 'abstractNum') continue;
    final abstractId = _attribute(abstractNum, 'abstractNumId');
    if (abstractId == null) continue;
    final levels = <int, String>{};
    for (final level in abstractNum.children.whereType<XmlElement>()) {
      if (level.name.local != 'lvl') continue;
      final ilvl = int.tryParse(_attribute(level, 'ilvl') ?? '');
      final numFmt = _child(level, 'numFmt');
      final format = _attribute(numFmt, 'val');
      if (ilvl != null && format != null) levels[ilvl] = format;
    }
    abstractFormats[abstractId] = levels;
  }

  final numFormats = <int, Map<int, String>>{};
  for (final num in document.rootElement.children.whereType<XmlElement>()) {
    if (num.name.local != 'num') continue;
    final numId = int.tryParse(_attribute(num, 'numId') ?? '');
    final abstractId = _attribute(_child(num, 'abstractNumId'), 'val');
    if (numId == null || abstractId == null) continue;
    numFormats[numId] = abstractFormats[abstractId] ?? const <int, String>{};
  }

  return _DocxNumbering(numFormats);
}

String _renderDocument(
  final XmlDocument document,
  final String documentPath,
  final Map<String, _DocxRelationship> relationships,
  final Map<String, _DocxStyle> styles,
  final _DocxNumbering numbering,
  final Set<String> referencedImages,
  final String? title,
) {
  final body = _child(document.rootElement, 'body');
  if (body == null) {
    throw InvalidDocxXmlException(document.rootElement.name.qualified, 'w:document has no w:body');
  }

  final context = _RenderContext(
    documentPath: documentPath,
    relationships: relationships,
    referencedImages: referencedImages,
  );
  final output = StringBuffer()
    ..write('<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head>')
    ..write('<meta charset="utf-8"/>')
    ..write('<title>${_escapeHtml(title ?? '')}</title>')
    ..write('</head><body>');

  String? listKind;
  int? listId;
  void closeList() {
    if (listKind == null) return;
    output.write('</$listKind>');
    listKind = null;
    listId = null;
  }

  for (final element in body.children.whereType<XmlElement>()) {
    if (element.name.local == 'p') {
      final list = _listInfo(element, numbering);
      if (list != null) {
        if (listKind != list.kind || listId != list.numId) {
          closeList();
          listKind = list.kind;
          listId = list.numId;
          output.write('<$listKind>');
        }
        output.write(
          '<li data-list-level="${list.level}">${_renderParagraphContent(element, context, styles)}</li>',
        );
      } else {
        closeList();
        output.write(_renderParagraph(element, context, styles));
      }
    } else if (element.name.local == 'tbl') {
      closeList();
      output.write(_renderTable(element, context, styles));
    }
  }
  closeList();

  output.write('</body></html>');

  return output.toString();
}

String _renderParagraph(
  final XmlElement paragraph,
  final _RenderContext context,
  final Map<String, _DocxStyle> styles,
) {
  final level = _headingLevel(paragraph, styles);
  final content = _renderParagraphContent(paragraph, context, styles);
  if (level != null) {
    context.headingCount++;
    return '<h$level id="heading-${context.headingCount}">$content</h$level>';
  }

  return '<p>$content</p>';
}

String _renderParagraphContent(
  final XmlElement paragraph,
  final _RenderContext context,
  final Map<String, _DocxStyle> styles,
) {
  final output = StringBuffer();
  for (final child in paragraph.children.whereType<XmlElement>()) {
    if (child.name.local == 'pPr') continue;
    output.write(_renderInline(child, context, styles));
  }

  return output.isEmpty ? '&nbsp;' : output.toString();
}

String _renderInline(
  final XmlElement element,
  final _RenderContext context,
  final Map<String, _DocxStyle> styles,
) {
  switch (element.name.local) {
    case 'r':
      return _renderRun(element, context);
    case 'hyperlink':
      final content = _renderChildren(element, context, styles);
      final relationshipId = _attribute(element, 'id');
      final relationship = relationshipId == null ? null : context.relationships[relationshipId];
      if (relationship == null || relationship.external == false) return content;
      return '<a href="${_escapeHtml(relationship.target)}">$content</a>';
    case 'fldSimple':
    case 'smartTag':
    case 'sdt':
    case 'customXml':
    case 'ins':
    case 'moveFrom':
    case 'moveTo':
      return _renderChildren(element, context, styles);
    case 'proofErr':
    case 'bookmarkStart':
    case 'bookmarkEnd':
      return '';
    default:
      return _renderChildren(element, context, styles);
  }
}

String _renderChildren(
  final XmlElement parent,
  final _RenderContext context,
  final Map<String, _DocxStyle> styles,
) {
  final output = StringBuffer();
  for (final child in parent.children.whereType<XmlElement>()) {
    output.write(_renderInline(child, context, styles));
  }

  return output.toString();
}

String _renderRun(final XmlElement run, final _RenderContext context) {
  final properties = _child(run, 'rPr');
  final output = StringBuffer();
  for (final child in run.children.whereType<XmlElement>()) {
    switch (child.name.local) {
      case 'rPr':
        break;
      case 't':
      case 'delText':
        output.write(_escapeHtml(child.innerText));
      case 'tab':
        output.write('&#9;');
      case 'br':
      case 'cr':
        output.write('<br/>');
      case 'noBreakHyphen':
        output.write('&#8209;');
      case 'softHyphen':
        output.write('&#173;');
      case 'drawing':
      case 'pict':
      case 'object':
        output.write(_renderImage(child, context));
      case 'sym':
        final char = _attribute(child, 'char');
        if (char != null && char.length >= 4) {
          final value = int.tryParse(char.substring(char.length - 4), radix: 16);
          if (value != null) output.write(_escapeHtml(String.fromCharCode(value)));
        }
    }
  }

  if (output.isEmpty) return '';

  var content = output.toString();
  if (_onOff(properties, 'b')) content = '<strong>$content</strong>';
  if (_onOff(properties, 'i')) content = '<em>$content</em>';
  if (_onOff(properties, 'u')) content = '<u>$content</u>';
  if (_onOff(properties, 'strike')) content = '<del>$content</del>';

  final vertical = _attribute(_child(properties, 'vertAlign'), 'val');
  if (vertical == 'superscript') content = '<sup>$content</sup>';
  if (vertical == 'subscript') content = '<sub>$content</sub>';

  final styles = <String>[];
  final color = _attribute(_child(properties, 'color'), 'val');
  if (color != null && color.toLowerCase() != 'auto' && _isHexColor(color)) {
    styles.add('color:#${color.toLowerCase()}');
  }
  final highlight = _attribute(_child(properties, 'highlight'), 'val');
  if (highlight != null) styles.add('background-color:${_highlightColor(highlight)}');
  final size = double.tryParse(_attribute(_child(properties, 'sz'), 'val') ?? '');
  if (size != null && size > 0) styles.add('font-size:${size / 2}pt');
  if (_onOff(properties, 'smallCaps')) styles.add('font-variant:small-caps');

  final rtl = _onOff(properties, 'rtl');
  if (styles.isNotEmpty || rtl) {
    final attributes = <String>[];
    if (styles.isNotEmpty) attributes.add('style="${_escapeHtml(styles.join(';'))}"');
    if (rtl) attributes.add('dir="rtl"');
    content = '<span ${attributes.join(' ')}>$content</span>';
  }

  return content;
}

String _renderImage(final XmlElement container, final _RenderContext context) {
  String? relationshipId;
  for (final element in container.descendants.whereType<XmlElement>()) {
    if (element.name.local != 'blip' && element.name.local != 'imagedata') continue;
    relationshipId = _attribute(element, 'embed') ?? _attribute(element, 'id');
    if (relationshipId != null) break;
  }
  if (relationshipId == null) return '';

  final relationship = context.relationships[relationshipId];
  if (relationship == null || relationship.external) return '';
  context.referencedImages.add(relationship.target);
  final source = _relativePartPath(context.documentPath, relationship.target);
  final alt = _imageAlt(container);

  return '<img src="${_escapeHtml(source)}" alt="${_escapeHtml(alt)}" />';
}

String _imageAlt(final XmlElement container) {
  for (final element in container.descendants.whereType<XmlElement>()) {
    if (element.name.local != 'docPr') continue;
    final descr = _attribute(element, 'descr');
    if (descr != null && descr.isNotEmpty) return descr;
    final name = _attribute(element, 'name');
    if (name != null && name.isNotEmpty) return name;
  }

  return 'Image';
}

String _renderTable(
  final XmlElement table,
  final _RenderContext context,
  final Map<String, _DocxStyle> styles,
) {
  final output = StringBuffer('<table class="docx-table"><tbody>');
  for (final row in table.children.whereType<XmlElement>()) {
    if (row.name.local != 'tr') continue;
    output.write('<tr>');
    for (final cell in row.children.whereType<XmlElement>()) {
      if (cell.name.local != 'tc') continue;
      final cellProperties = _child(cell, 'tcPr');
      final span = int.tryParse(_attribute(_child(cellProperties, 'gridSpan'), 'val') ?? '');
      final attributes = span != null && span > 1 ? ' colspan="$span"' : '';
      output.write('<td$attributes>');
      var rendered = false;
      for (final child in cell.children.whereType<XmlElement>()) {
        if (child.name.local == 'tcPr') continue;
        if (child.name.local == 'p') {
          output.write(_renderParagraph(child, context, styles));
          rendered = true;
        } else if (child.name.local == 'tbl') {
          output.write(_renderTable(child, context, styles));
          rendered = true;
        }
      }
      if (!rendered) output.write('&nbsp;');
      output.write('</td>');
    }
    output.write('</tr>');
  }
  output.write('</tbody></table>');

  return output.toString();
}

int? _headingLevel(final XmlElement paragraph, final Map<String, _DocxStyle> styles) {
  final properties = _child(paragraph, 'pPr');
  final styleId = _attribute(_child(properties, 'pStyle'), 'val');
  final style = styleId == null ? null : styles[styleId];
  final styleName = style?.name ?? styleId ?? '';
  final match = RegExp(r'heading\s*([1-9])', caseSensitive: false).firstMatch(styleName);
  if (match != null) return _clampHeading(int.parse(match.group(1)!));
  if (style?.outlineLevel != null) return _clampHeading(style!.outlineLevel! + 1);

  final directOutline = int.tryParse(_attribute(_child(properties, 'outlineLvl'), 'val') ?? '');
  if (directOutline != null) return _clampHeading(directOutline + 1);

  return null;
}

int _clampHeading(final int value) => value < 1
    ? 1
    : value > 6
    ? 6
    : value;

_ListInfo? _listInfo(final XmlElement paragraph, final _DocxNumbering numbering) {
  final properties = _child(paragraph, 'pPr');
  final numProperties = _child(properties, 'numPr');
  if (numProperties == null) return null;
  final numId = int.tryParse(_attribute(_child(numProperties, 'numId'), 'val') ?? '');
  if (numId == null) return null;
  final level = int.tryParse(_attribute(_child(numProperties, 'ilvl'), 'val') ?? '') ?? 0;
  final format = numbering.format(numId, level);
  final kind = format == 'bullet' || format == 'none' ? 'ul' : 'ol';

  return _ListInfo(numId: numId, level: level, kind: kind);
}

bool _onOff(final XmlElement? parent, final String localName) {
  final value = _attribute(_child(parent, localName), 'val');
  if (value == null) return _child(parent, localName) != null;
  return value != '0' && value.toLowerCase() != 'false' && value.toLowerCase() != 'off';
}

bool _isHexColor(final String value) => RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(value);

String _highlightColor(final String value) {
  const colors = <String, String>{
    'black': '#000000',
    'blue': '#0000ff',
    'cyan': '#00ffff',
    'darkBlue': '#00008b',
    'darkCyan': '#008b8b',
    'darkGray': '#a9a9a9',
    'darkGreen': '#006400',
    'darkMagenta': '#8b008b',
    'darkRed': '#8b0000',
    'darkYellow': '#b8860b',
    'gray': '#808080',
    'green': '#008000',
    'lightGray': '#d3d3d3',
    'magenta': '#ff00ff',
    'red': '#ff0000',
    'white': '#ffffff',
    'yellow': '#ffff00',
  };

  return colors[value] ?? value;
}

List<BinaryFile> _readImages(final Archive archive, final Set<String> referencedImages) {
  final result = <BinaryFile>[];
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final path = _normalizePartPath(entry.name);
    final underMedia = path.toLowerCase().startsWith('word/media/');
    final referenced = referencedImages.any(
      (final target) => target.toLowerCase() == path.toLowerCase(),
    );
    if (!referenced && (!underMedia || !_isImagePath(path))) continue;
    result.add(_binaryFile(path, _entryBytes(entry)));
  }

  return result;
}

List<BinaryFile> _readFonts(final Archive archive) {
  final result = <BinaryFile>[];
  for (final entry in archive.files) {
    if (!entry.isFile) continue;
    final path = _normalizePartPath(entry.name);
    if (!path.toLowerCase().startsWith('word/fonts/') || !_isFontPath(path)) continue;
    result.add(_binaryFile(path, _entryBytes(entry)));
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
    final path = _normalizePartPath(entry.name);
    final lower = path.toLowerCase();
    if (known.contains(lower) || lower.endsWith('.xml') || lower.endsWith('.rels')) continue;
    result.add(_binaryFile(path, _entryBytes(entry)));
  }

  return result;
}

List<ArchiveEntry> _archiveEntries(final Archive archive) => <ArchiveEntry>[
  for (final entry in archive.files)
    if (entry.isFile) ArchiveEntry(path: _normalizePartPath(entry.name), size: entry.size),
];

ArchiveFile? _findEntry(final Archive archive, final String path) {
  final wanted = _normalizePartPath(path).toLowerCase();
  for (final entry in archive.files) {
    if (entry.isFile && _normalizePartPath(entry.name).toLowerCase() == wanted) return entry;
  }

  return null;
}

Uint8List _entryBytes(final ArchiveFile entry) {
  final content = entry.content;

  return content is Uint8List
      ? Uint8List.sublistView(content)
      : Uint8List.fromList(content as List<int>);
}

String? _attribute(final XmlElement? element, final String localName) {
  if (element == null) return null;
  for (final attribute in element.attributes) {
    if (attribute.name.local == localName) return attribute.value;
  }

  return null;
}

XmlElement? _child(final XmlElement? parent, final String localName) {
  if (parent == null) return null;
  for (final child in parent.children.whereType<XmlElement>()) {
    if (child.name.local == localName) return child;
  }

  return null;
}

String _relationshipPath(final String documentPath) {
  final directory = _dirname(documentPath);
  final fileName = documentPath.split('/').last;

  return _normalizePartPath('$directory/_rels/$fileName.rels');
}

String _resolvePartPath(final String baseDirectory, final String target) {
  if (target.startsWith('/')) return _normalizePartPath(target.substring(1));

  return _normalizePartPath('$baseDirectory/$target');
}

String _relativePartPath(final String sourcePart, final String targetPart) {
  final sourceDirectory = _dirname(
    sourcePart,
  ).split('/').where((final item) => item.isNotEmpty).toList();
  final target = _normalizePartPath(
    targetPart,
  ).split('/').where((final item) => item.isNotEmpty).toList();
  var common = 0;
  while (common < sourceDirectory.length &&
      common < target.length &&
      sourceDirectory[common] == target[common]) {
    common++;
  }
  final result = <String>[
    ...List<String>.filled(sourceDirectory.length - common, '..'),
    ...target.skip(common),
  ];

  return result.join('/');
}

String _dirname(final String value) {
  final slash = value.lastIndexOf('/');

  return slash == -1 ? '' : value.substring(0, slash);
}

String _normalizePartPath(final String value) {
  final parts = <String>[];
  for (final segment in value.replaceAll('\\', '/').split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(segment);
  }

  return parts.join('/');
}

bool _isImagePath(final String path) {
  final lower = path.toLowerCase();

  return lower.endsWith('.bmp') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.svg') ||
      lower.endsWith('.tif') ||
      lower.endsWith('.tiff') ||
      lower.endsWith('.webp');
}

bool _isFontPath(final String path) {
  final lower = path.toLowerCase();

  return lower.endsWith('.otf') ||
      lower.endsWith('.ttf') ||
      lower.endsWith('.woff') ||
      lower.endsWith('.woff2');
}

String _escapeHtml(final String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

TextFile _textFile(final String path, final String content, {final String? type}) {
  final name = path.split('/').last;

  return TextFile(
    content: content,
    name: name,
    type: type ?? (name.contains('.') ? name.split('.').last.toLowerCase() : ''),
    path: path,
  );
}

BinaryFile _binaryFile(final String path, final List<int> bytes) {
  final name = path.split('/').last;

  return BinaryFile(
    content: bytes is Uint8List ? Uint8List.sublistView(bytes) : Uint8List.fromList(bytes),
    name: name,
    type: name.contains('.') ? name.split('.').last.toLowerCase() : '',
    path: path,
  );
}

Navigation _htmlNavigation(final String source, {required final String title}) {
  final document = html_parser.parse(source);
  final headings = document.querySelectorAll('h1,h2,h3,h4,h5,h6');
  final roots = <NavPoint>[];
  final stack = <(int, NavPoint)>[];
  var order = 0;
  for (final heading in headings) {
    final label = heading.text.trim();
    if (label.isEmpty) continue;
    final localName = heading.localName ?? 'h1';
    final level = int.tryParse(localName.substring(1)) ?? 1;
    final id = heading.attributes['id'] ?? 'heading-${order + 1}';
    final point = NavPoint(
      classAttribute: localName,
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

final class _DocxRelationship {
  const _DocxRelationship({required this.target, required this.external});

  final String target;
  final bool external;
}

final class _DocxStyle {
  const _DocxStyle({required this.name, this.outlineLevel});

  final String name;
  final int? outlineLevel;
}

final class _DocxNumbering {
  const _DocxNumbering(this._formats);

  const _DocxNumbering.empty() : _formats = const <int, Map<int, String>>{};

  final Map<int, Map<int, String>> _formats;

  String format(final int numId, final int level) => _formats[numId]?[level] ?? 'decimal';
}

final class _ListInfo {
  const _ListInfo({required this.numId, required this.level, required this.kind});

  final int numId;
  final int level;
  final String kind;
}

final class _RenderContext {
  _RenderContext({
    required this.documentPath,
    required this.relationships,
    required this.referencedImages,
  });

  final String documentPath;
  final Map<String, _DocxRelationship> relationships;
  final Set<String> referencedImages;
  int headingCount = 0;
}
