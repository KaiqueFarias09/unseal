/// Parses OPDS 2.0 JSON catalogs into the public model.
///
/// Unseal interprets catalogs; the host performs every network operation.
/// The parser is pure: two calls on distinct feeds share no state, and
/// nothing is fetched during or after parsing.
///
/// Bounds from `Opds2Limits` apply before the corresponding output is
/// allocated: input bytes before decoding, node count, depth, and string
/// length before mapping, per-collection counts while the model builds.
library;

import 'dart:convert' show jsonDecode, utf8;

import 'dart:typed_data';

import 'opds2_exception.dart';

import 'opds2_limits.dart';

import 'opds2_model.dart';

/// Parses OPDS 2.0 JSON catalogs into the public model.
///
/// Unseal interprets catalogs; the host performs every network operation.
/// Parses an OPDS 2.0 feed from its JSON [source].
///
/// Throws [Opds2MalformedException] for broken, truncated, incomplete, or
/// out-of-subset documents and [Opds2LimitExceededException] when a bound
/// of [limits] is crossed.
Opds2Feed parseOpds2Feed(final String source, {final Opds2Limits limits = const Opds2Limits()}) {
  final document = _decodeDocument(source, limits, pointer: '');

  return _FeedMapper(limits).mapFeed(document);
}

/// Parses an OPDS 2.0 feed from raw [bytes].
///
/// The byte bound is checked before decoding; see [parseOpds2Feed] for the
/// failure contract.
Opds2Feed parseOpds2FeedBytes(
  final Uint8List bytes, {
  final Opds2Limits limits = const Opds2Limits(),
}) {
  final document = _decodeBytes(bytes, limits);

  return _FeedMapper(limits).mapFeed(document);
}

/// Parses a standalone OPDS 2.0 publication document (media type
/// `application/opds-publication+json`).
///
/// A publication must carry at least one acquisition link; its `self`
/// link is recommended but not required. See [parseOpds2Feed] for the
/// failure contract.
Opds2Publication parseOpds2Publication(
  final String source, {
  final Opds2Limits limits = const Opds2Limits(),
}) {
  final document = _decodeDocument(source, limits, pointer: '');

  return _FeedMapper(limits).mapPublication(document, pointer: '');
}

/// Parses a standalone OPDS 2.0 publication document from raw [bytes].
Opds2Publication parseOpds2PublicationBytes(
  final Uint8List bytes, {
  final Opds2Limits limits = const Opds2Limits(),
}) {
  final document = _decodeBytes(bytes, limits);

  return _FeedMapper(limits).mapPublication(document, pointer: '');
}

Object? _decodeBytes(final Uint8List bytes, final Opds2Limits limits) {
  if (bytes.length > limits.maxBytes) {
    throw Opds2LimitExceededException(
      'OPDS 2.0 input is ${bytes.length} bytes, above the ${limits.maxBytes}-byte limit.',
    );
  }
  final String source;
  try {
    source = utf8.decode(bytes);
  } on FormatException catch (error) {
    throw Opds2MalformedException('OPDS 2.0 input is not valid UTF-8: ${error.message}');
  }
  return _decodeDocument(source, limits, pointer: '');
}

Object? _decodeDocument(
  final String source,
  final Opds2Limits limits, {
  required final String pointer,
}) {
  // UTF-16 code units never exceed UTF-8 bytes, so this bound holds
  // whether callers decoded bytes themselves or passed a string.
  if (source.length > limits.maxBytes) {
    throw Opds2LimitExceededException(
      'OPDS 2.0 input is ${source.length} code units, above the ${limits.maxBytes}-byte limit.',
      pointer: pointer,
    );
  }
  final Object? document;
  try {
    document = jsonDecode(source);
  } on FormatException catch (error) {
    throw Opds2MalformedException('OPDS 2.0 input is not valid JSON: ${error.message}');
  }
  _Preflight(limits).check(document);

  return document;
}

/// Depth, node, and string-length bounds over the decoded document,
/// checked before any model allocation.
final class _Preflight {
  _Preflight(this.limits);

  final Opds2Limits limits;

  int _nodes = 0;

  void check(final Object? value) => _visit(value, 1);

  void _visit(final Object? value, final int depth) {
    if (depth > limits.maxDepth) {
      throw Opds2LimitExceededException(
        'OPDS 2.0 input nests deeper than the ${limits.maxDepth}-level limit.',
      );
    }
    if (++_nodes > limits.maxNodes) {
      throw Opds2LimitExceededException(
        'OPDS 2.0 input has more than the ${limits.maxNodes}-value limit.',
      );
    }
    if (value is String) {
      if (value.length > limits.maxStringLength) {
        throw Opds2LimitExceededException(
          'OPDS 2.0 input has a string above the ${limits.maxStringLength}-character limit.',
        );
      }

      return;
    }
    if (value is List) {
      for (final item in value) {
        _visit(item, depth + 1);
      }

      return;
    }
    if (value is Map) {
      for (final key in value.keys) {
        if (key is! String) {
          throw Opds2MalformedException('OPDS 2.0 input has a non-string object key.');
        }
        _visit(key, depth + 1);
        _visit(value[key], depth + 1);
      }
    }
  }
}

