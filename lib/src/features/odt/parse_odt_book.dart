import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../foundation/entities/entities.dart';
import '../../foundation/files/book_file_factory.dart';
import '../../foundation/images/cover_helpers.dart';
import '../../foundation/navigation/html_navigation.dart';
import 'container/odt_package.dart';
import 'metadata/odt_metadata.dart';
import 'rendering/odt_renderer.dart';
import 'resources/odt_resources.dart';
import 'styles/odt_styles.dart';

export 'metadata/odt_metadata.dart' show readOdtMetadata, readOdtMetadataFromArchive;

/// Parses an OpenDocument Text package into the common document model.
DocumentBook parseOdtBook(final Uint8List bytes) => _parseOdtPackage(OdtPackage.fromBytes(bytes));

/// Parses an already decoded ODT [archive].
DocumentBook parseOdtArchive(final Archive archive) =>
    _parseOdtPackage(OdtPackage.fromArchive(archive));

DocumentBook _parseOdtPackage(final OdtPackage package) {
  final metadata = readOdtPackageMetadata(package);
  final styles = OdtStyleCatalog.fromPackage(package);
  final rendered = renderOdtContent(package, styles, title: metadata.title);
  final resources = OdtResources.fromPackage(package, referencedImages: rendered.referencedImages);
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
    navigation: htmlNavigation(rendered.xhtml, title: metadata.title ?? ''),
    cover: resources.cover,
    archiveEntries: resources.archiveEntries,
    order: <String>[content.path],
  );
}
