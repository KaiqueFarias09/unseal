/// Immutable model of OPDS 2.0 catalogs (feeds, groups, facets,
/// publications, links, and metadata).
///
/// The model is parsing output only: fetching links, authenticating,
/// purchasing, borrowing, and decryption belong to the host application.
/// Values the supported subset does not map are dropped; see the package
/// documentation for the extension policy.
library;

import 'package:collection/collection.dart';

/// Link relations that mark an acquisition link under OPDS 2.0: the short
/// relations of the specification and their OPDS 1.0 URI equivalents.
const Set<String> opds2AcquisitionRels = <String>{
  'acquisition',
  'borrow',
  'buy',
  'preview',
  'sample',
  'subscribe',
  'http://opds-spec.org/acquisition',
  'http://opds-spec.org/acquisition/buy',
  'http://opds-spec.org/acquisition/open-access',
  'http://opds-spec.org/acquisition/borrow',
  'http://opds-spec.org/acquisition/sample',
  'http://opds-spec.org/acquisition/subscribe',
};

/// Whether [rel] marks an acquisition link under OPDS 2.0.
bool isOpds2AcquisitionRel(final String rel) => opds2AcquisitionRels.contains(rel);

/// The availability states of the OPDS 2.0 link properties.
const Set<String> opds2AvailabilityStates = <String>{
  'available',
  'unavailable',
  'reserved',
  'ready',
};

/// A value that may carry one unlocalized string or a language map
/// (`{"en": ..., "pt-BR": ...}`).
///
/// A plain string is stored under `plain`; a language map under
/// `values`. `resolve` returns the best match for the requested language,
/// falling back to the base language, then to any single value.
final class Opds2LocalizedText {
  /// Creates a value from either form.
  const Opds2LocalizedText.plain(final String value)
    : plain = value,
      values = const <String, String>{};

  /// Creates a value from a language map.
  const Opds2LocalizedText.mapped(this.values) : plain = null;

  /// The unlocalized string, when the source was a plain string.
  final String? plain;

  /// The language map, when the source was an object.
  final Map<String, String> values;

  /// Whether no value is present.
  bool get isEmpty => plain == null && values.isEmpty;

  /// Best value for [language] (BCP 47 tag or undefined): exact tag, then
  /// base language, then any value. Returns null when empty.
  String? resolve({final String? language}) {
    if (plain != null) return plain;
    if (values.isEmpty) return null;
    if (language != null) {
      final exact = values[language];
      if (exact != null) return exact;
      final base = language.split('-').first;
      for (final entry in values.entries) {
        if (entry.key.split('-').first == base) return entry.value;
      }
    }
    return values.values.first;
  }

  @override
  String toString() => plain ?? values.toString();
}

/// One alternate identifier: a raw value or a value with its scheme URI.
final class Opds2AltIdentifier {
  /// Creates an alternate identifier.
  const Opds2AltIdentifier({required this.value, this.scheme});

  /// The identifier value.
  final String value;

  /// The scheme URI, when declared as an object.
  final String? scheme;

  @override
  String toString() => scheme == null ? value : '$scheme$value';
}

/// A person or organization contributing to a feed or publication.
final class Opds2Contributor {
  /// Creates a contributor.
  const Opds2Contributor({
    required this.name,
    this.identifier,
    this.sortAs,
    this.roles = const <String>[],
    this.links = const <Opds2Link>[],
  });

  /// The contributor name.
  final Opds2LocalizedText name;

  /// Canonical identifier (often a URI) of the contributor.
  final String? identifier;

  /// Sort key mapped per language.
  final Opds2LocalizedText? sortAs;

  /// Roles, typically MARC relator codes (`aut`, `trl`, ...).
  final List<String> roles;

  /// Links about the contributor.
  final List<Opds2Link> links;

  @override
  String toString() => 'Opds2Contributor(${name.resolve()})';
}

/// A subject of a publication.
final class Opds2Subject {
  /// Creates a subject.
  const Opds2Subject({
    required this.name,
    this.sortAs,
    this.code,
    this.scheme,
    this.links = const <Opds2Link>[],
  });

  /// The subject name.
  final Opds2LocalizedText name;

