import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import '../../foundation/archive/archive_access.dart';
import '../../foundation/entities/entities.dart';
import '../../foundation/files/book_file_factory.dart';
import '../../foundation/images/cover_helpers.dart';
import '../../foundation/text/xml_encoding.dart';
import 'exceptions/exceptions.dart';

part 'container/docx_package.dart';
part 'container/docx_relationships.dart';
part 'metadata/docx_metadata.dart';
part 'rendering/docx_renderer.dart';
part 'resources/docx_resources.dart';
part 'styles/docx_styles.dart';

/// Parses a DOCX package into the common document-backed book model.
///
/// The parser intentionally supports the interoperable WordprocessingML
/// surface used by ordinary Word/LibreOffice documents: paragraphs, basic
/// run formatting, heading styles, numbering, tables, line breaks and images
/// referenced through `word/_rels/document.xml.rels`. Unsupported Word
/// extensions remain absent from the generated XHTML instead of making the
/// complete document unreadable.
DocumentBook parseDocxBook(final Uint8List bytes) {
  return _parseDocxPackage(_DocxPackage.fromBytes(bytes));
}

/// Parses an already decoded DOCX [archive].
DocumentBook parseDocxArchive(final Archive archive) {
  return _parseDocxPackage(_DocxPackage.fromArchive(archive));
}

DocumentBook _parseDocxPackage(final _DocxPackage package) {
  final metadata = _readDocxCoreMetadata(package.coreProperties);
  final relationships = _readDocxRelationships(
    package.documentRelationships,
    package.document.name,
  );
  final styles = _readDocxStyles(package.styles);
  final numbering = _readDocxNumbering(package.numbering);
  final rendered = _renderDocxDocument(
    package.documentXml,
    package.document.name,
    relationships,
    styles,
    numbering,
    metadata.title,
  );
  final resources = _readDocxResources(package.archive, rendered.referencedImages);
  final cover = firstImageCover(resources.images);
  final html = textFile('word/document.xhtml', rendered.xhtml, type: 'xhtml');

  return DocumentBook(
    format: BookFormat.docx,
    files: Files(
      images: resources.images,
      css: const <TextFile>[],
      html: <TextFile>[html],
      fonts: resources.fonts,
      others: resources.others,
    ),
    metadata: metadata.copyWith(cover: coverFromBinary(cover)),
    navigation: rendered.navigation,
    cover: cover,
    archiveEntries: resources.archiveEntries,
    order: <String>[html.path],
  );
}

/// Reads only the metadata from a DOCX package.
///
/// The required `word/document.xml` part is still validated so callers do
/// not accidentally accept a random ZIP containing a core-properties file.
BookMetadata readDocxMetadata(final Uint8List bytes) {
  final package = _DocxPackage.fromBytes(bytes);

  return _readDocxCoreMetadata(package.coreProperties);
}

/// Reads only the metadata from an already decoded DOCX [archive].
BookMetadata readDocxMetadataFromArchive(final Archive archive) {
  final package = _DocxPackage.fromArchive(archive);

  return _readDocxCoreMetadata(package.coreProperties);
}
