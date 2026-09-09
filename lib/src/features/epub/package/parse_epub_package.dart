import 'package:collection/collection.dart';
import 'package:e_livre/src/features/epub/codec/epub_xml.dart';
import 'package:e_livre/src/features/epub/entities/entities.dart';
import 'package:e_livre/src/features/epub/exceptions/exceptions.dart';
import 'package:xml/xml.dart';

/// Parses the provided XML string into an `EpubPackage`.
///
/// The function first parses the XML string into an XML document, then retrieves the package element from the document.
/// It then retrieves the version, metadata, manifest, and spine from the package element.
/// Depending on the version, it either creates an `Epub2Package` or an `Epub3Package` from the retrieved data.
///
/// [xml] is the XML string to parse.
///
/// Returns an `EpubPackage` representing the parsed package.
///
/// Missing navigation metadata is allowed; callers can represent it as an
/// empty table of contents while still reading the spine.
EpubPackage parsePackage(final String xml) {
  final document = XmlDocument.parse(xml);
  final namespaceUri = document.rootElement.namespaceUri;

  final package = document.findElements('package', namespace: namespaceUri).firstOrNull;
  _validate(package, 'package');
  final version = package!.getAttribute('version')?.trim() ?? '2.0';

  final metadataElement = package.findElements('metadata', namespace: namespaceUri).firstOrNull;
  _validate(metadataElement, 'metadata');

  final manifestElement = package.findElements('manifest', namespace: namespaceUri).firstOrNull;
  _validate(manifestElement, 'manifest');
  final spineElement = package.findElements('spine', namespace: namespaceUri).firstOrNull;
  _validate(spineElement, 'spine');

  final uniqueIdentifierProperty = package.getAttribute('unique-identifier') ?? 'uuid_id';

  final metadata = _parseMetadata(metadataElement!, version, uniqueIdentifierProperty);
  final manifestItems = _parseManifestItems(manifestElement!, namespaceUri);
  final spine = _parseSpine(spineElement!);

  final xmlns = package.getAttribute('xmlns');
  final guideElement = package.findElements('guide', namespace: namespaceUri).firstOrNull;
  final guide = guideElement != null ? _parseGuide(guideElement) : null;

  if (_isEpub2(version)) {
    return Epub2Package(
      xmlns: xmlns,
      uniqueIdentifier: uniqueIdentifierProperty,
      version: version,
      metadata: metadata,
      manifest: Epub2Manifest(items: manifestItems),
      spine: spine,
      guide: guide,
    );
  } else {
    final tocElement = manifestElement
        .findElements('item')
        .firstWhereOrNull(
          (final element) => element.getAttribute('properties')?.contains('nav') == true,
        );

    final tocPath = tocElement?.getAttribute('id') ?? spine.tocId;

    return Epub3Package(
      xmlns: xmlns,
      uniqueIdentifier: uniqueIdentifierProperty,
      version: version,
      metadata: metadata,
      manifest: Epub2Manifest(items: manifestItems),
      spine: spine,
      guide: guide,
      tocId: tocPath,
    );
  }
}

/// Parses an OPF package from its encoded archive bytes.
EpubPackage parsePackageBytes(final List<int> bytes) => parsePackage(decodeEpubText(bytes));

void _validate(final XmlElement? item, final String name) {
  if (item != null) return;
  throw EpubException('EPUB parsing package error: No $name element found.');
}

// XmlElement getCorrectPackage(final XmlDocument xml) {
//   XmlElement? packageElements = xml.findElements('package').firstOrNull;
//   if (packageElements != null) return packageElements;

//   packageElements = xml.findAllElements('ns0:package').firstOrNull;
//   if (packageElements != null) return packageElements;

//   throw EpubException('EPUB parsing package error: No package element found.');
// }

