import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/src/features/odt/container/odt_package.dart';
import 'package:e_livre/src/features/odt/metadata/odt_metadata.dart';
import 'package:e_livre/src/features/odt/rendering/odt_renderer.dart';
import 'package:e_livre/src/features/odt/resources/odt_resources.dart';
import 'package:e_livre/src/features/odt/styles/odt_styles.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/files/book_file_factory.dart';
import 'package:e_livre/src/foundation/images/cover_helpers.dart';
import 'package:e_livre/src/foundation/navigation/html_navigation.dart';

export 'package:e_livre/src/features/odt/metadata/odt_metadata.dart'
    show readOdtMetadata, readOdtMetadataFromArchive;

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