/// Builds the public model from a preflighted document, reporting JSON
/// pointers in every failure.
final class _FeedMapper {
  _FeedMapper(this.limits);

  final Opds2Limits limits;

  Opds2Feed mapFeed(final Object? root) {
    final feed = _requireObject(root, 'OPDS 2.0 feed', pointer: '');
    final metadata = _mapFeedMetadata(
      _requireMember(feed, 'metadata', 'feed'),
      pointer: '/metadata',
    );
    final links = _mapLinkArray(_requireMember(feed, 'links', 'feed'), pointer: '/links');
    _requireSelfLink(links);
    final navigation = _mapNavigation(feed['navigation'], pointer: '/navigation');
    final publications = _mapPublicationArray(feed['publications'], pointer: '/publications');
    final groups = _mapGroups(feed['groups'], pointer: '/groups');
    final facets = _mapFacets(feed['facets'], pointer: '/facets');
    final subcollections = _mapSubcollections(
      feed,
      known: const {'metadata', 'links', 'navigation', 'publications', 'groups', 'facets'},
    );
    if (navigation.isEmpty && publications.isEmpty && groups.isEmpty) {
      throw Opds2MalformedException(
        'OPDS 2.0 feed must contain at least one navigation, publications, or groups collection.',
        pointer: '',
      );
    }

    return Opds2Feed(
      metadata: metadata,
      links: links,
      navigation: navigation,
      publications: publications,
      groups: groups,
      facets: facets,
      subcollections: subcollections,
    );
  }

  Opds2Publication mapPublication(final Object? root, {required final String pointer}) {
    final publication = _requireObject(root, 'OPDS 2.0 publication', pointer: pointer);
    final metadata = _mapPublicationMetadata(
      _requireMember(publication, 'metadata', 'publication', pointer: pointer),
      pointer: '$pointer/metadata',
    );
    final links = _mapLinkArray(
      _requireMember(publication, 'links', 'publication', pointer: pointer),
      pointer: '$pointer/links',
    );
    if (!links.any((final link) => link.isAcquisition)) {
      throw Opds2MalformedException(
        'OPDS 2.0 publication must contain at least one acquisition link.',
        pointer: '$pointer/links',
      );
    }
    final images = _mapImages(publication['images'], pointer: '$pointer/images');

    return Opds2Publication(metadata: metadata, links: links, images: images);
  }

  void _requireSelfLink(final List<Opds2Link> links) {
    if (!links.any((final link) => link.hasRel('self'))) {
      throw Opds2MalformedException('OPDS 2.0 feed must contain a self link.', pointer: '/links');
    }
  }

  Opds2FeedMetadata _mapFeedMetadata(final Object? value, {required final String pointer}) {
    final object = _requireObject(value, 'feed metadata', pointer: pointer);
    final title = _mapLocalizedText(
      _requireMember(object, 'title', 'feed metadata', pointer: pointer),
      pointer: '$pointer/title',
    );
    final modifier = object['modified'];

    return Opds2FeedMetadata(
      title: title,
      identifier: _optionalString(object['identifier'], name: 'identifier', pointer: pointer),
      atType: _optionalString(object['@type'], name: '@type', pointer: pointer),
      subtitle: _optionalLocalizedText(object['subtitle'], pointer: '$pointer/subtitle'),
      modified: modifier == null ? null : _requireDateTime(modifier, pointer: '$pointer/modified'),
      description: _optionalString(object['description'], name: 'description', pointer: pointer),
      numberOfItems: _optionalCount(
        object['numberOfItems'],
        name: 'numberOfItems',
        pointer: pointer,
      ),
      itemsPerPage: _optionalPositiveCount(
        object['itemsPerPage'],
        name: 'itemsPerPage',
        pointer: pointer,
      ),
      currentPage: _optionalPositiveCount(
        object['currentPage'],
        name: 'currentPage',
        pointer: pointer,
      ),
    );
  }

  List<Opds2Link> _mapNavigation(final Object? value, {required final String pointer}) {
    if (value == null) return const <Opds2Link>[];
    final items = _requireArray(value, 'navigation collection', pointer: pointer);
    if (items.length > limits.maxLinks) {
      throw Opds2LimitExceededException(
        'navigation collection has ${items.length} links, above the ${limits.maxLinks} limit.',
        pointer: pointer,
      );
    }
    final links = <Opds2Link>[];
    for (var index = 0; index < items.length; index++) {
      final object = _requireObject(items[index], 'navigation link', pointer: '$pointer/$index');
      final link = _mapLink(object, pointer: '$pointer/$index');
      if (link.title == null || link.title!.isEmpty) {
        throw Opds2MalformedException(
          'navigation links must carry a title.',
          pointer: '$pointer/$index/title',
        );
      }
      links.add(link);
    }

    return links;
  }

