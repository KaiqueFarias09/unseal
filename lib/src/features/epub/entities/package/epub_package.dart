// Base classes

import 'package:e_livre/src/features/epub/entities/package/page_progression_direction.dart';

abstract class EpubPackage {
  EpubPackage({
    required this.version,
    required this.metadata,
    required this.manifest,
    required this.spine,
    required this.uniqueIdentifier,
    this.guide,
    this.xmlns,
  });

  String uniqueIdentifier;
  String version;
  Metadata metadata;
  Manifest manifest;
  Spine spine;
  String? xmlns;
  Guide? guide;
}

abstract class Metadata {
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

  String title;
  String date;
  String language;
  List<String> identifiers;
  String uniqueIdentifierValue;
  String? subject;
  String? description;
  List<String>? rights;
  String? contributor;
  String? creator;
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

abstract class Manifest {
  Manifest({required this.items});

  List<ManifestItem> items;
}

class ManifestItem {
  ManifestItem({
    required this.path,
    required this.id,
    required this.mediaType,
    this.properties = const [],
    this.mediaOverlay,
  });

  String path;
  String id;
  String mediaType;
  List<String> properties;

  /// EPUB 3 `media-overlay` attribute: the manifest id of the SMIL
  /// document narrating this item (media overlays).
  String? mediaOverlay;

  @override
  String toString() {
    return 'Item(href: $path, id: $id, mediaType: $mediaType)';
  }
}

class Spine {
  Spine({
    required this.tocId,
    required this.items,
    this.pageProgressionDirection = PageProgressionDirection.unspecified,
  });

  String? tocId;
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

class Guide {
  Guide({required this.references});

  List<Reference> references;

  @override
  String toString() {
    return 'Guide(references: $references)';
  }
}

class Reference {
  Reference({required this.href, required this.title, required this.type});

  String href;
  String title;
  String type;

  @override
  String toString() {
    return 'Reference(href: $href, title: $title, type: $type)';
  }
}
