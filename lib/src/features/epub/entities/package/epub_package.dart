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
  final String uniqueIdentifier;

  /// EPUB package format version.
  final String version;

  /// Dublin Core and EPUB metadata associated with the package.
  final Metadata metadata;

  /// Resources declared in the package manifest.
  final Manifest manifest;

  /// Reading order declared by the package spine.
  final Spine spine;

  /// Namespace URI declared on the package element, when present.
  final String? xmlns;

  /// Optional EPUB 2 guide references.
  final Guide? guide;
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
  final String title;

  /// Publication date as declared by the package document.
  final String date;

  /// Primary language of the publication.
  final String language;

  /// Identifiers declared for the publication.
  final List<String> identifiers;

  /// Value of the package's unique identifier metadata element.
  final String uniqueIdentifierValue;

  /// Primary subject of the publication.
  final String? subject;

  /// Description of the publication.
  final String? description;

  /// Rights statements associated with the publication.
  final List<String>? rights;

  /// Contributor to the publication.
  final String? contributor;

  /// Creator or author of the publication.
  final String? creator;

  /// Publisher of the publication.
  final String? publisher;

  /// EPUB 2 cover manifest item id, from `<meta name="cover" content="id"/>`.
  final String? coverId;

  /// Series name read from a legacy OPF `meta` value.
  final String? series;

  /// Series position read from a legacy OPF `meta` value or EPUB 3 `group-position`.
  final String? seriesIndex;

  /// Sort form of the title, from `opf:file-as` or a legacy OPF `meta` value.
  final String? titleSort;

  /// Sort form of the author (`Last, First`), from `opf:file-as`
  /// or a legacy OPF `meta` value.
  final String? authorSort;

  /// Producer recorded as the `dc:contributor` with role `bkp`.
  final String? bookProducer;
}

/// Resources declared by an EPUB package manifest.
final class Manifest {
  /// Creates a manifest containing [items].
  Manifest({required this.items});

  /// Items declared in the manifest.
  final List<ManifestItem> items;
}

/// A resource declared by an EPUB manifest.
final class ManifestItem {
  /// Creates a manifest item with its archive path, identifier, and media type.
  ManifestItem({
    required this.path,
    required this.id,
    required this.mediaType,
    this.properties = const [],
    this.mediaOverlay,
  });

  /// Path to the resource within the EPUB archive.
  final String path;

  /// Identifier used to reference the resource from the package document.
  final String id;

  /// MIME type declared for the resource.
  final String mediaType;

  /// EPUB properties declared for the resource.
  final List<String> properties;

  /// EPUB 3 `media-overlay` attribute: the manifest id of the SMIL
  /// document narrating this item (media overlays).
  final String? mediaOverlay;

  @override
  String toString() {
    return 'Item(href: $path, id: $id, mediaType: $mediaType)';
  }
}

/// The EPUB reading order and its page-flow direction.
final class Spine {
  /// Creates a spine with an optional table-of-contents identifier.
  Spine({
    required this.tocId,
    required this.items,
    this.pageProgressionDirection = PageProgressionDirection.unspecified,
  });

  /// Manifest identifier of the table of contents, when declared.
  final String? tocId;

  /// Manifest identifiers in reading order.
  final List<String> items;

  /// The spine `page-progression-direction` attribute: `.ltr` or
  /// `.rtl` when the book declares its page flow, `.unspecified` when
  /// the attribute is absent, `default`, or malformed.
  final PageProgressionDirection pageProgressionDirection;

  @override
  String toString() {
    return 'Spine(toc: $tocId, item: $items)';
  }
}

/// EPUB 2 guide containing references to publication sections.
final class Guide {
  /// Creates a guide from its [references].
  Guide({required this.references});

  /// References to publication sections.
  final List<Reference> references;

  @override
  String toString() {
    return 'Guide(references: $references)';
  }
}

/// A section reference from an EPUB 2 guide.
final class Reference {
  /// Creates a guide reference.
  Reference({required this.href, required this.title, required this.type});

  /// Path to the referenced resource.
  final String href;

  /// Human-readable title of the referenced section.
  final String title;

  /// EPUB guide type of the referenced section.
  final String type;

  @override
  String toString() {
    return 'Reference(href: $href, title: $title, type: $type)';
  }
}
