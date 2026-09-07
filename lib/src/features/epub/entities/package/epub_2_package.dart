import 'package:e_livre/src/features/epub/entities/package/epub_package.dart';

/// EPUB 2 package document and its parsed components.
class Epub2Package extends EpubPackage {
  /// Creates an EPUB 2 package.
  Epub2Package({
    required super.version,
    required super.metadata,
    required super.manifest,
    required super.spine,
    required super.guide,
    required super.uniqueIdentifier,
    required super.xmlns,
  });

  @override
  String toString() {
    return 'Package(xmlns: $xmlns, uniqueIdentifier: $uniqueIdentifier, version: $version, metadata: $metadata, manifest: $manifest, spine: $spine, guide: $guide)';
  }
}

/// EPUB 2 manifest.
class Epub2Manifest extends Manifest {
  /// Creates an EPUB 2 manifest from its items.
  Epub2Manifest({required super.items});
}

/// EPUB 2 metadata.
class Epub2Metadata extends Metadata {
  /// Creates EPUB 2 metadata from its package-document fields.
  Epub2Metadata({
    required super.rights,
    required super.contributor,
    required super.creator,
    required super.publisher,
    required super.title,
    required super.date,
    required super.language,
    required super.subject,
    required super.description,
    required super.identifiers,
    required super.uniqueIdentifierValue,
    super.coverId,
    super.series,
    super.seriesIndex,
    super.titleSort,
    super.authorSort,
    super.bookProducer,
  });

  @override
  String toString() {
    return 'Metadata(rights: $rights, contributor: $contributor, creator: $creator, publisher: $publisher, title: $title, date: $date, language: $language, subject: $subject, description: $description, identifier: $identifiers)';
  }
}
