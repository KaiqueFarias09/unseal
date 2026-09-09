import 'epub_package.dart';

/// EPUB 3 package document and its parsed components.
class Epub3Package extends EpubPackage {
  /// Creates an EPUB 3 package.
  Epub3Package({
    required super.version,
    required super.metadata,
    required super.manifest,
    required super.spine,
    required super.uniqueIdentifier,
    required super.xmlns,
    required this.tocId,
    super.guide,
  });

  /// On some EPUB 3.0 files the table of contents is declared on the manifest
  /// element; in others it is defined in the spine element.
  final String? tocId;
}

/// EPUB 3 metadata, including accessibility and media-overlay fields.
class Epub3Metadata extends Metadata {
  /// Creates EPUB 3 metadata from its package-document fields.
  Epub3Metadata({
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
    required this.schemaOrgs,
    required this.accessibilitySummaries,
    required this.educationalRole,
    required this.typicalAgeRange,
    required this.accessibilityFeatures,
    required this.modified,
    required this.rendition,
    required this.belongsToCollection,
    required this.sourceOf,
    required this.recordIdentifier,
    this.mediaDuration = '',
    this.mediaActiveClass = '',
    this.mediaPlaybackActiveClass = '',
    this.narrator = '',
    super.coverId,
    super.series,
    super.seriesIndex,
    super.titleSort,
    super.authorSort,
    super.bookProducer,
  });

  /// Schema.org vocabulary values declared for the publication.
  List<String> schemaOrgs;

  /// Accessibility summaries declared for the publication.
  List<String> accessibilitySummaries;

  /// Accessibility features declared for the publication.
  List<String> accessibilityFeatures;

  /// Educational role assigned to the publication.
  String educationalRole;

  /// Typical age range for the publication.
  String typicalAgeRange;

  /// Last modification timestamp declared by the EPUB package.
  String modified;

  /// Rendition metadata declared for the publication.
  String rendition;

  /// Collection to which the publication belongs.
  String belongsToCollection;

  /// Source publication or resource for this publication.
  String sourceOf;

  /// Record identifier for the publication.
  String recordIdentifier;

  /// Total overlay duration from `<meta property="media:duration">`
  /// (EPUB 3 media overlays).
  String mediaDuration;

  /// CSS class the reading system toggles on the currently narrated
  /// element (`media:active-class`).
  String mediaActiveClass;

  /// CSS class applied while playback is active
  /// (`media:playback-active-class`).
  String mediaPlaybackActiveClass;

  /// Narrator of the audio narration (`dc:narrator`).
  String narrator;
}

/// EPUB 3 manifest with package-level properties.
class Epub3Manifest extends Manifest {
  /// Creates an EPUB 3 manifest.
  Epub3Manifest({required super.items, required this.properties});

  /// Properties declared on the EPUB 3 manifest element.
  final String properties;
}
