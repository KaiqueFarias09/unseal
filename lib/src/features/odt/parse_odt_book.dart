import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../foundation/archive/archive_access.dart';
import '../../foundation/entities/entities.dart';
import '../../foundation/files/book_file_factory.dart';
import '../../foundation/images/cover_helpers.dart';
import '../../foundation/images/image_type_sniffer.dart';
import '../../foundation/text/html_escape.dart';
import '../../foundation/text/xml_encoding.dart';
import 'exceptions/exceptions.dart';

part 'container/odt_package.dart';
part 'metadata/odt_metadata.dart';
part 'rendering/odt_renderer.dart';
part 'resources/odt_resources.dart';
part 'styles/odt_styles.dart';

/// Parses an OpenDocument Text package into the common document model.
DocumentBook parseOdtBook(final Uint8List bytes) => _parseOdtPackage(_OdtPackage.fromBytes(bytes));

/// Parses an already decoded ODT [archive].
DocumentBook parseOdtArchive(final Archive archive) {
  return _parseOdtPackage(_OdtPackage.fromArchive(archive));
}

/// Reads metadata from an ODT package without rendering the document body.
BookMetadata readOdtMetadata(final Uint8List bytes) {
  return _readOdtPackageMetadata(_OdtPackage.fromBytes(bytes));
}

/// Reads metadata from an already decoded ODT [archive].
BookMetadata readOdtMetadataFromArchive(final Archive archive) {
  return _readOdtPackageMetadata(_OdtPackage.fromArchive(archive));
}

DocumentBook _parseOdtPackage(final _OdtPackage package) {
  final metadata = _readOdtPackageMetadata(package);
  final styles = _OdtStyleCatalog.fromPackage(package);
  final rendered = _renderOdtContent(package, styles, title: metadata.title);
  final resources = _OdtResources.fromPackage(package);
  final content = textFile('content.xhtml', rendered.xhtml, type: 'xhtml');

  return DocumentBook(
    format: BookFormat.odt,
    files: Files(
      images: resources.images,
      css: const <TextFile>[],
      html: <TextFile>[content],
      fonts: resources.fonts,
      others: resources.others,
    ),
    metadata: metadata.copyWith(cover: coverFromBinary(resources.cover)),
    navigation: rendered.navigation,
    cover: resources.cover,
    archiveEntries: resources.archiveEntries,
    order: <String>[content.path],
  );
}
