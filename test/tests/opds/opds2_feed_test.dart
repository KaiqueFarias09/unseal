import 'package:test/test.dart';

import 'package:unseal/opds.dart' as opds;
import 'package:unseal/unseal.dart';

const String feedWithEverything = '''
{
  "metadata": {
    "title": {"en": "Everything feed", "pt-BR": "Feed completo"},
    "identifier": "https://example.org/feed",
    "modified": "2026-10-18T12:00:00Z",
    "numberOfItems": 42,
    "itemsPerPage": 10,
    "currentPage": 2,
    "unknownMeta": {"kept": "out of the model"}
  },
  "links": [
    {"rel": "self", "href": "https://example.org/feed?page=2", "type": "application/opds+json"},
    {"rel": ["first", "previous"], "href": "https://example.org/feed?page=1", "type": "application/opds+json"},
    {"rel": "next", "href": "https://example.org/feed?page=3", "type": "application/opds+json"},
    {"rel": "search", "href": "https://example.org/search{?query,title}", "type": "application/opds+json", "templated": true}
  ],
  "navigation": [
    {"href": "/by-title", "title": "By title", "type": "application/opds+json"},
    {"href": "/by-author", "title": "By author", "rel": "subsection", "type": "application/opds+json"}
  ],
  "publications": [
    {
      "metadata": {
        "title": "Moby-Dick",
        "identifier": "urn:isbn:978031600000X",
        "author": [{"name": "Herman Melville", "sortAs": "Melville, Herman", "role": "aut"}],
        "language": "en",
        "modified": "2015-09-29T17:00:00Z"
      },
      "links": [
        {"rel": "self", "href": "https://example.org/pub/moby.json", "type": "application/opds-publication+json"},
        {"rel": "http://opds-spec.org/acquisition/open-access", "href": "https://example.org/pub/moby.epub", "type": "application/epub+zip",
         "properties": {"indirectAcquisition": [{"type": "application/pdf"}]}}
      ],
      "images": [
        {"href": "https://example.org/cover-small.png", "type": "image/png", "width": 200, "height": 300},
        {"href": "https://example.org/cover.jpg", "type": "image/jpeg", "width": 800, "height": 1200}
      ]
    }
  ],
  "facets": [
    {
      "metadata": {"title": "Sort"},
      "links": [
        {"href": "/feed?sort=title", "title": "Title", "type": "application/opds+json", "properties": {"numberOfItems": 42}},
        {"href": "/feed?sort=author", "title": "Author", "type": "application/opds+json"}
      ]
    }
  ],
  "groups": [
    {
      "metadata": {"title": "Featured", "numberOfItems": 1},
      "links": [{"rel": "self", "href": "https://example.org/featured", "type": "application/opds+json"}],
      "publications": [
        {
          "metadata": {"title": "Dom Casmurro", "author": "Machado de Assis", "identifier": "urn:x:dom"},
          "links": [{"rel": "buy", "href": "https://shop.example/dom", "type": "text/html",
                     "properties": {"price": {"value": 19.9, "currency": "BRL"}}}],
          "images": [{"href": "https://covers.example/dom.gif", "type": "image/gif"}]
        }
      ]
    },
    {
      "metadata": {"title": "Browse"},
      "navigation": [{"href": "/new", "title": "New", "type": "application/opds+json"}]
    }
  ]
}
''';

