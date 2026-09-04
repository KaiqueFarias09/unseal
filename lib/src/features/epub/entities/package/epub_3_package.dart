import 'package:e_livre/src/features/epub/entities/package/epub_package.dart';

class Epub3Package extends EpubPackage {
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

  // On some EPUB 3.0 files the tocPath is present directly on the manifest
  // element, but in others it is defined in the spine element instead
  final String? tocId;
}

class Epub3Metadata extends Metadata {
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

  List<String> schemaOrgs;
  List<String> accessibilitySummaries;
  List<String> accessibilityFeatures;
  String educationalRole;
  String typicalAgeRange;
  String modified;
  String rendition;
  String belongsToCollection;
  String sourceOf;
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

class Epub3Manifest extends Manifest {
  Epub3Manifest({required super.items, required this.properties});

  final String properties;
}