  List<Opds2Publication> _mapPublicationArray(
    final Object? value, {
    required final String pointer,
  }) {
    if (value == null) return const <Opds2Publication>[];
    final items = _requireArray(value, 'publications collection', pointer: pointer);
    if (items.length > limits.maxPublications) {
      throw Opds2LimitExceededException(
        'publications collection has ${items.length} entries, above the ${limits.maxPublications} limit.',
        pointer: pointer,
      );
    }
    final publications = <Opds2Publication>[];
    for (var index = 0; index < items.length; index++) {
      publications.add(mapPublication(items[index], pointer: '$pointer/$index'));
    }

    return publications;
  }

  List<Opds2Group> _mapGroups(final Object? value, {required final String pointer}) {
    if (value == null) return const <Opds2Group>[];
    final items = _requireArray(value, 'groups collection', pointer: pointer);
    if (items.length > limits.maxGroups) {
      throw Opds2LimitExceededException(
        'groups collection has ${items.length} entries, above the ${limits.maxGroups} limit.',
        pointer: pointer,
      );
    }
    final groups = <Opds2Group>[];
    for (var index = 0; index < items.length; index++) {
      final object = _requireObject(items[index], 'group', pointer: '$pointer/$index');
      final groupPointer = '$pointer/$index';
      final metadata = _mapFeedMetadata(
        _requireMember(object, 'metadata', 'group', pointer: groupPointer),
        pointer: '$groupPointer/metadata',
      );
      groups.add(
        Opds2Group(
          metadata: metadata,
          links: object['links'] == null
              ? const <Opds2Link>[]
              : _mapLinkArray(object['links'], pointer: '$groupPointer/links'),
          navigation: _mapNavigation(object['navigation'], pointer: '$groupPointer/navigation'),
          publications: _mapPublicationArray(
            object['publications'],
            pointer: '$groupPointer/publications',
          ),
        ),
      );
    }

    return groups;
  }

  List<Opds2Facet> _mapFacets(final Object? value, {required final String pointer}) {
    if (value == null) return const <Opds2Facet>[];
    final items = _requireArray(value, 'facets collection', pointer: pointer);
    if (items.length > limits.maxFacets) {
      throw Opds2LimitExceededException(
        'facets collection has ${items.length} entries, above the ${limits.maxFacets} limit.',
        pointer: pointer,
      );
    }
    final facets = <Opds2Facet>[];
    for (var index = 0; index < items.length; index++) {
      final object = _requireObject(items[index], 'facet', pointer: '$pointer/$index');
      final facetPointer = '$pointer/$index';
      final metadataValue = object['metadata'];
      if (metadataValue == null) {
        throw Opds2MalformedException(
          'facet must carry metadata with a title.',
          pointer: '$facetPointer/metadata',
        );
      }
      final metadata = _mapFeedMetadata(metadataValue, pointer: '$facetPointer/metadata');
      facets.add(
        Opds2Facet(
          metadata: metadata,
          links: _mapLinkArray(
            _requireMember(object, 'links', 'facet', pointer: facetPointer),
            pointer: '$facetPointer/links',
          ),
        ),
      );
    }

    return facets;
  }

  Map<String, Opds2Subcollection> _mapSubcollections(
    final Map<Object?, Object?> feed, {
    required final Set<String> known,
  }) {
    final subcollections = <String, Opds2Subcollection>{};
    var count = 0;
    for (final entry in feed.entries) {
      final key = entry.key;
      if (key is! String || known.contains(key)) continue;
      if (++count > limits.maxSubcollections) {
        throw Opds2LimitExceededException(
          'feed has more than ${limits.maxSubcollections} subcollection members.',
          pointer: '/${_escapeToken(key)}',
        );
      }
      subcollections[key] = _mapSubcollection(key, entry.value, pointer: '/${_escapeToken(key)}');
    }

    return Map.unmodifiable(subcollections);
  }

  Opds2Subcollection _mapSubcollection(
    final String key,
    final Object? value, {
    required final String pointer,
  }) {
    if (value is List) {
      if (value.length > limits.maxLinks) {
        throw Opds2LimitExceededException(
          'subcollection "$key" has ${value.length} members, above the ${limits.maxLinks} limit.',
          pointer: pointer,
        );
      }
      final links = <Opds2Link>[];
      final children = <String, Opds2Subcollection>{};
      for (var index = 0; index < value.length; index++) {
        final item = value[index];
        if (item is Map && !item.containsKey('href')) {
          children['$index'] = _subcollectionFromObject(
            '$key/$index',
            item,
            pointer: '$pointer/$index',
          );
        } else {
          links.add(
            _mapLink(
              _requireObject(item, 'subcollection link', pointer: '$pointer/$index'),
              pointer: '$pointer/$index',
            ),
          );
        }
      }

      return Opds2Subcollection(key: key, links: links, children: Map.unmodifiable(children));
    }
    return _subcollectionFromObject(
      key,
      _requireObject(value, 'subcollection "$key"', pointer: pointer),
      pointer: pointer,
    );
  }

