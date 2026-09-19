import 'package:collection/collection.dart';
import 'package:xml/xml.dart';

import '../codec/epub_xml.dart';
import '../entities/entities.dart';
import '../exceptions/exceptions.dart';

const _opfNamespace = 'http://www.idpf.org/2007/opf';
const _dcNamespace = 'http://purl.org/dc/elements/1.1/';

/// Parses an OPF package document from [xml].
///
/// Missing navigation metadata is allowed; callers can represent it as an
/// empty table of contents while still reading the spine.
EpubPackage parsePackage(final String xml) {
  final document = XmlDocument.parse(xml);
  final namespaceUri = document.rootElement.namespaceUri;
  final package = document.findElements('package', namespaceUri: namespaceUri).firstOrNull;
  _validate(package, 'package');
  final version = package!.getAttribute('version')?.trim() ?? '2.0';

  final metadataElement = package.findElements('metadata', namespaceUri: namespaceUri).firstOrNull;
  _validate(metadataElement, 'metadata');

  final manifestElement = package.findElements('manifest', namespaceUri: namespaceUri).firstOrNull;
  _validate(manifestElement, 'manifest');
  final spineElement = package.findElements('spine', namespaceUri: namespaceUri).firstOrNull;
  _validate(spineElement, 'spine');

  final uniqueIdentifierProperty = package.getAttribute('unique-identifier') ?? 'uuid_id';
  final metadata = _parseMetadata(metadataElement!, version, uniqueIdentifierProperty);
  final manifestItems = _parseManifestItems(manifestElement!, namespaceUri);
  final spine = _parseSpine(spineElement!);
  final xmlns = package.getAttribute('xmlns');
  final guideElement = package.findElements('guide', namespaceUri: namespaceUri).firstOrNull;
  final guide = guideElement != null ? _parseGuide(guideElement) : null;
  if (_isEpub2(version)) {
    return Epub2Package(
      xmlns: xmlns,
      uniqueIdentifier: uniqueIdentifierProperty,
      version: version,
      metadata: metadata,
      manifest: Manifest(items: manifestItems),
      spine: spine,
      guide: guide,
    );
  }

  final navigationItem = manifestElement
      .findElements('item')
      .firstWhereOrNull((final element) => _propertiesOf(element).contains('nav'));

  return Epub3Package(
    xmlns: xmlns,
    uniqueIdentifier: uniqueIdentifierProperty,
    version: version,
    metadata: metadata,
    manifest: Manifest(items: manifestItems),
    spine: spine,
    guide: guide,
    tocId: navigationItem?.getAttribute('id') ?? spine.tocId,
  );
}

/// Parses an OPF package from its encoded archive bytes.
EpubPackage parsePackageBytes(final List<int> bytes) => parsePackage(decodeEpubText(bytes));

void _validate(final XmlElement? item, final String name) {
  if (item != null) return;

  throw EpubException('EPUB parsing package error: No $name element found.');
}

Metadata _parseMetadata(
  final XmlElement metadataElement,
  final String version,
  final String uniqueIdentifierProperty,
) {
  final metaElements = _metadataMetaElements(metadataElement);
  final common = _readCommonMetadata(
    metadataElement,
    version: version,
    uniqueIdentifierProperty: uniqueIdentifierProperty,
    metaElements: metaElements,
  );

  if (_isEpub2(version)) {
    return _buildEpub2Metadata(common);
  }

  return _buildEpub3Metadata(metadataElement, metaElements, common);
}

final class _EpubCommonMetadata {
  const _EpubCommonMetadata({
    required this.rights,
    required this.contributor,
    required this.creator,
    required this.publisher,
    required this.title,
    required this.date,
    required this.language,
    required this.subject,
    required this.description,
    required this.identifiers,
    required this.uniqueIdentifierValue,
    required this.coverId,
    required this.series,
    required this.seriesIndex,
    required this.titleSort,
    required this.authorSort,
    required this.bookProducer,
  });