  /// Sort key mapped per language.
  final Opds2LocalizedText? sortAs;

  /// Subject code within [scheme].
  final String? code;

  /// URI of the classification scheme.
  final String? scheme;

  /// Links about the subject.
  final List<Opds2Link> links;

  @override
  String toString() => 'Opds2Subject(${name.resolve()})';
}

/// A link target: `href` is kept exactly as written; relative references
/// are data until the host resolves them against an explicit base URL
/// through `resolveOpds2Href`.
final class Opds2Link {
  /// Creates a link.
  const Opds2Link({
    required this.href,
    this.rels = const <String>[],
    this.templated = false,
    this.type,
    this.title,
    this.languages = const <String>[],
    this.height,
    this.width,
    this.size,
    this.bitrate,
    this.duration,
    this.properties,
    this.alternate,
    this.children = const <Opds2Link>[],
  });

  /// URI or URI template of the target, verbatim from the document.
  final String href;

  /// All relations of the link; OPDS 2.0 allows a string or a list.
  final List<String> rels;

  /// Whether the source declared `templated: true`.
  final bool templated;

  /// Media type of the target.
  final String? type;

  /// Display title.
  final String? title;

  /// Expected languages of the target.
  final List<String> languages;

  /// Pixel height of an image resource.
  final int? height;

  /// Pixel width of an image resource.
  final int? width;

  /// Original byte size of the resource.
  final int? size;

  /// Bitrate in kbps.
  final num? bitrate;

  /// Length in seconds.
  final num? duration;

  /// Structured properties, when present.
  final Opds2LinkProperties? properties;

  /// Alternate-exactness flag of the Readium link model, when declared.
  final bool? alternate;

  /// Child links of an acquisition link.
  final List<Opds2Link> children;

  /// Whether the link carries the given relation.
  bool hasRel(final String rel) => rels.contains(rel);

  /// Whether any relation marks an acquisition.
  bool get isAcquisition => rels.any(isOpds2AcquisitionRel);

  /// Whether the source declares the link as a URI template or the href
  /// contains a template expression.
  bool get isTemplate => templated || (href.contains('{') && href.contains('}'));

  /// Whether the href contains a URI template expression.
  bool get hasTemplateExpression => href.contains('{') && href.contains('}');

  @override
  String toString() => 'Opds2Link(${rels.join(', ')} -> $href)';
}

/// Price of an acquisition link.
final class Opds2Price {
  /// Creates a price.
  const Opds2Price({required this.value, this.currency});

  /// Decimal price value.
  final num value;

  /// ISO 4217 currency code.
  final String? currency;

  @override
  String toString() => currency == null ? '$value' : '$value $currency';
}

/// One expected type acquired after additional (indirect) steps.
final class Opds2AcquisitionObject {
  /// Creates an acquisition object.
  const Opds2AcquisitionObject({
    required this.type,
    this.children = const <Opds2AcquisitionObject>[],
  });

  /// Media type expected after this step.
  final String type;

  /// Further indirections.
  final List<Opds2AcquisitionObject> children;

  @override
  String toString() => 'Opds2AcquisitionObject($type)';
}

/// Hold-list information of a library acquisition link.
final class Opds2Holds {
  /// Creates hold information.
  const Opds2Holds({this.total, this.position});

  /// Total number of holds.
  final int? total;

  /// Position of the caller in the hold list.
  final int? position;
}

/// Copy availability of a library acquisition link.
final class Opds2Copies {
  /// Creates copy information.
  const Opds2Copies({this.total, this.available});

  /// Total number of copies.
  final int? total;

  /// Currently available copies.
  final int? available;
}

/// Availability state of an acquisition link.
final class Opds2Availability {
  /// Creates availability information.
  const Opds2Availability({required this.state, this.since, this.until});

  /// One of `available`, `unavailable`, `reserved`, `ready`.
  final String state;

  /// Timestamp of the previous state change.
  final DateTime? since;

  /// Timestamp of the next state change.
  final DateTime? until;

  @override
  String toString() => 'Opds2Availability($state)';
}

/// Encryption information attached to a link.
final class Opds2Encryption {
  /// Creates encryption information.
  const Opds2Encryption({
    required this.algorithm,
    this.compression,
    this.originalLength,
    this.profile,
    this.scheme,
  });