Metadata _parseMetadata(
  final XmlElement metadataElement,
  final String version,
  final String uniqueIdentifierProperty,
) {
  String getElementText(final String name) {
    final elements = metadataElement.findElements(name);
    return elements.isEmpty ? '' : elements.first.innerText.trim();
  }

  final rights = metadataElement
      .findElements('dc:rights')
      .map((final e) => e.innerText.trim())
      .toList();
  final contributor = getElementText('dc:contributor');
  final creator = getElementText('dc:creator');
  final date =
      metadataElement.findElements('dc:date').firstOrNull?.innerText.trim() ??
      (metadataElement
              .findElements('meta')
              .firstWhereOrNull((final element) => element.getAttribute('property') == 'dc:date')
              ?.innerText
              .trim() ??
          '');
  final publisher =
      metadataElement.findElements('dc:publisher').firstOrNull?.innerText.trim() ??
      (metadataElement
              .findElements('meta')
              .firstWhereOrNull(
                (final element) => element.getAttribute('property') == 'dc:publisher',
              )
              ?.innerText
              .trim() ??
          '');
  final language = getElementText('dc:language');

  final subjectText = getElementText('dc:subject');
  final subject = subjectText.isEmpty ? getElementText('dc:type') : subjectText;
  final description = getElementText('dc:description');
  final title = getElementText('dc:title');
  final identifiers = metadataElement
      .findElements('dc:identifier')
      .map((final e) => e.innerText.trim())
      .toList();

  final uniqueIdentifierValue =
      metadataElement
          .findElements('dc:identifier')
          .firstWhereOrNull(
            (final element) => element.getAttribute('id') == uniqueIdentifierProperty,
          )
          ?.innerText
          .trim() ??
      (identifiers.isEmpty ? '' : identifiers.first);

  // EPUB 2 cover reference: <meta name="cover" content="cover-id"/>
  final coverId = metadataElement
      .findElements('meta')
      .firstWhereOrNull(
        (final element) =>
            element.getAttribute('name') == 'cover' &&
            (element.getAttribute('content') ?? '').isNotEmpty,
      )
      ?.getAttribute('content');

  // Series: calibre writes <meta name="calibre:series" content="..."/>
  // (EPUB 2) or <meta property="calibre:series"> (EPUB 3); EPUB 3
  // collections use belongs-to-collection + group-position.
  // Real-world files write these metas both bare and `opf:`-prefixed,
  // so both spellings are collected.
  final metaElements = <XmlElement>[
    ...metadataElement.findElements('meta', namespace: _opfNamespace),
    ...metadataElement.findElements('meta'),
  ];
  String? series;
  String? seriesIndex;
  for (final meta in metaElements) {
    final name = meta.getAttribute('name');
    final property = meta.getAttribute('property');
    if (name == null && property == null) {
      continue;
    }
    final value = meta.getAttribute('content') ?? meta.innerText.trim();
    if (value.isEmpty) {
      continue;
    }
    if (name == 'calibre:series' || property == 'calibre:series') {
      series ??= value;
    } else if (name == 'calibre:series_index' || property == 'calibre:series_index') {
      seriesIndex ??= value;
    } else if (property == 'group-position' && !_isEpub2(version)) {
      seriesIndex ??= value;
    }
  }

  // Sort keys and producer, following Calibre's conventions: the sort
  // forms live on `file-as` (attribute or refines meta) or the
  // `calibre:title_sort` / `calibre:author_sort` metas; the producer is
  // the `dc:contributor` carrying the `bkp` role (attribute or the
  // `marc:relators` refines). DC elements are looked up by namespace
  // since the `dc:` prefix is not guaranteed.
  final titleElement = metadataElement.findElements('title', namespace: _dcNamespace).firstOrNull;
  final creatorElement = metadataElement
      .findElements('creator', namespace: _dcNamespace)
      .firstOrNull;
  final titleSort =
      _fileAsOf(titleElement, metaElements) ??
      _normalize(_namedMeta(metaElements, 'calibre:title_sort'));
  final authorSort =
      _fileAsOf(creatorElement, metaElements) ??
      _normalize(_namedMeta(metaElements, 'calibre:author_sort'));
  final bookProducer = _bookProducerOf(metadataElement, metaElements);

  if (_isEpub2(version)) {
    return Epub2Metadata(
      rights: rights,
      contributor: contributor,
      creator: creator,
      publisher: publisher,
      title: title,
      date: date,
      language: language,
      subject: subject,
      description: description,
      identifiers: identifiers,
      uniqueIdentifierValue: uniqueIdentifierValue,
      coverId: coverId,
      series: series,
      seriesIndex: seriesIndex,
      titleSort: titleSort,
      authorSort: authorSort,
      bookProducer: bookProducer,
    );
  }

  final educationalRole =
      metadataElement
          .findElements('meta')
          .firstWhereOrNull(
            (final element) => element.getAttribute('property') == 'schema:educationalRole',
          )
          ?.innerText
          .trim() ??
      '';
  final typicalAgeRange =
      metadataElement
          .findElements('meta')
          .firstWhereOrNull(
            (final element) => element.getAttribute('property') == 'schema:typicalAgeRange',
          )
          ?.innerText
          .trim() ??
      '';
  final accessibilityFeatures = metadataElement
      .findElements('meta')
      .where((final element) => element.getAttribute('property') == 'schema:accessibilityFeature')
      .map((final e) => e.innerText.trim())
      .toList();

  return Epub3Metadata(
    rights: rights,
    contributor: contributor,
    creator: creator,
    publisher: publisher,
    title: title,
    date: date,
    language: language,
    subject: subject,
    description: description,
    identifiers: identifiers,
    coverId: coverId,
    series: series,
    seriesIndex: seriesIndex,
    schemaOrgs: metadataElement
        .findElements('meta')
        .where((final element) => element.getAttribute('property') == 'schema:org')
        .map((final e) => e.innerText.trim())
        .toList(),
    accessibilitySummaries: metadataElement
        .findElements('meta')
        .where((final element) => element.getAttribute('property') == 'a11y:summary')
        .map((final e) => e.innerText.trim())
        .toList(),
    educationalRole: educationalRole,
    typicalAgeRange: typicalAgeRange,
    accessibilityFeatures: accessibilityFeatures,
    uniqueIdentifierValue: uniqueIdentifierValue,
    modified:
        metadataElement
            .findElements('meta')
            .where((final element) => element.getAttribute('property') == 'dcterms:modified')
            .firstOrNull
            ?.innerText
            .trim() ??
        '',
    rendition:
        metadataElement
            .findElements('meta')
            .firstWhereOrNull((final element) => element.getAttribute('property') == 'rendition')
            ?.innerText
            .trim() ??
        '',
    belongsToCollection:
        metadataElement
            .findElements('meta')
            .firstWhereOrNull(
              (final element) => element.getAttribute('property') == 'belongs-to-collection',
            )
            ?.innerText
            .trim() ??
        '',
    sourceOf:
        metadataElement
            .findElements('meta')
            .firstWhereOrNull(
              (final element) =>
                  element.getAttribute('refines') == '#cover-image' &&
                  element.getAttribute('property') == 'source-of',
            )
            ?.innerText
            .trim() ??
        '',
    recordIdentifier:
        metadataElement
            .findElements('meta')
            .firstWhereOrNull(
              (final element) => element.getAttribute('property') == 'dcterms:recordIdentifier',
            )
            ?.innerText
            .trim() ??
        '',
    mediaDuration: _propertyMeta(metaElements, 'media:duration'),
    mediaActiveClass: _propertyMeta(metaElements, 'media:active-class'),
    mediaPlaybackActiveClass: _propertyMeta(metaElements, 'media:playback-active-class'),
    narrator:
        metadataElement
            .findElements('narrator', namespace: _dcNamespace)
            .firstOrNull
            ?.innerText
            .trim() ??
        '',
    titleSort: titleSort,
    authorSort: authorSort,
    bookProducer: bookProducer,
  );
}