  final List<String> rights;
  final String contributor;
  final String creator;
  final String publisher;
  final String title;
  final String date;
  final String language;
  final String subject;
  final String description;
  final List<String> identifiers;
  final String uniqueIdentifierValue;
  final String? coverId;
  final String? series;
  final String? seriesIndex;
  final String? titleSort;
  final String? authorSort;
  final String? bookProducer;
}

_EpubCommonMetadata _readCommonMetadata(
  final XmlElement metadataElement, {
  required final String version,
  required final String uniqueIdentifierProperty,
  required final List<XmlElement> metaElements,
}) {
  final identifierElements = _dcElements(metadataElement, 'identifier').toList();
  final identifiers = _dcTexts(metadataElement, 'identifier');
  final uniqueIdentifierValue = _uniqueIdentifierValue(
    identifierElements,
    identifiers,
    uniqueIdentifierProperty,
  );
  final series = _readSeries(metaElements, version);
  final sorts = _readSorts(metadataElement, metaElements);

  return _EpubCommonMetadata(
    rights: _dcTexts(metadataElement, 'rights'),
    contributor: _dcText(metadataElement, 'contributor'),
    creator: _dcText(metadataElement, 'creator'),
    publisher: _opfText(metadataElement, 'publisher', 'dc:publisher'),
    title: _dcText(metadataElement, 'title'),
    date: _opfText(metadataElement, 'date', 'dc:date'),
    language: _dcText(metadataElement, 'language'),
    subject: _firstText(metadataElement, 'subject', fallback: 'type'),
    description: _dcText(metadataElement, 'description'),
    identifiers: identifiers,
    uniqueIdentifierValue: uniqueIdentifierValue,
    coverId: _coverId(metadataElement),
    series: series.name,
    seriesIndex: series.index,
    titleSort: sorts.title,
    authorSort: sorts.author,
    bookProducer: _bookProducerOf(metadataElement, metaElements),
  );
}

List<XmlElement> _metadataMetaElements(final XmlElement metadataElement) {
  return <XmlElement>[
    // Series and sort metadata can use either the OPF namespace or no namespace.
    ...metadataElement.findElements('meta', namespaceUri: _opfNamespace),
    ...metadataElement.findElements('meta'),
  ];
}

String _dcText(final XmlElement metadataElement, final String name) {
  return _dcElements(metadataElement, name).firstOrNull?.innerText.trim() ?? '';
}

List<String> _dcTexts(final XmlElement metadataElement, final String name) {
  return _dcElements(metadataElement, name)
      .map((final element) => element.innerText.trim())
      .where((final value) => value.isNotEmpty)
      .toList();
}

String _opfText(final XmlElement metadataElement, final String name, final String property) {
  return _dcText(metadataElement, name).isNotEmpty
      ? _dcText(metadataElement, name)
      : metadataElement
                .findElements('meta')
                .firstWhereOrNull((final element) => element.getAttribute('property') == property)
                ?.innerText
                .trim() ??
            '';
}

String _firstText(
  final XmlElement metadataElement,
  final String name, {
  required final String fallback,
}) {
  final value = _dcText(metadataElement, name);

  return value.isEmpty ? _dcText(metadataElement, fallback) : value;
}

String _uniqueIdentifierValue(
  final List<XmlElement> identifierElements,
  final List<String> identifiers,
  final String uniqueIdentifierProperty,
) {
  return identifierElements
          .firstWhereOrNull(
            (final element) => element.getAttribute('id') == uniqueIdentifierProperty,
          )
          ?.innerText
          .trim() ??
      (identifiers.isEmpty ? '' : identifiers.first);
}

String? _coverId(final XmlElement metadataElement) {
  return metadataElement
      .findElements('meta')
      .firstWhereOrNull((final element) {
        return element.getAttribute('name') == 'cover' &&
            (element.getAttribute('content') ?? '').isNotEmpty;
      })
      ?.getAttribute('content');
}