  Opds2Subcollection _subcollectionFromObject(
    final String key,
    final Map<Object?, Object?> object, {
    required final String pointer,
  }) {
    final metadata = object['metadata'];
    if (metadata != null && metadata is! Map) {
      throw Opds2MalformedException(
        'subcollection metadata must be an object.',
        pointer: '$pointer/metadata',
      );
    }
    final links = _mapLinkArray(
      _requireMember(object, 'links', 'subcollection "$key"', pointer: pointer),
      pointer: '$pointer/links',
    );
    final children = <String, Opds2Subcollection>{};
    var count = 0;
    for (final entry in object.entries) {
      final childKey = entry.key;
      if (childKey is! String) continue;
      if (childKey == 'metadata' || childKey == 'links') continue;
      if (++count > limits.maxSubcollections) {
        throw Opds2LimitExceededException(
          'subcollection "$key" has more than ${limits.maxSubcollections} nested members.',
          pointer: pointer,
        );
      }
      children[childKey] = _mapSubcollection(
        childKey,
        entry.value,
        pointer: '$pointer/${_escapeToken(childKey)}',
      );
    }

    return Opds2Subcollection(
      key: key,
      metadata: Map<String, Object?>.unmodifiable(
        metadata == null ? const <String, Object?>{} : Map<String, Object?>.from(metadata as Map),
      ),
      links: links,
      children: Map.unmodifiable(children),
    );
  }

  List<Opds2Link> _mapLinkArray(final Object? value, {required final String pointer}) {
    final items = _requireArray(value, 'links', pointer: pointer);
    if (items.length > limits.maxLinks) {
      throw Opds2LimitExceededException(
        'links array has ${items.length} entries, above the ${limits.maxLinks} limit.',
        pointer: pointer,
      );
    }
    final links = <Opds2Link>[];
    for (var index = 0; index < items.length; index++) {
      links.add(
        _mapLink(
          _requireObject(items[index], 'link', pointer: '$pointer/$index'),
          pointer: '$pointer/$index',
        ),
      );
    }

    return links;
  }

  Opds2Link _mapLink(final Map<Object?, Object?> object, {required final String pointer}) {
    final href = _requireString(object['href'], name: 'href', pointer: pointer);
    final rels = _mapRels(object['rel'], pointer: '$pointer/rel');
    if (rels.contains('search') && !_templateCarriesQuery(href)) {
      throw Opds2MalformedException(
        'search links must be URI templates carrying at least a query parameter.',
        pointer: '$pointer/href',
      );
    }
    final propertiesValue = object['properties'];
    final childrenValue = object['children'];
    final children = childrenValue == null
        ? const <Opds2Link>[]
        : _mapLinkArray(childrenValue, pointer: '$pointer/children');

    return Opds2Link(
      href: href,
      rels: rels,
      templated: object['templated'] == null
          ? false
          : _requireBool(object['templated'], pointer: '$pointer/templated'),
      type: _optionalString(object['type'], name: 'type', pointer: pointer),
      title: _optionalString(object['title'], name: 'title', pointer: pointer),
      languages: _mapStringList(object['language'], pointer: '$pointer/language'),
      height: _optionalPositiveCount(object['height'], name: 'height', pointer: pointer),
      width: _optionalPositiveCount(object['width'], name: 'width', pointer: pointer),
      size: _optionalPositiveCount(object['size'], name: 'size', pointer: pointer),
      bitrate: _optionalNumber(object['bitrate'], name: 'bitrate', pointer: pointer),
      duration: _optionalNumber(object['duration'], name: 'duration', pointer: pointer),
      properties: propertiesValue == null
          ? null
          : _mapLinkProperties(propertiesValue, pointer: '$pointer/properties'),
      alternate: object['alternate'] == null
          ? null
          : _requireBool(object['alternate'], pointer: '$pointer/alternate'),
      children: children,
    );
  }

  List<String> _mapRels(final Object? value, {required final String pointer}) {
    if (value == null) return const <String>[];
    if (value is String) return <String>[value];
    if (value is List) {
      if (value.length > limits.maxLinks) {
        throw Opds2LimitExceededException(
          'rel list has ${value.length} entries, above the ${limits.maxLinks} limit.',
          pointer: pointer,
        );
      }
      final rels = <String>[];
      for (var index = 0; index < value.length; index++) {
        rels.add(_requireString(value[index], name: 'rel', pointer: '$pointer/$index'));
      }

      return rels;
    }
    throw Opds2MalformedException('rel must be a string or a list of strings.', pointer: pointer);
  }

