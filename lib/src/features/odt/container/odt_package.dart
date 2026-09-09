import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../../foundation/archive/archive_access.dart';
import '../../../foundation/text/xml_encoding.dart';
import '../exceptions/exceptions.dart';

/// Validated ODT container plus its package-level XML documents.
final class OdtPackage {
  OdtPackage._({required this.archive, required this.content, this.meta, this.styles});

  /// Decodes and validates an ODT package from [bytes].
  factory OdtPackage.fromBytes(final Uint8List bytes) {
    if (bytes.isEmpty) throw const InvalidOdtPackageException('ODT package is empty.');

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on Object catch (error) {
      throw InvalidOdtPackageException('ODT package is not a valid ZIP archive: $error');
    }

    return OdtPackage.fromArchive(archive);
  }

  /// Validates an already decoded ODT [archive].
  factory OdtPackage.fromArchive(final Archive archive) {
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
    if (odtFindDescendant(root, 'body') == null) {
      throw InvalidOdtXmlException(contentEntry.name, 'document has no office:body element');
    }

    return OdtPackage._(
      archive: archive,
      content: content,
      meta: _optionalXml(archive, 'meta.xml'),
      styles: _optionalXml(archive, 'styles.xml'),
    );
  }

  /// Underlying decoded ZIP archive.
  final Archive archive;

  /// Required `content.xml` document.
  final XmlDocument content;

  /// Optional `meta.xml` document when it is present and valid.
  final XmlDocument? meta;

  /// Optional `styles.xml` document when it is present and valid.
  final XmlDocument? styles;
}

/// Finds the first descendant whose namespace-local name is [localName].
XmlElement? odtFindDescendant(final XmlElement root, final String localName) {
  for (final element in root.descendants.whereType<XmlElement>()) {
    if (element.name.local == localName) return element;
  }

  return null;
}

/// Finds the first direct child whose namespace-local name is [localName].
XmlElement? odtFindChild(final XmlElement? root, final String localName) {
  if (root == null) return null;
  for (final child in root.children.whereType<XmlElement>()) {
    if (child.name.local == localName) return child;
  }

  return null;
}

/// Reads an attribute by namespace-local [localName].
String? odtAttribute(final XmlElement? element, final String localName) {
  if (element == null) return null;
  for (final attribute in element.attributes) {
    if (attribute.name.local == localName) return attribute.value;
  }

  return null;
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
