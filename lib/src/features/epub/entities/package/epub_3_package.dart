import 'epub_package.dart';

/// EPUB 3 package document and its parsed components.
final class Epub3Package extends EpubPackage {
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
final class Epub3Metadata extends Metadata {
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
  final List<String> schemaOrgs;

  /// Accessibility summaries declared for the publication.
  final List<String> accessibilitySummaries;

  /// Accessibility features declared for the publication.
  final List<String> accessibilityFeatures;

  /// Educational role assigned to the publication.
  final String educationalRole;

  /// Typical age range for the publication.
  final String typicalAgeRange;

  /// Last modification timestamp declared by the EPUB package.
  final String modified;

  /// Rendition metadata declared for the publication.
  final String rendition;

  /// Collection to which the publication belongs.
  final String belongsToCollection;

  /// Source publication or resource for this publication.
  final String sourceOf;

  /// Record identifier for the publication.
  final String recordIdentifier;

  /// Total overlay duration from `<meta property="media:duration">`
  /// (EPUB 3 media overlays).
  final String mediaDuration;

  /// CSS class the reading system toggles on the currently narrated
  /// element (`media:active-class`).
  final String mediaActiveClass;

  /// CSS class applied while playback is active
  /// (`media:playback-active-class`).
  final String mediaPlaybackActiveClass;

  /// Narrator of the audio narration (`dc:narrator`).
  final String narrator;
}