  Opds2LinkProperties _mapLinkProperties(final Object? value, {required final String pointer}) {
    final object = _requireObject(value, 'link properties', pointer: pointer);
    final priceValue = object['price'];
    final holdsValue = object['holds'];
    final copiesValue = object['copies'];
    final availabilityValue = object['availability'];
    final encryptedValue = object['encrypted'];
    final indirectValue = object['indirectAcquisition'];
    final indirectAcquisitions = <Opds2AcquisitionObject>[];
    if (indirectValue != null) {
      final items = _requireArray(
        indirectValue,
        'indirectAcquisition',
        pointer: '$pointer/indirectAcquisition',
      );
      for (var index = 0; index < items.length; index++) {
        indirectAcquisitions.add(
          _mapAcquisitionObject(items[index], pointer: '$pointer/indirectAcquisition/$index'),
        );
      }
    }

    return Opds2LinkProperties(
      numberOfItems: _optionalCount(
        object['numberOfItems'],
        name: 'numberOfItems',
        pointer: pointer,
      ),
      price: priceValue == null ? null : _mapPrice(priceValue, pointer: '$pointer/price'),
      indirectAcquisitions: indirectAcquisitions,
      holds: holdsValue == null ? null : _mapHolds(holdsValue, pointer: '$pointer/holds'),
      copies: copiesValue == null ? null : _mapCopies(copiesValue, pointer: '$pointer/copies'),
      availability: availabilityValue == null
          ? null
          : _mapAvailability(availabilityValue, pointer: '$pointer/availability'),
      contains: _mapStringList(object['contains'], pointer: '$pointer/contains'),
      layout: _optionalString(object['layout'], name: 'layout', pointer: pointer),
      encrypted: encryptedValue == null
          ? null
          : _mapEncryption(encryptedValue, pointer: '$pointer/encrypted'),
      page: _optionalString(object['page'], name: 'page', pointer: pointer),
    );
  }

  Opds2AcquisitionObject _mapAcquisitionObject(
    final Object? value, {
    required final String pointer,
  }) {
    final object = _requireObject(value, 'acquisition object', pointer: pointer);
    final type = _requireString(object['type'], name: 'type', pointer: pointer);
    final childValue = object['child'];
    final children = <Opds2AcquisitionObject>[];
    if (childValue != null) {
      final items = _requireArray(childValue, 'acquisition child', pointer: '$pointer/child');
      for (var index = 0; index < items.length; index++) {
        children.add(_mapAcquisitionObject(items[index], pointer: '$pointer/child/$index'));
      }
    }

    return Opds2AcquisitionObject(type: type, children: children);
  }

  Opds2Price _mapPrice(final Object? value, {required final String pointer}) {
    final object = _requireObject(value, 'price', pointer: pointer);
    final priceValue = object['value'];
    if (priceValue is! num) {
      throw Opds2MalformedException('price must carry a numeric value.', pointer: '$pointer/value');
    }
    final currency = object['currency'];
    if (currency != null) {
      final text = _requireString(currency, name: 'currency', pointer: pointer);
      if (text.length != 3 ||
          !text.codeUnits.every(
            (final unit) => (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A),
          )) {
        throw Opds2MalformedException(
          'price currency must be a three-letter ISO 4217 code.',
          pointer: '$pointer/currency',
        );
      }
    }

    return Opds2Price(value: priceValue, currency: currency == null ? null : currency as String);
  }

  Opds2Holds _mapHolds(final Object? value, {required final String pointer}) {
    final object = _requireObject(value, 'holds', pointer: pointer);

    return Opds2Holds(
      total: object['total'] == null
          ? null
          : _optionalCount(object['total'], name: 'total', pointer: pointer),
      position: object['position'] == null
          ? null
          : _optionalCount(object['position'], name: 'position', pointer: pointer),
    );
  }

  Opds2Copies _mapCopies(final Object? value, {required final String pointer}) {
    final object = _requireObject(value, 'copies', pointer: pointer);

    return Opds2Copies(
      total: object['total'] == null
          ? null
          : _optionalCount(object['total'], name: 'total', pointer: pointer),
      available: object['available'] == null
          ? null
          : _optionalCount(object['available'], name: 'available', pointer: pointer),
    );
  }

  Opds2Availability _mapAvailability(final Object? value, {required final String pointer}) {
    final object = _requireObject(value, 'availability', pointer: pointer);
    final state = _requireString(object['state'], name: 'state', pointer: pointer);
    if (!opds2AvailabilityStates.contains(state)) {
      throw Opds2MalformedException(
        'availability state must be one of ${opds2AvailabilityStates.join(', ')}.',
        pointer: '$pointer/state',
      );
    }

    return Opds2Availability(
      state: state,
      since: object['since'] == null
          ? null
          : _requireDateTime(object['since'], pointer: '$pointer/since'),
      until: object['until'] == null
          ? null
          : _requireDateTime(object['until'], pointer: '$pointer/until'),
    );
  }

  Opds2Encryption _mapEncryption(final Object? value, {required final String pointer}) {
    final object = _requireObject(value, 'encrypted', pointer: pointer);

    return Opds2Encryption(
      algorithm: _requireString(object['algorithm'], name: 'algorithm', pointer: pointer),
      compression: _optionalString(object['compression'], name: 'compression', pointer: pointer),
      originalLength: object['originalLength'] == null
          ? null
          : _optionalCount(object['originalLength'], name: 'originalLength', pointer: pointer),
      profile: _optionalString(object['profile'], name: 'profile', pointer: pointer),
      scheme: _optionalString(object['scheme'], name: 'scheme', pointer: pointer),
    );
  }

