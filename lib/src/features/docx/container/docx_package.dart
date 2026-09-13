part of '../parse_docx_book.dart';

/// Decodes a DOCX ZIP payload while preserving the package error contract.
Archive _decodeDocxZip(final Uint8List bytes) {
  try {
    return decodeBookZip(bytes);
  } on Exception catch (error) {
    throw InvalidDocxPackageException('DOCX package is not a valid ZIP archive: $error');
  }
}

/// The validated package parts needed to parse a DOCX document.
final class _DocxPackage {
  /// Creates a validated collection of DOCX package parts.
  _DocxPackage({
    required this.archive,
    required this.document,
    required this.documentXml,
    this.documentRelationships,
    this.styles,
    this.numbering,
    this.coreProperties,
  });

  /// Validates and reads the required and optional DOCX package parts.
  factory _DocxPackage.fromBytes(final Uint8List bytes) {
    if (bytes.isEmpty) throw const InvalidDocxPackageException('DOCX package is empty.');

    return _DocxPackage.fromArchive(_decodeDocxZip(bytes));
  }

  /// Validates and reads the required and optional DOCX package parts.
  factory _DocxPackage.fromArchive(final Archive archive) {
    final document = _findDocxEntry(archive, 'word/document.xml');
    if (document == null) throw const MissingDocxPartException('word/document.xml');

    final documentXml = _parseRequiredXml(document);
    final root = documentXml.rootElement;
    if (root.name.local != 'document') {
      throw InvalidDocxXmlException(
        document.name,
        'root element must be w:document, found ${root.name.qualified}',
      );
    }
    if (_docxChild(root, 'body') == null) {
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

  /// The complete decoded ZIP archive.
  final Archive archive;

  /// The required main document archive entry.
  final ArchiveFile document;

  /// The parsed main WordprocessingML document.
  final XmlDocument documentXml;

  /// Relationships associated with the main document, when readable.
  final XmlDocument? documentRelationships;

  /// Package styles, when present and readable.
  final XmlDocument? styles;

  /// Package numbering definitions, when present and readable.
  final XmlDocument? numbering;

  /// Package core properties, when present and readable.
  final XmlDocument? coreProperties;
}

XmlDocument _parseRequiredXml(final ArchiveFile entry) {
  try {
    return XmlDocument.parse(decodeXmlText(contentBytes(entry)));
  } on Exception catch (error) {
    throw InvalidDocxXmlException(entry.name, error.toString());
  }
}

XmlDocument? _optionalXml(final Archive archive, final String path) {
  final entry = _findDocxEntry(archive, path);
  if (entry == null) return null;

  try {
    return XmlDocument.parse(decodeXmlText(contentBytes(entry)));
  } on Exception {
    // Styles, numbering, relationships and core properties are optional for
    // the useful subset of DOCX packages. A malformed optional part should
    // not hide the readable document body.
    return null;
  }
}

/// Finds a package entry after applying DOCX path normalization.
ArchiveFile? _findDocxEntry(final Archive archive, final String path) {
  final wanted = _normalizeDocxPartPath(path).toLowerCase();
  for (final entry in archive.files) {
    if (entry.isFile && _normalizeDocxPartPath(entry.name).toLowerCase() == wanted) return entry;
  }

  return null;
}

/// Reads an XML attribute by local name, independent of namespace prefix.
String? _docxAttribute(final XmlElement? element, final String localName) {
  if (element == null) return null;

  for (final attribute in element.attributes) {
    if (attribute.name.local == localName) return attribute.value;
  }

  return null;
}

/// Reads a direct XML child by local name, independent of namespace prefix.
XmlElement? _docxChild(final XmlElement? parent, final String localName) {
  if (parent == null) return null;

  for (final child in parent.children.whereType<XmlElement>()) {
    if (child.name.local == localName) return child;
  }

  return null;
}

/// Resolves a relationship target relative to the owning document part.
String _resolveDocxRelationshipTarget(final String documentPath, final String target) {
  if (target.startsWith('/')) return _normalizeDocxPartPath(target.substring(1));

  return _normalizeDocxPartPath('${_dirname(documentPath)}/$target');
}

/// Makes a package target relative to its source document part.
String _relativeDocxPartPath(final String sourcePart, final String targetPart) {
  final sourceDirectory = _dirname(
    sourcePart,
  ).split('/').where((final item) => item.isNotEmpty).toList();
  final target = _normalizeDocxPartPath(
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

/// Normalizes an OPC package path without allowing traversal above its root.
String _normalizeDocxPartPath(final String value) {
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

String _relationshipPath(final String documentPath) {
  final directory = _dirname(documentPath);
  final fileName = documentPath.split('/').last;

  return _normalizeDocxPartPath('$directory/_rels/$fileName.rels');
}

String _dirname(final String value) {
  final slash = value.lastIndexOf('/');

  return slash == -1 ? '' : value.substring(0, slash);
}
