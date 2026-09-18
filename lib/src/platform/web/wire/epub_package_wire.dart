import '../../../features/epub/entities/package/epub_2_package.dart';
import '../../../features/epub/entities/package/epub_3_package.dart';
import '../../../features/epub/entities/package/epub_package.dart';
import '../../../features/epub/entities/package/page_progression_direction.dart';

/// Encodes an EPUB package and its nested manifest, spine, guide, and metadata.
Map<String, Object?> encodeEpubPackageWireValue(final EpubPackage package) {
  return <String, Object?>{
    'kind': package is Epub3Package ? 3 : 2,
    'version': package.version,
    'xmlns': package.xmlns,
    'uniqueIdentifier': package.uniqueIdentifier,
    'tocId': package is Epub3Package ? package.tocId : null,
    'metadata': _encodePackageMetadata(package),
    'manifest': <String, Object?>{
      'items': <Object?>[
        for (final item in package.manifest.items)
          <String, Object?>{
            'path': item.path,
            'id': item.id,
            'mediaType': item.mediaType,
            'properties': List<String>.of(item.properties),
            'mediaOverlay': item.mediaOverlay,
          },
      ],
    },
    'spine': <String, Object?>{
      'tocId': package.spine.tocId,
      'items': List<String>.of(package.spine.items),
      'pageProgressionDirection': package.spine.pageProgressionDirection.name,
    },
    'guide': package.guide == null
        ? null
        : <String, Object?>{
            'references': <Object?>[
              for (final reference in package.guide!.references)
                <String, Object?>{
                  'href': reference.href,
                  'title': reference.title,
                  'type': reference.type,
                },
            ],
          },
  };
}

Map<String, Object?> _encodePackageMetadata(final EpubPackage package) {
  final metadata = package.metadata;

  return <String, Object?>{
    'kind': metadata is Epub3Metadata ? 3 : 2,
    'title': metadata.title,
    'date': metadata.date,
    'language': metadata.language,
    'identifiers': List<String>.of(metadata.identifiers),
    'uniqueIdentifierValue': metadata.uniqueIdentifierValue,
    'subject': metadata.subject,
    'description': metadata.description,
    'rights': metadata.rights == null ? null : List<String>.of(metadata.rights!),
    'contributor': metadata.contributor,
    'creator': metadata.creator,
    'publisher': metadata.publisher,
    'coverId': metadata.coverId,
    'series': metadata.series,
    'seriesIndex': metadata.seriesIndex,
    'titleSort': metadata.titleSort,
    'authorSort': metadata.authorSort,
    'bookProducer': metadata.bookProducer,
    if (metadata is Epub3Metadata) ...<String, Object?>{
      'schemaOrgs': List<String>.of(metadata.schemaOrgs),
      'accessibilitySummaries': List<String>.of(metadata.accessibilitySummaries),
      'accessibilityFeatures': List<String>.of(metadata.accessibilityFeatures),
      'educationalRole': metadata.educationalRole,
      'typicalAgeRange': metadata.typicalAgeRange,
      'modified': metadata.modified,
      'rendition': metadata.rendition,
      'belongsToCollection': metadata.belongsToCollection,
      'sourceOf': metadata.sourceOf,
      'recordIdentifier': metadata.recordIdentifier,
      'mediaDuration': metadata.mediaDuration,
      'mediaActiveClass': metadata.mediaActiveClass,
      'mediaPlaybackActiveClass': metadata.mediaPlaybackActiveClass,
      'narrator': metadata.narrator,
    },
  };
}

/// Decodes an EPUB package from its wire-map representation.
EpubPackage decodeEpubPackageWireValue(final Map<String, Object?> json) {
  final isEpub3 = json['kind'] == 3;
  final manifestJson = json['manifest'] as Map<String, Object?>;
  final manifest = Manifest(items: _decodeManifestItems(manifestJson['items'] as List<Object?>));
  final metadataJson = json['metadata'] as Map<String, Object?>;
  final metadata = metadataJson['kind'] == 3
      ? _decodeEpub3Metadata(metadataJson)
      : _decodeEpub2Metadata(metadataJson);
  final guideJson = json['guide'] as Map<String, Object?>?;
  final guide = guideJson == null
      ? null
      : Guide(
          references: <Reference>[
            for (final reference in guideJson['references'] as List<Object?>)
              _decodeReference(reference as Map<String, Object?>),
          ],
        );
  final spineJson = json['spine'] as Map<String, Object?>;

  return isEpub3
      ? Epub3Package(
          version: json['version'] as String,
          xmlns: json['xmlns'] as String?,
          uniqueIdentifier: json['uniqueIdentifier'] as String,
          metadata: metadata,
          manifest: manifest,
          spine: _decodeSpine(spineJson),
          tocId: json['tocId'] as String?,
          guide: guide,
        )
      : Epub2Package(
          version: json['version'] as String,
          xmlns: json['xmlns'] as String?,
          uniqueIdentifier: json['uniqueIdentifier'] as String,
          metadata: metadata,
          manifest: manifest,
          spine: _decodeSpine(spineJson),
          guide: guide,
        );
}