({String? name, String? index}) _readSeries(
  final List<XmlElement> metaElements,
  final String version,
) {
  String? series;
  String? seriesIndex;
  for (final meta in metaElements) {
    final name = meta.getAttribute('name');
    final property = meta.getAttribute('property');
    if (name == null && property == null) continue;

    final value = meta.getAttribute('content') ?? meta.innerText.trim();
    if (value.isEmpty) continue;
    if (name == 'calibre:series' || property == 'calibre:series') {
      series ??= value;
    } else if (name == 'calibre:series_index' || property == 'calibre:series_index') {
      seriesIndex ??= value;
    } else if (property == 'group-position' && !_isEpub2(version)) {
      seriesIndex ??= value;
    }
  }

  return (name: series, index: seriesIndex);
}

({String? title, String? author}) _readSorts(
  final XmlElement metadataElement,
  final List<XmlElement> metaElements,
) {
  final titleElement = metadataElement
      .findElements('title', namespaceUri: _dcNamespace)
      .firstOrNull;
  final creatorElement = metadataElement
      .findElements('creator', namespaceUri: _dcNamespace)
      .firstOrNull;

  return (
    title:
        _fileAsOf(titleElement, metaElements) ??
        _normalize(_namedMeta(metaElements, 'calibre:title_sort')),
    author:
        _fileAsOf(creatorElement, metaElements) ??
        _normalize(_namedMeta(metaElements, 'calibre:author_sort')),
  );
}

Epub2Metadata _buildEpub2Metadata(final _EpubCommonMetadata common) {
  return Epub2Metadata(
    rights: common.rights,
    contributor: common.contributor,
    creator: common.creator,
    publisher: common.publisher,
    title: common.title,
    date: common.date,
    language: common.language,
    subject: common.subject,
    description: common.description,
    identifiers: common.identifiers,
    uniqueIdentifierValue: common.uniqueIdentifierValue,
    coverId: common.coverId,
    series: common.series,
    seriesIndex: common.seriesIndex,
    titleSort: common.titleSort,
    authorSort: common.authorSort,
    bookProducer: common.bookProducer,
  );
}

Epub3Metadata _buildEpub3Metadata(
  final XmlElement metadataElement,
  final List<XmlElement> metaElements,
  final _EpubCommonMetadata common,
) {
  final details = _readEpub3Details(metadataElement);

  return Epub3Metadata(
    rights: common.rights,
    contributor: common.contributor,
    creator: common.creator,
    publisher: common.publisher,
    title: common.title,
    date: common.date,
    language: common.language,
    subject: common.subject,
    description: common.description,
    identifiers: common.identifiers,
    coverId: common.coverId,
    series: common.series,
    seriesIndex: common.seriesIndex,
    schemaOrgs: details.schemaOrgs,
    accessibilitySummaries: details.accessibilitySummaries,
    educationalRole: details.educationalRole,
    typicalAgeRange: details.typicalAgeRange,
    accessibilityFeatures: details.accessibilityFeatures,
    uniqueIdentifierValue: common.uniqueIdentifierValue,
    modified: details.modified,
    rendition: details.rendition,
    belongsToCollection: details.belongsToCollection,
    sourceOf: details.sourceOf,
    recordIdentifier: details.recordIdentifier,
    mediaDuration: _propertyMeta(metaElements, 'media:duration'),
    mediaActiveClass: _propertyMeta(metaElements, 'media:active-class'),
    mediaPlaybackActiveClass: _propertyMeta(metaElements, 'media:playback-active-class'),
    narrator: _dcText(metadataElement, 'narrator'),
    titleSort: common.titleSort,
    authorSort: common.authorSort,
    bookProducer: common.bookProducer,
  );
}

final class _Epub3Details {
  const _Epub3Details({
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
  });

  final List<String> schemaOrgs;
  final List<String> accessibilitySummaries;
  final String educationalRole;
  final String typicalAgeRange;
  final List<String> accessibilityFeatures;
  final String modified;
  final String rendition;
  final String belongsToCollection;
  final String sourceOf;
  final String recordIdentifier;
}