  /// URI identifying the encryption algorithm.
  final String algorithm;

  /// Compression applied before encryption.
  final String? compression;

  /// Original length in bytes before compression and/or encryption.
  final int? originalLength;

  /// URI of the encryption profile.
  final String? profile;

  /// URI of the encryption scheme.
  final String? scheme;
}

/// Structured properties of a link: the OPDS 2.0 acquisition properties
/// plus the Readium EPUB and encryption extension members.
final class Opds2LinkProperties {
  /// Creates link properties.
  const Opds2LinkProperties({
    this.numberOfItems,
    this.price,
    this.indirectAcquisitions = const <Opds2AcquisitionObject>[],
    this.holds,
    this.copies,
    this.availability,
    this.contains = const <String>[],
    this.layout,
    this.encrypted,
    this.page,
  });

  /// Expected number of items behind the link.
  final int? numberOfItems;

  /// Acquisition price.
  final Opds2Price? price;

  /// Expected media types after additional steps.
  final List<Opds2AcquisitionObject> indirectAcquisitions;

  /// Library hold-list information.
  final Opds2Holds? holds;

  /// Library copy information.
  final Opds2Copies? copies;

  /// Availability state.
  final Opds2Availability? availability;

  /// EPUB extension: content markers of the resource (`js`, `mathml`, ...).
  final List<String> contains;

  /// EPUB extension: reflowable or fixed layout hint.
  final String? layout;

  /// Encryption extension: how the resource is encrypted.
  final Opds2Encryption? encrypted;

  /// Synthetic-spread placement (`left`, `right`, `center`).
  final String? page;
}

/// Metadata of a publication (the Readium Web Publication metadata subset).
final class Opds2Metadata {
  /// Creates publication metadata. [title] is required by OPDS 2.0.
  const Opds2Metadata({
    required this.title,
    this.identifier,
    this.altIdentifiers = const <Opds2AltIdentifier>[],
    this.atType,
    this.conformsTo = const <String>[],
    this.sortAs,
    this.subtitle,
    this.modified,
    this.published,
    this.languages = const <String>[],
    this.authors = const <Opds2Contributor>[],
    this.translators = const <Opds2Contributor>[],
    this.editors = const <Opds2Contributor>[],
    this.artists = const <Opds2Contributor>[],
    this.illustrators = const <Opds2Contributor>[],
    this.letterers = const <Opds2Contributor>[],
    this.pencilers = const <Opds2Contributor>[],
    this.colorists = const <Opds2Contributor>[],
    this.inkers = const <Opds2Contributor>[],
    this.narrators = const <Opds2Contributor>[],
    this.contributors = const <Opds2Contributor>[],
    this.publishers = const <Opds2Contributor>[],
    this.imprints = const <Opds2Contributor>[],
    this.subjects = const <Opds2Subject>[],
    this.accessibility,
    this.layout,
    this.readingProgression,
    this.description,
    this.duration,
    this.numberOfPages,
  });

  /// Publication title (string or language map in the source).
  final Opds2LocalizedText title;

  /// Canonical identifier, typically a URI.
  final String? identifier;

  /// Alternate identifiers.
  final List<Opds2AltIdentifier> altIdentifiers;

  /// The source `@type` value.
  final String? atType;

  /// Profile URIs the publication conforms to.
  final List<String> conformsTo;

  /// Sort key mapped per language.
  final Opds2LocalizedText? sortAs;

  /// Subtitle mapped per language.
  final Opds2LocalizedText? subtitle;

  /// Last modification timestamp.
  final DateTime? modified;

  /// Publication date as written (full or partial date, or date-time).
  final String? published;

  /// BCP 47 languages of the publication content.
  final List<String> languages;

  /// Authors.
  final List<Opds2Contributor> authors;

  /// Translators.
  final List<Opds2Contributor> translators;

  /// Editors.
  final List<Opds2Contributor> editors;

  /// Artists.
  final List<Opds2Contributor> artists;

  /// Illustrators.
  final List<Opds2Contributor> illustrators;

  /// Letterers.
  final List<Opds2Contributor> letterers;

