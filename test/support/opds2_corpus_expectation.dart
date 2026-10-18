import 'dart:convert' as convert;

import 'package:crypto/crypto.dart' as crypto;

import 'package:unseal/unseal.dart';

/// Builds the per-feed summary the C05 Python oracle pins in
/// `test/resources/opds/expected/` and checks the Dart model against.
///
/// The shape mirrors `feed_summary` in `tool/opds2_schema_oracle.py`;
/// change both together.
Map<Object?, Object?> summarizeFeed(final Opds2Feed feed, final String name) {
  return <Object?, Object?>{
    'feed': name,
    'metadata': <Object?, Object?>{
      'title': _langMap(feed.metadata.title),
      'identifier': feed.metadata.identifier,
      'modified': _iso(feed.metadata.modified),
      'description': feed.metadata.description,
      'numberOfItems': feed.metadata.numberOfItems,
      'itemsPerPage': feed.metadata.itemsPerPage,
      'currentPage': feed.metadata.currentPage,
    },
    'self': feed.selfLink == null
        ? null
        : <Object?, Object?>{'href': feed.selfLink!.href, 'type': feed.selfLink!.type},
    'links': feed.links.map(_link).toList(),
    'navigation': feed.navigation
        .map(
          (final link) => <Object?, Object?>{
            'title': _langMap(link.title == null ? null : Opds2LocalizedText.plain(link.title!)),
            'href': link.href,
            'rels': link.rels,
            'type': link.type,
          },
        )
        .toList(),
    'facets': feed.facets
        .map(
          (final facet) => <Object?, Object?>{
            'title': _langMap(facet.metadata.title),
            'links': facet.links.map(_link).toList(),
          },
        )
        .toList(),
    'groups': feed.groups
        .map(
          (final group) => <Object?, Object?>{
            'title': _langMap(group.metadata.title),
            'self': group.selfLink?.href,
            // Group navigation titles stay raw in the reference.
            'navigation': group.navigation
                .map((final link) => <Object?, Object?>{'title': link.title, 'href': link.href})
                .toList(),
            'publications': group.publications.map(_publication).toList(),
          },
        )
        .toList(),
    'publications': feed.publications.map(_publication).toList(),
    'subcollections':
        (feed.subcollections.values.toList()..sort((final a, final b) => a.key.compareTo(b.key)))
            .map(
              (final subcollection) => <Object?, Object?>{
                'key': subcollection.key,
                'title': subcollection.metadata['title'],
                'linksCount': subcollection.links.length,
              },
            )
            .toList(),
    'acquisitionRels': _allAcquisitionRels(feed),
  };
}

/// Summarizes a single standalone publication (shape of one element of the
/// `publications` array).
Map<Object?, Object?> summarizePublication(final Opds2Publication publication) =>
    _publication(publication);

String sha256OfBytes(final List<int> bytes) => crypto.sha256.convert(bytes).toString();

List<String> _allAcquisitionRels(final Opds2Feed feed) {
  final rels = <String>{};
  void collect(final Iterable<Opds2Link> links) {
    for (final link in links) {
      rels.addAll(link.rels.where(isOpds2AcquisitionRel));
    }
  }

  collect(feed.links);
  collect(feed.navigation);
  for (final facet in feed.facets) {
    collect(facet.links);
  }
  for (final publication in feed.publications) {
    collect(publication.links);
  }
  for (final group in feed.groups) {
    collect(group.links);
    collect(group.navigation);
    for (final inner in group.publications) {
      collect(inner.links);
    }
  }

  return rels.toList()..sort();
}

Map<Object?, Object?> _publication(final Opds2Publication publication) {
  return <Object?, Object?>{
    'title': _langMap(publication.metadata.title),
    'sortAs': publication.metadata.sortAs == null ? null : _langMap(publication.metadata.sortAs!),
    'subtitle': publication.metadata.subtitle == null
        ? null
        : _langMap(publication.metadata.subtitle!),
    'identifier': publication.metadata.identifier,
    'languages': publication.metadata.languages,
    'authors': <Object?>[for (final author in publication.metadata.authors) author.name.resolve()],
    'published': publication.metadata.published,
    'modified': _iso(publication.metadata.modified),
    'links': publication.links.map(_link).toList(),
    'images': publication.images
        .map(
          (final image) => <Object?, Object?>{
            'href': image.href,
            'type': image.type,
            'width': image.width,
            'height': image.height,
          },
        )
        .toList(),
  };
}

Map<Object?, Object?> _link(final Opds2Link link) {
  return <Object?, Object?>{
    'rels': link.rels,
    'href': link.href,
    'type': link.type,
    'templated': link.templated,
  };
}

Object? _langMap(final Opds2LocalizedText? value) {
  if (value == null) return null;
  if (value.plain != null) return <Object?, Object?>{'und': value.plain};
  return <Object?, Object?>{for (final entry in value.values.entries) entry.key: entry.value};
}

String? _iso(final DateTime? value) {
  if (value == null) return null;
  final utc = value.toUtc();
  String two(final int number) => number.toString().padLeft(2, '0');

  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
      'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}.000Z';
}

/// Expected failure pointer per negative/normative-only corpus fixture,
/// verified against the Python schema reference and pinned here so the VM
/// and Chrome suites assert the same behavior.
const Map<String, String?> opds2ExpectedFailurePointers = <String, String?>{
  'negative-missing-self.json': '/links',
  'negative-missing-title.json': '/metadata/title',
  'negative-wrong-type.json': '/links',
  'negative-no-collection.json': '',
  'negative-publication-without-acquisition.json': '/publications/0/links',
  'negative-images-without-raster.json': '/publications/0/images',
  'negative-publication-without-title.json': '/publications/0/metadata/title',
  'negative-truncated.json': null,
  'spec-facets-fragment.json': '/metadata',
  'spec-publications-feed.json': '/publications/0/links',
  'spec-groups-featured-feed.json': '/groups/1/publications/0/links',
  'spec-paginated-feed.json': '',
};

/// Decodes a pinned expectation JSON string into the comparable shape.
Map<Object?, Object?> decodeExpectation(final String json) =>
    convert.jsonDecode(json) as Map<Object?, Object?>;