_Epub3Details _readEpub3Details(final XmlElement metadataElement) {
  return _Epub3Details(
    schemaOrgs: _propertyTexts(metadataElement, 'schema:org'),
    accessibilitySummaries: _propertyTexts(metadataElement, 'a11y:summary'),
    educationalRole: _propertyText(metadataElement, 'schema:educationalRole'),
    typicalAgeRange: _propertyText(metadataElement, 'schema:typicalAgeRange'),
    accessibilityFeatures: _propertyTexts(metadataElement, 'schema:accessibilityFeature'),
    modified: _propertyText(metadataElement, 'dcterms:modified'),
    rendition: _propertyText(metadataElement, 'rendition'),
    belongsToCollection: _propertyText(metadataElement, 'belongs-to-collection'),
    sourceOf: _propertyText(metadataElement, 'source-of', refines: '#cover-image'),
    recordIdentifier: _propertyText(metadataElement, 'dcterms:recordIdentifier'),
  );
}

String _propertyText(
  final XmlElement metadataElement,
  final String property, {
  final String? refines,
}) {
  return metadataElement
          .findElements('meta')
          .firstWhereOrNull((final element) {
            return element.getAttribute('property') == property &&
                (refines == null || element.getAttribute('refines') == refines);
          })
          ?.innerText
          .trim() ??
      '';
}

List<String> _propertyTexts(final XmlElement metadataElement, final String property) {
  return metadataElement
      .findElements('meta')
      .where((final element) => element.getAttribute('property') == property)
      .map((final element) => element.innerText.trim())
      .toList();
}

List<ManifestItem> _parseManifestItems(
  final XmlElement manifestElement,
  final String? namespaceUri,
) {
  return manifestElement.findElements('item', namespaceUri: namespaceUri).map((final itemElement) {
    return ManifestItem(
      path: _requiredAttribute(itemElement, 'href', elementName: 'manifest item'),
      id: _requiredAttribute(itemElement, 'id', elementName: 'manifest item'),
      mediaType: _requiredAttribute(itemElement, 'media-type', elementName: 'manifest item'),
      properties: _propertiesOf(itemElement),
      mediaOverlay: itemElement.getAttribute('media-overlay'),
    );
  }).toList();
}

Spine _parseSpine(final XmlElement spineElement) {
  return Spine(
    tocId: spineElement.getAttribute('toc'),
    pageProgressionDirection: PageProgressionDirection.fromSpineValue(
      spineElement.getAttribute('page-progression-direction'),
    ),
    items: spineElement.findElements('itemref').map((final itemrefElement) {
      return _requiredAttribute(itemrefElement, 'idref', elementName: 'spine item');
    }).toList(),
  );
}

Guide? _parseGuide(final XmlElement guideElement) {
  return Guide(
    references: guideElement.findElements('reference').map((final referenceElement) {
      // The OPF spec only requires `href` and `type`; `title` is optional and
      // real-world books omit it, so missing attributes degrade to empty.
      return Reference(
        href: referenceElement.getAttribute('href') ?? '',
        title: referenceElement.getAttribute('title') ?? '',
        type: referenceElement.getAttribute('type') ?? '',
      );
    }).toList(),
  );
}

/// The sort form carried on [element]: its `file-as` attribute, or a
/// `file-as` refine targeted at it (`<meta refines="#id"
/// property="file-as">…</meta>`).
String? _fileAsOf(final XmlElement? element, final List<XmlElement> metaElements) {
  if (element == null) return null;

  final direct = _opfAttribute(element, 'file-as');
  if (direct != null) return _normalize(direct);

  final id = element.getAttribute('id');
  if (id == null || id.isEmpty) return null;

  for (final meta in metaElements) {
    if (meta.getAttribute('refines') != '#$id') continue;
    if (meta.getAttribute('property') != 'file-as') continue;

    final value = _normalize(meta.innerText.trim());
    if (value != null) return value;
  }

  return null;
}