  Opds2Metadata _mapPublicationMetadata(final Object? value, {required final String pointer}) {
    final object = _requireObject(value, 'publication metadata', pointer: pointer);
    final title = _mapLocalizedText(
      _requireMember(object, 'title', 'publication metadata', pointer: pointer),
      pointer: '$pointer/title',
    );
    final accessibilityValue = object['accessibility'];

    return Opds2Metadata(
      title: title,
      identifier: _optionalString(object['identifier'], name: 'identifier', pointer: pointer),
      altIdentifiers: _mapAltIdentifiers(
        object['altIdentifier'],
        pointer: '$pointer/altIdentifier',
      ),
      atType: _optionalString(object['@type'], name: '@type', pointer: pointer),
      conformsTo: _mapStringList(object['conformsTo'], pointer: '$pointer/conformsTo'),
      sortAs: _optionalLocalizedText(object['sortAs'], pointer: '$pointer/sortAs'),
      subtitle: _optionalLocalizedText(object['subtitle'], pointer: '$pointer/subtitle'),
      modified: object['modified'] == null
          ? null
          : _requireDateTime(object['modified'], pointer: '$pointer/modified'),
      published: _optionalString(object['published'], name: 'published', pointer: pointer),
      languages: _mapStringList(object['language'], pointer: '$pointer/language'),
      authors: _mapContributors(object['author'], pointer: '$pointer/author'),
      translators: _mapContributors(object['translator'], pointer: '$pointer/translator'),
      editors: _mapContributors(object['editor'], pointer: '$pointer/editor'),
      artists: _mapContributors(object['artist'], pointer: '$pointer/artist'),
      illustrators: _mapContributors(object['illustrator'], pointer: '$pointer/illustrator'),
      letterers: _mapContributors(object['letterer'], pointer: '$pointer/letterer'),
      pencilers: _mapContributors(object['penciler'], pointer: '$pointer/penciler'),
      colorists: _mapContributors(object['colorist'], pointer: '$pointer/colorist'),
      inkers: _mapContributors(object['inker'], pointer: '$pointer/inker'),
      narrators: _mapContributors(object['narrator'], pointer: '$pointer/narrator'),
      contributors: _mapContributors(object['contributor'], pointer: '$pointer/contributor'),
      publishers: _mapContributors(object['publisher'], pointer: '$pointer/publisher'),
      imprints: _mapContributors(object['imprint'], pointer: '$pointer/imprint'),
      subjects: _mapSubjects(object['subject'], pointer: '$pointer/subject'),
      accessibility: accessibilityValue == null
          ? null
          : Map<String, Object?>.unmodifiable(
              Map<String, Object?>.from(
                _requireObject(accessibilityValue, 'accessibility', pointer: pointer),
              ),
            ),
      layout: _optionalString(object['layout'], name: 'layout', pointer: pointer),
      readingProgression: _optionalString(
        object['readingProgression'],
        name: 'readingProgression',
        pointer: pointer,
      ),
      description: _optionalString(object['description'], name: 'description', pointer: pointer),
      duration: _optionalNumber(object['duration'], name: 'duration', pointer: pointer),
      numberOfPages: _optionalCount(
        object['numberOfPages'],
        name: 'numberOfPages',
        pointer: pointer,
      ),
    );
  }

  List<Opds2AltIdentifier> _mapAltIdentifiers(
    final Object? value, {
    required final String pointer,
  }) {
    if (value == null) return const <Opds2AltIdentifier>[];
    final items = _requireArray(value, 'altIdentifier', pointer: pointer);
    final identifiers = <Opds2AltIdentifier>[];
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      final itemPointer = '$pointer/$index';
      if (item is String) {
        identifiers.add(Opds2AltIdentifier(value: item));
        continue;
      }
      final object = _requireObject(item, 'altIdentifier', pointer: itemPointer);
      identifiers.add(
        Opds2AltIdentifier(
          value: _requireString(object['value'], name: 'value', pointer: itemPointer),
          scheme: _optionalString(object['scheme'], name: 'scheme', pointer: itemPointer),
        ),
      );
    }