List<ManifestItem> _decodeManifestItems(final List<Object?> json) {
  return <ManifestItem>[for (final item in json) _decodeManifestItem(item as Map<String, Object?>)];
}

ManifestItem _decodeManifestItem(final Map<String, Object?> json) {
  return ManifestItem(
    path: json['path'] as String,
    id: json['id'] as String,
    mediaType: json['mediaType'] as String,
    properties: (json['properties'] as List<Object?>?)?.cast<String>() ?? const <String>[],
    mediaOverlay: json['mediaOverlay'] as String?,
  );
}

Spine _decodeSpine(final Map<String, Object?> json) {
  return Spine(
    tocId: json['tocId'] as String?,
    items: (json['items'] as List<Object?>).cast<String>(),
    pageProgressionDirection: PageProgressionDirection.fromName(
      json['pageProgressionDirection'] as String?,
    ),
  );
}

Reference _decodeReference(final Map<String, Object?> json) {
  return Reference(
    href: json['href'] as String,
    title: json['title'] as String,
    type: json['type'] as String,
  );
}

Epub2Metadata _decodeEpub2Metadata(final Map<String, Object?> json) {
  return Epub2Metadata(
    title: json['title'] as String,
    date: json['date'] as String,
    language: json['language'] as String,
    identifiers: (json['identifiers'] as List<Object?>).cast<String>(),
    uniqueIdentifierValue: json['uniqueIdentifierValue'] as String,
    subject: json['subject'] as String?,
    description: json['description'] as String?,
    rights: (json['rights'] as List<Object?>?)?.cast<String>(),
    contributor: json['contributor'] as String?,
    creator: json['creator'] as String?,
    publisher: json['publisher'] as String?,
    coverId: json['coverId'] as String?,
    series: json['series'] as String?,
    seriesIndex: json['seriesIndex'] as String?,
    titleSort: json['titleSort'] as String?,
    authorSort: json['authorSort'] as String?,
    bookProducer: json['bookProducer'] as String?,
  );
}

Epub3Metadata _decodeEpub3Metadata(final Map<String, Object?> json) {
  return Epub3Metadata(
    title: json['title'] as String,
    date: json['date'] as String,
    language: json['language'] as String,
    identifiers: (json['identifiers'] as List<Object?>).cast<String>(),
    uniqueIdentifierValue: json['uniqueIdentifierValue'] as String,
    subject: json['subject'] as String?,
    description: json['description'] as String?,
    rights: (json['rights'] as List<Object?>?)?.cast<String>(),
    contributor: json['contributor'] as String?,
    creator: json['creator'] as String?,
    publisher: json['publisher'] as String?,
    coverId: json['coverId'] as String?,
    series: json['series'] as String?,
    seriesIndex: json['seriesIndex'] as String?,
    titleSort: json['titleSort'] as String?,
    authorSort: json['authorSort'] as String?,
    bookProducer: json['bookProducer'] as String?,
    schemaOrgs: (json['schemaOrgs'] as List<Object?>?)?.cast<String>() ?? const <String>[],
    accessibilitySummaries:
        (json['accessibilitySummaries'] as List<Object?>?)?.cast<String>() ?? const <String>[],
    accessibilityFeatures:
        (json['accessibilityFeatures'] as List<Object?>?)?.cast<String>() ?? const <String>[],
    educationalRole: (json['educationalRole'] as String?) ?? '',
    typicalAgeRange: (json['typicalAgeRange'] as String?) ?? '',
    modified: (json['modified'] as String?) ?? '',
    rendition: (json['rendition'] as String?) ?? '',
    belongsToCollection: (json['belongsToCollection'] as String?) ?? '',
    sourceOf: (json['sourceOf'] as String?) ?? '',
    recordIdentifier: (json['recordIdentifier'] as String?) ?? '',
    mediaDuration: (json['mediaDuration'] as String?) ?? '',
    mediaActiveClass: (json['mediaActiveClass'] as String?) ?? '',
    mediaPlaybackActiveClass: (json['mediaPlaybackActiveClass'] as String?) ?? '',
    narrator: (json['narrator'] as String?) ?? '',
  );
}