/// Text of the `dc:contributor` carrying the `bkp` (book producer)
/// role, either as an attribute or as a `marc:relators` refines.
String? _bookProducerOf(final XmlElement metadataElement, final List<XmlElement> metaElements) {
  for (final contributor in metadataElement.findElements(
    'contributor',
    namespaceUri: _dcNamespace,
  )) {
    final role = _opfAttribute(contributor, 'role');
    final isProducer = role?.toLowerCase() == 'bkp' || _refinesRoleIsBkp(contributor, metaElements);
    if (!isProducer) continue;

    final value = contributor.innerText.trim();
    if (value.isNotEmpty) return value;
  }

  return null;
}

bool _isEpub2(final String version) {
  final major = int.tryParse(version.trim().split('.').first);
  if (major == null || major < 2) {
    throw EpubException('EPUB parsing package error: invalid version "$version".');
  }

  return major < 3;
}

List<String> _propertiesOf(final XmlElement element) {
  return (element.getAttribute('properties') ?? '')
      .split(RegExp(r'\s+'))
      .where((final property) => property.isNotEmpty)
      .toList();
}

String _requiredAttribute(
  final XmlElement element,
  final String attribute, {
  required final String elementName,
}) {
  final value = element.getAttribute(attribute)?.trim();
  if (value == null || value.isEmpty) {
    throw EpubException(
      'EPUB parsing package error: $elementName is missing the $attribute attribute.',
    );
  }

  return value;
}

Iterable<XmlElement> _dcElements(final XmlElement metadata, final String localName) {
  final namespaced = metadata.findElements(localName, namespaceUri: _dcNamespace);
  if (namespaced.isNotEmpty) return namespaced;

  return metadata.childElements.where((final element) => element.name.local == localName);
}

/// An OPF-namespaced (or plain) attribute by local name, trimmed.
///
/// Real-world files spell these attributes `opf:file-as`, `ns4:role`,
/// plain `file-as`, ... so the prefix must not matter.
String? _opfAttribute(final XmlElement element, final String localName) {
  final namespaced = element.getAttribute(localName, namespaceUri: _opfNamespace);
  if (namespaced != null && namespaced.trim().isNotEmpty) return namespaced.trim();

  final plain = element.getAttribute(localName);
  if (plain != null && plain.trim().isNotEmpty) return plain.trim();

  return null;
}

/// Value of `<meta name="[name]" content="…"/>`.
String? _namedMeta(final Iterable<XmlElement> metaElements, final String name) {
  for (final meta in metaElements) {
    if (meta.getAttribute('name') != name) continue;

    final value = (meta.getAttribute('content') ?? meta.innerText).trim();
    if (value.isNotEmpty) return value;
  }

  return null;
}

/// Value of the first `<meta property="[property]">…</meta>` (EPUB 3
/// metadata, e.g. `media:duration`).
String _propertyMeta(final Iterable<XmlElement> metaElements, final String property) {
  for (final meta in metaElements) {
    if (meta.getAttribute('property') != property) continue;

    final value = meta.innerText.trim();
    if (value.isNotEmpty) return value;
  }

  return '';
}

/// Whether a `role` refine on [element] resolves to `bkp`.
bool _refinesRoleIsBkp(final XmlElement element, final List<XmlElement> metaElements) {
  final id = element.getAttribute('id');
  if (id == null || id.isEmpty) return false;

  for (final meta in metaElements) {
    if (meta.getAttribute('refines') != '#$id') continue;
    if (meta.getAttribute('property') != 'role') continue;

    final scheme = meta.getAttribute('scheme');
    if (scheme != null && scheme != 'marc:relators') continue;
    if (meta.innerText.trim().toLowerCase() == 'bkp') return true;
  }

  return false;
}

/// Treats `Unknown` as an absent value.
String? _normalize(final String? value) {
  if (value == null || value.isEmpty) return null;
  if (value.toLowerCase() == 'unknown') return null;

  return value;
}