List<ManifestItem> _parseManifestItems(
  final XmlElement manifestElement,
  final String? namespaceUri,
) {
  return manifestElement.findElements('item', namespace: namespaceUri).map((final itemElement) {
    return ManifestItem(
      path: itemElement.getAttribute('href')!,
      id: itemElement.getAttribute('id')!,
      mediaType: itemElement.getAttribute('media-type')!,
      properties: itemElement.getAttribute('properties')?.split(' ').toList() ?? [],
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
    items: spineElement
        .findElements('itemref')
        .map((final itemrefElement) => itemrefElement.getAttribute('idref')!)
        .toList(),
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
  for (final contributor in metadataElement.findElements('contributor', namespace: _dcNamespace)) {
    final role = _opfAttribute(contributor, 'role');
    final isProducer = role?.toLowerCase() == 'bkp' || _refinesRoleIsBkp(contributor, metaElements);
    if (!isProducer) continue;
    final value = contributor.innerText.trim();
    if (value.isNotEmpty) return value;
  }

  return null;
}

bool _isEpub2(final String version) => double.parse(version) < 3.0;

const String _opfNamespace = 'http://www.idpf.org/2007/opf';
const String _dcNamespace = 'http://purl.org/dc/elements/1.1/';

/// An OPF-namespaced (or plain) attribute by local name, trimmed.
///
/// Real-world files spell these attributes `opf:file-as`, `ns4:role`,
/// plain `file-as`, ... so the prefix must not matter.
String? _opfAttribute(final XmlElement element, final String localName) {
  final namespaced = element.getAttribute(localName, namespace: _opfNamespace);
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

/// Calibre treats `Unknown` as an absent value.
String? _normalize(final String? value) {
  if (value == null || value.isEmpty) return null;
  if (value.toLowerCase() == 'unknown') return null;

  return value;
}