  /// Pencilers.
  final List<Opds2Contributor> pencilers;

  /// Colorists.
  final List<Opds2Contributor> colorists;

  /// Inkers.
  final List<Opds2Contributor> inkers;

  /// Narrators.
  final List<Opds2Contributor> narrators;

  /// General contributors.
  final List<Opds2Contributor> contributors;

  /// Publishers.
  final List<Opds2Contributor> publishers;

  /// Imprints.
  final List<Opds2Contributor> imprints;

  /// Subjects.
  final List<Opds2Subject> subjects;

  /// Accessibility object preserved as data; Unseal maps its presence,
  /// hosts interpret its members.
  final Map<String, Object?>? accessibility;

  /// Layout hint (`fixed`, `reflowable`, `scrolled`).
  final String? layout;

  /// Reading progression (`rtl` or `ltr`).
  final String? readingProgression;

  /// Human-readable description.
  final String? description;

  /// Total duration in seconds.
  final num? duration;

  /// Number of pages.
  final int? numberOfPages;

  /// All contributors across every role.
  List<Opds2Contributor> get allContributors => <Opds2Contributor>[
    ...authors,
    ...translators,
    ...editors,
    ...artists,
    ...illustrators,
    ...letterers,
    ...pencilers,
    ...colorists,
    ...inkers,
    ...narrators,
    ...contributors,
    ...publishers,
    ...imprints,
  ];

  @override
  String toString() => 'Opds2Metadata(${title.resolve()})';
}

/// One publication entry of a feed or a standalone publication document.
final class Opds2Publication {
  /// Creates a publication.
  const Opds2Publication({
    required this.metadata,
    this.links = const <Opds2Link>[],
    this.images = const <Opds2Link>[],
  });

  /// Publication metadata.
  final Opds2Metadata metadata;

  /// All links, including acquisition links.
  final List<Opds2Link> links;

  /// Image resources for browsing.
  final List<Opds2Link> images;

  /// Links whose relations mark an acquisition.
  List<Opds2Link> get acquisitionLinks => links.where((final link) => link.isAcquisition).toList();

  /// The first `self` link, when present (recommended for standalone
  /// publication documents).
  Opds2Link? get selfLink => links.firstWhereOrNull((final link) => link.hasRel('self'));

  /// The largest raster image by declared pixel area, preferring the first
  /// one among equals; falls back to the first image of any type.
  Opds2Link? get bestImage {
    if (images.isEmpty) return null;
    Opds2Link? best;
    var bestArea = -1;
    for (final image in images) {
      final area = (image.width ?? 0) * (image.height ?? 0);
      if (area > bestArea) {
        bestArea = area;
        best = image;
      }
    }
    return best ?? images.first;
  }

  @override
  String toString() => 'Opds2Publication(${metadata.title.resolve()})';
}

/// Metadata of a feed, facet, or group (the OPDS feed metadata subset).
final class Opds2FeedMetadata {
  /// Creates feed metadata. [title] is required by OPDS 2.0.
  const Opds2FeedMetadata({
    required this.title,
    this.identifier,
    this.atType,
    this.subtitle,
    this.modified,
    this.description,
    this.numberOfItems,
    this.itemsPerPage,
    this.currentPage,
  });

  /// Title (string or language map in the source).
  final Opds2LocalizedText title;

  /// Canonical identifier, typically a URI.
  final String? identifier;

  /// The source `@type` value.
  final String? atType;

  /// Subtitle mapped per language.
  final Opds2LocalizedText? subtitle;

  /// Last modification timestamp.
  final DateTime? modified;

  /// Human-readable description.
  final String? description;

  /// Total number of items the feed paginates over.
  final int? numberOfItems;

  /// Page size when paginated.
  final int? itemsPerPage;

  /// Current 1-based page number when paginated.
  final int? currentPage;

  @override
  String toString() => 'Opds2FeedMetadata(${title.resolve()})';
}

/// One facet group of a feed.
final class Opds2Facet {
  /// Creates a facet. [metadata] is required: facets must have a title.
  const Opds2Facet({required this.metadata, required this.links});

  /// Facet metadata carrying the required title.
  final Opds2FeedMetadata metadata;

