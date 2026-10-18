import 'dart:convert' as convert;

import 'package:test/test.dart';

import 'package:unseal/unseal.dart';

/// Two calls over distinct feeds share no state (acceptance OJ07).
void main() {
  const firstFeed = '''
  {
    "metadata": {"title": "First", "identifier": "urn:first", "modified": "2026-01-01T00:00:00Z"},
    "links": [{"rel": "self", "href": "https://a.example/feed", "type": "application/opds+json"}],
    "navigation": [{"href": "https://a.example/a", "title": "A", "type": "application/opds+json"}],
    "publications": [
      {
        "metadata": {"title": "First book", "author": "Alpha"},
        "links": [{"rel": "buy", "href": "https://a.example/buy/1"}],
        "images": [{"href": "https://a.example/1.png", "type": "image/png"}]
      }
    ]
  }
  ''';

  const secondFeed = '''
  {
    "metadata": {"title": "Second", "identifier": "urn:second", "modified": "2026-02-02T00:00:00Z"},
    "links": [{"rel": "self", "href": "https://b.example/feed", "type": "application/opds+json"}],
    "navigation": [{"href": "https://b.example/b", "title": "B", "type": "application/opds+json"}]
  }
  ''';

  test('parsing the second feed never sees the first feed data', () {
    final first = parseOpds2Feed(firstFeed);
    final second = parseOpds2Feed(secondFeed);

    expect(first.metadata.title.resolve(), 'First');
    expect(second.metadata.title.resolve(), 'Second');
    expect(first.publications, hasLength(1));
    expect(second.publications, isEmpty);
    expect(first.navigation.single.href, 'https://a.example/a');
    expect(second.navigation.single.href, 'https://b.example/b');
    expect(first.metadata.modified, DateTime.utc(2026, 1, 1));
    expect(second.metadata.modified, DateTime.utc(2026, 2, 2));
  });

  test('reparsing the same source is deterministic', () {
    final one = summarize(convert.jsonDecode('null'), source: firstFeed, name: 'first.json');
    final two = summarize(convert.jsonDecode('null'), source: firstFeed, name: 'first.json');

    expect(one, two);
  });

  test('byte and string entry points agree', () {
    final bytes = convert.utf8.encode(firstFeed);
    final fromString = parseOpds2Feed(firstFeed);
    final fromBytes = parseOpds2FeedBytes(bytes);

    expect(fromBytes.metadata.title.resolve(), fromString.metadata.title.resolve());
    expect(fromBytes.publications, hasLength(fromString.publications.length));
    expect(fromBytes.links.length, fromString.links.length);
  });

  test('limit failures do not poison later successful parses', () {
    const limits = Opds2Limits(maxPublications: 1);
    const wide = '''
    {
      "metadata": {"title": "Wide"},
      "links": [{"rel": "self", "href": "https://x.example/feed", "type": "application/opds+json"}],
      "publications": [
        {"metadata": {"title": "One"}, "links": [{"rel": "buy", "href": "/1"}]},
        {"metadata": {"title": "Two"}, "links": [{"rel": "buy", "href": "/2"}]}
      ]
    }
    ''';
    expect(() => parseOpds2Feed(wide, limits: limits), throwsA(isA<Opds2LimitExceededException>()));
    final after = parseOpds2Feed(secondFeed);
    expect(after.metadata.title.resolve(), 'Second');
  });
}

Map<Object?, Object?> summarize(
  final Object? ignored, {
  required final String source,
  required final String name,
}) {
  final feed = parseOpds2Feed(source);
  final metadata = <Object?, Object?>{
    'title': feed.metadata.title.resolve(),
    'identifier': feed.metadata.identifier,
    'modified': feed.metadata.modified?.toUtc().toIso8601String(),
    'navigation': <Object?>[for (final link in feed.navigation) link.href],
    'publications': <Object?>[
      for (final publication in feed.publications) publication.metadata.title.resolve(),
    ],
  };
  // The ignored argument keeps the signature stable for callers that build
  // JSON values first.
  if (ignored != null) metadata['ignored'] = ignored;
  return metadata;
}
