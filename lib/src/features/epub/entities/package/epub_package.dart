// Base classes

import 'page_progression_direction.dart';

/// Base representation of an EPUB package document.
abstract class EpubPackage {
  /// Creates an EPUB package from its package-document components.
  EpubPackage({
    required this.version,
    required this.metadata,
    required this.manifest,
    required this.spine,
    required this.uniqueIdentifier,
    this.guide,
    this.xmlns,
  });

  /// Unique identifier declared by the package document.
  String uniqueIdentifier;

  /// EPUB package format version.
  String version;

  /// Dublin Core and EPUB metadata associated with the package.
  Metadata metadata;

  /// Resources declared in the package manifest.
  Manifest manifest;

  /// Reading order declared by the package spine.
  Spine spine;

  /// Namespace URI declared on the package element, when present.
  String? xmlns;

  /// Optional EPUB 2 guide references.
  Guide? guide;
}

/// Metadata extracted from an EPUB package document.
abstract class Metadata {
  /// Creates metadata with the package's core descriptive fields.
  Metadata({
    required this.title,
    required this.date,
    required this.language,
    required this.identifiers,
    required this.uniqueIdentifierValue,
    this.rights,
    this.contributor,
    this.creator,
    this.publisher,
    this.subject,
    this.description,
    this.coverId,
    this.series,
    this.seriesIndex,
    this.titleSort,
    this.authorSort,
    this.bookProducer,
  });

  /// Title of the publication.
  String title;

  /// Publication date as declared by the package document.
  String date;

  /// Primary language of the publication.
  String language;

  /// Identifiers declared for the publication.
  List<String> identifiers;

  /// Value of the package's unique identifier metadata element.
  String uniqueIdentifierValue;

  /// Primary subject of the publication.
  String? subject;

  /// Description of the publication.
  String? description;

  /// Rights statements associated with the publication.
  List<String>? rights;

  /// Contributor to the publication.
  String? contributor;

  /// Creator or author of the publication.
  String? creator;

  /// Publisher of the publication.
  String? publisher;

  /// EPUB 2 cover manifest item id, from `<meta name="cover" content="id"/>`.
  String? coverId;

  /// Series name from `calibre:series` (or EPUB 3 collections).
  String? series;

  /// Series position from `calibre:series_index` (or `group-position`).
  String? seriesIndex;

  /// Sort form of the title, from `opf:file-as` or `calibre:title_sort`.
  String? titleSort;

  /// Sort form of the author (`Last, First`), from `opf:file-as`
  /// or `calibre:author_sort`.
  String? authorSort;

  /// Producer recorded as the `dc:contributor` with role `bkp`.
  String? bookProducer;
}

/// Resources declared by an EPUB package manifest.
abstract class Manifest {
  /// Creates a manifest containing [items].
  Manifest({required this.items});

  /// Items declared in the manifest.
  List<ManifestItem> items;
}

/// A resource declared by an EPUB manifest.
class ManifestItem {
  /// Creates a manifest item with its archive path, identifier, and media type.
  ManifestItem({
    required this.path,
    required this.id,
    required this.mediaType,
    this.properties = const [],
    this.mediaOverlay,
  });

  /// Path to the resource within the EPUB archive.
  String path;

  /// Identifier used to reference the resource from the package document.
  String id;

  /// MIME type declared for the resource.
  String mediaType;

  /// EPUB properties declared for the resource.
  List<String> properties;

  /// EPUB 3 `media-overlay` attribute: the manifest id of the SMIL
  /// document narrating this item (media overlays).
  String? mediaOverlay;

  @override
  String toString() {
    return 'Item(href: $path, id: $id, mediaType: $mediaType)';
  }
}

/// The EPUB reading order and its page-flow direction.
class Spine {
  /// Creates a spine with an optional table-of-contents identifier.
  Spine({
    required this.tocId,
    required this.items,
    this.pageProgressionDirection = PageProgressionDirection.unspecified,
  });

  /// Manifest identifier of the table of contents, when declared.
  String? tocId;

  /// Manifest identifiers in reading order.
  List<String> items;

  /// The spine `page-progression-direction` attribute: `.ltr` or
  /// `.rtl` when the book declares its page flow, `.unspecified` when
  /// the attribute is absent, `default`, or malformed.
  PageProgressionDirection pageProgressionDirection;

  @override
  String toString() {
    return 'Spine(toc: $tocId, item: $items)';
  }
}

/// EPUB 2 guide containing references to publication sections.
class Guide {
  /// Creates a guide from its [references].
  Guide({required this.references});

  /// References to publication sections.
  List<Reference> references;

  @override
  String toString() {
    return 'Guide(references: $references)';
  }
}

/// A section reference from an EPUB 2 guide.
class Reference {
  /// Creates a guide reference.
  Reference({required this.href, required this.title, required this.type});

  /// Path to the referenced resource.
  String href;

  /// Human-readable title of the referenced section.
  String title;

  /// EPUB guide type of the referenced section.
  String type;

  @override
  String toString() {
    return 'Reference(href: $href, title: $title, type: $type)';
  }
}