    return identifiers;
  }

  List<Opds2Contributor> _mapContributors(final Object? value, {required final String pointer}) {
    if (value == null) return const <Opds2Contributor>[];
    if (value is String) {
      return <Opds2Contributor>[Opds2Contributor(name: Opds2LocalizedText.plain(value))];
    }
    // A single object counts as a one-element collection so failure
    // pointers match the schema's array shape.
    final items = value is Map
        ? <Object?>[value]
        : _requireArray(value, 'contributors', pointer: pointer);
    final contributors = <Opds2Contributor>[];
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      contributors.add(
        item is String
            ? Opds2Contributor(name: Opds2LocalizedText.plain(item))
            : _mapContributorObject(
                _requireObject(item, 'contributor', pointer: '$pointer/$index'),
                pointer: '$pointer/$index',
              ),
      );
    }

    return contributors;
  }

  Opds2Contributor _mapContributorObject(
    final Map<Object?, Object?> object, {
    required final String pointer,
  }) {
    final name = _mapLocalizedText(
      _requireMember(object, 'name', 'contributor', pointer: pointer),
      pointer: '$pointer/name',
    );
    final roleValue = object['role'];

    return Opds2Contributor(
      name: name,
      identifier: _optionalString(object['identifier'], name: 'identifier', pointer: pointer),
      sortAs: _optionalLocalizedText(object['sortAs'], pointer: '$pointer/sortAs'),
      roles: roleValue == null
          ? const <String>[]
          : _mapStringList(roleValue, pointer: '$pointer/role'),
      links: object['links'] == null
          ? const <Opds2Link>[]
          : _mapLinkArray(object['links'], pointer: '$pointer/links'),
    );
  }

  List<Opds2Subject> _mapSubjects(final Object? value, {required final String pointer}) {
    if (value == null) return const <Opds2Subject>[];
    if (value is String) {
      return <Opds2Subject>[Opds2Subject(name: Opds2LocalizedText.plain(value))];
    }
    final items = value is Map
        ? <Object?>[value]
        : _requireArray(value, 'subjects', pointer: pointer);
    final subjects = <Opds2Subject>[];
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      subjects.add(
        item is String
            ? Opds2Subject(name: Opds2LocalizedText.plain(item))
            : _mapSubjectObject(
                _requireObject(item, 'subject', pointer: '$pointer/$index'),
                pointer: '$pointer/$index',
              ),
      );
    }

    return subjects;
  }

  Opds2Subject _mapSubjectObject(
    final Map<Object?, Object?> object, {
    required final String pointer,
  }) {
    final name = _mapLocalizedText(
      _requireMember(object, 'name', 'subject', pointer: pointer),
      pointer: '$pointer/name',
    );

    return Opds2Subject(
      name: name,
      sortAs: _optionalLocalizedText(object['sortAs'], pointer: '$pointer/sortAs'),
      code: _optionalString(object['code'], name: 'code', pointer: pointer),
      scheme: _optionalString(object['scheme'], name: 'scheme', pointer: pointer),
      links: object['links'] == null
          ? const <Opds2Link>[]
          : _mapLinkArray(object['links'], pointer: '$pointer/links'),
    );
  }

  Opds2LocalizedText _mapLocalizedText(final Object? value, {required final String pointer}) {
    final text = _optionalLocalizedText(value, pointer: pointer);
    if (text == null || text.isEmpty) {
      throw Opds2MalformedException('value must be a string or a language map.', pointer: pointer);
    }

    return text;
  }

  Opds2LocalizedText? _optionalLocalizedText(final Object? value, {required final String pointer}) {
    if (value == null) return null;
    if (value is String) {
      return Opds2LocalizedText.plain(value);
    }
    if (value is Map) {
      final values = <String, String>{};
      for (final entry in value.entries) {
        if (entry.key is! String || entry.value is! String) {
          throw Opds2MalformedException(
            'language map must carry string values under BCP 47 keys.',
            pointer: pointer,
          );
        }
        final key = entry.key as String;
        if (!_isValidLanguageTag(key)) {
          throw Opds2MalformedException(
            '"$key" is not a valid BCP 47 language tag.',
            pointer: pointer,
          );
        }
        values[key] = entry.value as String;
      }

      return Opds2LocalizedText.mapped(Map.unmodifiable(values));
    }
    throw Opds2MalformedException('value must be a string or a language map.', pointer: pointer);
  }

  List<String> _mapStringList(final Object? value, {required final String pointer}) {
    if (value == null) return const <String>[];
    if (value is String) return <String>[value];
    final items = _requireArray(value, 'string list', pointer: pointer);
    return <String>[
      for (var index = 0; index < items.length; index++)
        _requireString(items[index], name: 'value', pointer: '$pointer/$index'),
    ];
  }

  List<Opds2Link> _mapImages(final Object? value, {required final String pointer}) {
    if (value == null) return const <Opds2Link>[];
    final items = _requireArray(value, 'images', pointer: pointer);
    if (items.length > limits.maxLinks) {
      throw Opds2LimitExceededException(
        'images array has ${items.length} entries, above the ${limits.maxLinks} limit.',
        pointer: pointer,
      );
    }
    if (items.isEmpty) {
      throw Opds2MalformedException('images must not be an empty array.', pointer: pointer);
    }
    final images = <Opds2Link>[];
    for (var index = 0; index < items.length; index++) {
      images.add(
        _mapLink(
          _requireObject(items[index], 'image', pointer: '$pointer/$index'),
          pointer: '$pointer/$index',
        ),
      );
    }
    const rasterTypes = <String>{
      'image/jpeg',
      'image/avif',
      'image/webp',
      'image/jxl',
      'image/png',
      'image/gif',
    };
    if (!images.any((final image) => image.type != null && rasterTypes.contains(image.type))) {
      throw Opds2MalformedException(
        'images must contain at least one jpeg, avif, webp, jxl, png, or gif resource.',
        pointer: pointer,
      );
    }

    return images;
  }

  Map<Object?, Object?> _requireObject(
    final Object? value,
    final String what, {
    required final String pointer,
  }) {
    if (value is Map<Object?, Object?>) return value;
    if (value is Map) return Map<Object?, Object?>.from(value);
    throw Opds2MalformedException('$what must be a JSON object.', pointer: pointer);
  }

  List<Object?> _requireArray(
    final Object? value,
    final String what, {
    required final String pointer,
  }) {
    if (value is List<Object?>) return value;
    if (value is List) return List<Object?>.from(value);
    throw Opds2MalformedException('$what must be a JSON array.', pointer: pointer);
  }

  Object? _requireMember(
    final Map<Object?, Object?> object,
    final String name,
    final String what, {
    final String pointer = '',
  }) {
    final value = object[name];
    if (value == null) {
      throw Opds2MalformedException('$what must carry "$name".', pointer: '$pointer/$name');
    }

    return value;
  }

  String _requireString(
    final Object? value, {
    required final String name,
    required final String pointer,
  }) {
    if (value is String) return value;
    throw Opds2MalformedException('"$name" must be a string.', pointer: '$pointer/$name');
  }

  String? _optionalString(
    final Object? value, {
    required final String name,
    required final String pointer,
  }) {
    if (value == null) return null;
    if (value is String) return value;
    throw Opds2MalformedException('"$name" must be a string.', pointer: '$pointer/$name');
  }

  bool _requireBool(final Object? value, {required final String pointer}) {
    if (value is bool) return value;
    throw Opds2MalformedException('value must be a boolean.', pointer: pointer);
  }

  num? _optionalNumber(
    final Object? value, {
    required final String name,
    required final String pointer,
  }) {
    if (value == null) return null;
    if (value is num) return value;
    throw Opds2MalformedException('"$name" must be a number.', pointer: '$pointer/$name');
  }

  int? _optionalCount(
    final Object? value, {
    required final String name,
    required final String pointer,
  }) {
    final number = _optionalNumber(value, name: name, pointer: pointer);
    if (number == null) return null;
    if (number is int) return number;
    if (number == number.truncate()) return number.toInt();
    throw Opds2MalformedException('"$name" must be an integer.', pointer: '$pointer/$name');
  }

  int? _optionalPositiveCount(
    final Object? value, {
    required final String name,
    required final String pointer,
  }) {
    final count = _optionalCount(value, name: name, pointer: pointer);
    if (count == null) return null;
    if (count <= 0) {
      throw Opds2MalformedException(
        '"$name" must be a positive integer.',
        pointer: '$pointer/$name',
      );
    }

    return count;
  }

  DateTime _requireDateTime(final Object? value, {required final String pointer}) {
    if (value is! String) {
      throw Opds2MalformedException(
        'timestamp must be an RFC 3339 date-time string.',
        pointer: pointer,
      );
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null || !(value.contains('T') || value.contains('t') || value.contains(' '))) {
      throw Opds2MalformedException('"$value" is not an RFC 3339 date-time.', pointer: pointer);
    }

    return parsed;
  }

  /// OPDS 2.0 expresses search as a URI template with at least one query
  /// parameter named "query" (normative text the official schema does not
  /// enforce). Simple `{...}` and form-style `{?...}` expressions count.
  bool _templateCarriesQuery(final String href) {
    final open = href.indexOf('{');
    if (open < 0) return false;
    final close = href.indexOf('}', open);
    if (close < 0) return false;
    var expression = href.substring(open + 1, close);
    if (expression.isNotEmpty && _templateOperators.contains(expression[0])) {
      expression = expression.substring(1);
    }
    for (final name in expression.split(',')) {
      if (name.trim() == 'query') return true;
    }

    return false;
  }

  String _escapeToken(final String token) => token.replaceAll('~', '~0').replaceAll('/', '~1');
}

/// Operators with special RFC 6570 meaning; anything else starts a simple
/// expansion.
const _templateOperators = <String>{'+', '#', '.', '/', ';', '?', '&'};

/// Lightweight BCP 47 shape check: alphanumeric subtags separated by
/// single hyphens, each 1-8 characters, 2-35 in total. Deliberately
/// simpler than the full schema pattern (which also pins grandfathered and
/// private-use forms); see doc/opds2.md.
bool _isValidLanguageTag(final String tag) {
  if (tag.isEmpty || tag.length > 35) return false;
  var partLength = 0;
  for (var index = 0; index < tag.length; index++) {
    final unit = tag.codeUnitAt(index);
    final isAlnum =
        (unit >= 0x30 && unit <= 0x39) ||
        (unit >= 0x41 && unit <= 0x5A) ||
        (unit >= 0x61 && unit <= 0x7A);
    if (isAlnum) {
      partLength++;
      continue;
    }
    if (unit == 0x2D) {
      if (partLength == 0 || partLength > 8) return false;
      partLength = 0;
      continue;
    }
    return false;
  }
  return partLength > 0 && partLength <= 8;
}