  /// Facet links (one per ordering or subset).
  final List<Opds2Link> links;

  @override
  String toString() => 'Opds2Facet(${metadata.title.resolve()})';
}

/// A curated group of a feed: navigation links, publications, or both.
final class Opds2Group {
  /// Creates a group. [metadata] is required: groups must have a title.
  const Opds2Group({
    required this.metadata,
    this.links = const <Opds2Link>[],
    this.navigation = const <Opds2Link>[],
    this.publications = const <Opds2Publication>[],
  });

  /// Group metadata carrying the required title.
  final Opds2FeedMetadata metadata;

  /// Group-level links, including the optional `self` link.
  final List<Opds2Link> links;

  /// Navigation links of the group.
  final List<Opds2Link> navigation;

  /// Publications of the group.
  final List<Opds2Publication> publications;

  /// The group's `self` link, when present.
  Opds2Link? get selfLink => links.firstWhereOrNull((final link) => link.hasRel('self'));

  @override
  String toString() => 'Opds2Group(${metadata.title.resolve()})';
}

/// An unknown feed member, preserved as a named subcollection: either a
/// full collection object or a compact array of links (nested objects in
/// an array become children keyed by their index).
final class Opds2Subcollection {
  /// Creates a subcollection under [key].
  const Opds2Subcollection({
    required this.key,
    this.metadata = const <String, Object?>{},
    this.links = const <Opds2Link>[],
    this.children = const <String, Opds2Subcollection>{},
  });

  /// The feed member name that produced this subcollection.
  final String key;

  /// Free-form collection metadata, preserved as data.
  final Map<String, Object?> metadata;

  /// Links of the subcollection.
  final List<Opds2Link> links;

  /// Nested subcollections.
  final Map<String, Opds2Subcollection> children;

  @override
  String toString() => 'Opds2Subcollection($key)';
}

/// A parsed OPDS 2.0 feed: navigation, publications, groups, facets, and
/// named subcollections under one metadata and link set.
final class Opds2Feed {
  /// Creates a feed.
  const Opds2Feed({
    required this.metadata,
    required this.links,
    this.navigation = const <Opds2Link>[],
    this.publications = const <Opds2Publication>[],
    this.groups = const <Opds2Group>[],
    this.facets = const <Opds2Facet>[],
    this.subcollections = const <String, Opds2Subcollection>{},
  });

  /// Feed metadata carrying the required title.
  final Opds2FeedMetadata metadata;

  /// Feed-level links (`self`, `next`, `search`, ...).
  final List<Opds2Link> links;

  /// Navigation links.
  final List<Opds2Link> navigation;

  /// Publications listed directly on the feed.
  final List<Opds2Publication> publications;

  /// Curated groups.
  final List<Opds2Group> groups;

  /// Facet groups.
  final List<Opds2Facet> facets;

  /// Unknown members mapped as named subcollections.
  final Map<String, Opds2Subcollection> subcollections;

  /// Whether any listed publication carries acquisition links.
  bool get isAcquisition =>
      publications.any((final publication) => publication.acquisitionLinks.isNotEmpty) ||
      groups.any(
        (final group) =>
            group.publications.any((final publication) => publication.acquisitionLinks.isNotEmpty),
      );

  /// The first link carrying the given relation.
  Opds2Link? linkForRel(final String rel) =>
      links.firstWhereOrNull((final link) => link.hasRel(rel));

  /// The `self` link of the feed.
  Opds2Link? get selfLink => linkForRel('self');

  /// The `next` page link, when the feed is paginated.
  Opds2Link? get nextLink => linkForRel('next');

  /// The `previous` (or `prev`) page link.
  Opds2Link? get previousLink => linkForRel('previous') ?? linkForRel('prev');

  /// The `first` page link.
  Opds2Link? get firstLink => linkForRel('first');

  /// The `last` page link.
  Opds2Link? get lastLink => linkForRel('last');

  /// The `search` link, whose href is a URI template with a `query`
  /// parameter under OPDS 2.0.
  Opds2Link? get searchLink => linkForRel('search');

  @override
  String toString() => 'Opds2Feed(${metadata.title.resolve()})';
}