void main() {
  late final opds.Opds2Feed feed;
  setUpAll(() {
    feed = opds.parseOpds2Feed(feedWithEverything);
  });

  test('main and narrow entry points expose the OPDS 2 API', () {
    // Same types are reachable through the main entry point.
    expect(identical(opds.Opds2Feed, Opds2Feed), isTrue);
    expect(identical(opds.parseOpds2Feed, parseOpds2Feed), isTrue);
    expect(identical(opds.Opds2Exception, Opds2Exception), isTrue);

    // The existing Atom 1.x API stays intact beside the JSON one.
    const atom =
        '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">'
        '<id>urn:a</id><title>Atom feed</title></feed>';
    final atomFeed = OpdsFeed.parse(atom);
    expect(atomFeed.title, 'Atom feed');
    expect(opds.OpdsFeed, same(OpdsFeed));
  });

  test('parses feed metadata with pagination counters', () {
    expect(feed.metadata.title.resolve(), 'Everything feed');
    expect(feed.metadata.title.resolve(language: 'pt-BR'), 'Feed completo');
    expect(feed.metadata.identifier, 'https://example.org/feed');
    expect(feed.metadata.modified, DateTime.utc(2026, 10, 18, 12));
    expect(feed.metadata.numberOfItems, 42);
    expect(feed.metadata.itemsPerPage, 10);
    expect(feed.metadata.currentPage, 2);
    // Unknown metadata members follow the documented extension policy:
    // dropped, not surfaced as speculative aliases.
    expect(() => (feed.metadata as dynamic).unknownMeta, throwsNoSuchMethodError);
  });

  test('maps self, pagination, and search links including rel lists', () {
    expect(feed.selfLink!.href, 'https://example.org/feed?page=2');
    expect(feed.nextLink!.href, 'https://example.org/feed?page=3');
    expect(feed.firstLink!.rels, <String>['first', 'previous']);
    expect(feed.previousLink!.href, 'https://example.org/feed?page=1');
    expect(feed.searchLink!.isTemplate, isTrue);
    expect(feed.searchLink!.hasTemplateExpression, isTrue);
    expect(
      expandOpds2Template(feed.searchLink!.href, {'query': 'melville', 'title': 'sea'}),
      'https://example.org/search?query=melville&title=sea',
    );
    expect(expandOpds2Template(feed.searchLink!.href, {}), 'https://example.org/search');
  });

  test('navigation links carry their required titles', () {
    expect(feed.navigation, hasLength(2));
    expect(feed.navigation.first.title, 'By title');
    expect(feed.navigation.last.hasRel('subsection'), isTrue);
  });

  test('publications map contributors, languages, acquisition and images', () {
    final publication = feed.publications.single;
    expect(publication.metadata.title.resolve(), 'Moby-Dick');
    expect(publication.metadata.languages, <String>['en']);
    final author = publication.metadata.authors.single;
    expect(author.name.resolve(), 'Herman Melville');
    expect(author.sortAs!.resolve(), 'Melville, Herman');
    expect(author.roles, <String>['aut']);
    expect(publication.acquisitionLinks, hasLength(1));
    expect(
      publication.acquisitionLinks.single.properties!.indirectAcquisitions.single.type,
      'application/pdf',
    );
    expect(publication.images, hasLength(2));
    expect(publication.bestImage!.href, 'https://example.org/cover.jpg');
    expect(publication.selfLink!.href, 'https://example.org/pub/moby.json');
  });

  test('acquisition relations include the short and URI forms', () {
    expect(isOpds2AcquisitionRel('buy'), isTrue);
    expect(isOpds2AcquisitionRel('borrow'), isTrue);
    expect(isOpds2AcquisitionRel('http://opds-spec.org/acquisition/open-access'), isTrue);
    expect(isOpds2AcquisitionRel('detail'), isFalse);
    expect(feed.isAcquisition, isTrue);
  });

  test('facets carry titled metadata and per-facet links', () {
    final facet = feed.facets.single;
    expect(facet.metadata.title.resolve(), 'Sort');
    expect(facet.links, hasLength(2));
    expect(facet.links.first.properties!.numberOfItems, 42);
  });

  test('groups nest publications and navigation under titled metadata', () {
    expect(feed.groups, hasLength(2));
    final featured = feed.groups.first;
    expect(featured.metadata.title.resolve(), 'Featured');
    expect(featured.selfLink!.href, 'https://example.org/featured');
    final casmurro = featured.publications.single;
    expect(casmurro.metadata.title.resolve(), 'Dom Casmurro');
    expect(casmurro.metadata.authors.single.name.resolve(), 'Machado de Assis');
    expect(casmurro.acquisitionLinks.single.properties!.price.toString(), '19.9 BRL');
    final browse = feed.groups.last;
    expect(browse.publications, isEmpty);
    expect(browse.navigation.single.title, 'New');
  });

  test('parses standalone publication documents', () {
    const document = '''
    {
      "metadata": {"title": "Standalone", "identifier": "urn:x:standalone"},
      "links": [
        {"rel": "self", "href": "https://example.org/pub.json", "type": "application/opds-publication+json"},
        {"rel": "preview", "href": "https://example.org/pub.html", "type": "text/html"}
      ],
      "images": [{"href": "https://example.org/cover.png", "type": "image/png"}]
    }
    ''';
    final publication = parseOpds2Publication(document);
    expect(publication.metadata.title.resolve(), 'Standalone');
    expect(publication.selfLink, isNotNull);
    expect(publication.acquisitionLinks.single.relName, 'preview');
  });

  test('uri helpers keep unknown schemes as data and expand templates', () {
    final href = resolveOpds2Href(
      'opds://catalog.example/root',
      baseUrl: Uri.parse('https://example.org/feed'),
    );
    expect(href.toString(), 'opds://catalog.example/root');

    final resolved = resolveOpds2Href(
      '/page/2',
      baseUrl: Uri.parse('https://example.org/feed?page=2#top'),
    );
    expect(resolved.toString(), 'https://example.org/page/2');

    // Unsupported expression forms stay literal.
    expect(expandOpds2Template('/a{+path}/b{/list}', {'path': 'x'}), '/a{+path}/b{/list}');
    expect(expandOpds2Template('/s{?query}', {'query': 'a b'}), '/s?query=a%20b');
  });
}

extension on Opds2Link {
  String? get relName => rels.isEmpty ? null : rels.first;
}
