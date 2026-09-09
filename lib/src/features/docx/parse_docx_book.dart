import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../foundation/entities/entities.dart';
import '../../foundation/files/book_file_factory.dart';
import '../../foundation/images/cover_helpers.dart';
import 'container/docx_package.dart';
import 'container/docx_relationships.dart';
import 'exceptions/exceptions.dart';
import 'metadata/docx_metadata.dart';
import 'rendering/docx_renderer.dart';
import 'resources/docx_resources.dart';
import 'styles/docx_styles.dart';

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

  final archive = decodeDocxZip(bytes);

  return parseDocxArchive(archive);
}

/// Parses an already decoded DOCX [archive].
DocumentBook parseDocxArchive(final Archive archive) {
  final package = DocxPackage.fromArchive(archive);
  final metadata = readDocxCoreMetadata(package.coreProperties);
  final relationships = readDocxRelationships(package.documentRelationships, package.document.name);
  final styles = readDocxStyles(package.styles);
  final numbering = readDocxNumbering(package.numbering);
  final rendered = renderDocxDocument(
    package.documentXml,
    package.document.name,
    relationships,
    styles,
    numbering,
    metadata.title,
  );
  final resources = readDocxResources(package.archive, rendered.referencedImages);
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
  if (bytes.isEmpty) {
    throw const InvalidDocxPackageException('DOCX package is empty.');
  }

  return readDocxCoreMetadata(DocxPackage.fromArchive(decodeDocxZip(bytes)).coreProperties);
}

/// Reads only the metadata from an already decoded DOCX [archive].
BookMetadata readDocxMetadataFromArchive(final Archive archive) {
  return readDocxCoreMetadata(DocxPackage.fromArchive(archive).coreProperties);
}
