import 'dart:convert' as convert;

import 'package:test/test.dart';

import 'package:unseal/unseal.dart';

/// Resource bounds run before allocation (acceptance OJ06).
void main() {
  String feedWithManyPublications(final int count) {
    final publications = <String>[];
    for (var index = 0; index < count; index++) {
      publications.add(
        '{"metadata": {"title": "Book $index", "author": "A"},'
        '"links": [{"rel": "buy", "href": "https://x.example/buy/$index", "type": "text/html"}],'
        '"images": [{"href": "https://x.example/c$index.png", "type": "image/png"}]}',
      );
    }

    return '{"metadata": {"title": "Bulk"},'
        '"links": [{"rel": "self", "href": "https://x.example/feed", "type": "application/opds+json"}],'
        '"publications": [${publications.join(',')}]}';
  }

  const baseFeed =
      '{"metadata": {"title": "Host"},'
      '"links": [{"rel": "self", "href": "https://x.example/feed", "type": "application/opds+json"}],';

  test('byte bound rejects oversized input before decoding', () {
    const limits = Opds2Limits(maxBytes: 64);
    final big = '${baseFeed}x' * 200;
    expect(
      () => parseOpds2FeedBytes(convert.utf8.encode(big), limits: limits),
      throwsA(
        isA<Opds2LimitExceededException>().having(
          (final error) => error.message,
          'message',
          contains('byte limit'),
        ),
      ),
    );
  });

  test('depth bound rejects adversarial nesting', () {
    const limits = Opds2Limits(maxDepth: 8);
    final deep = '$baseFeed"deep": ${'[' * 40}${']' * 40}}';
    expect(
      () => parseOpds2Feed(deep, limits: limits),
      throwsA(
        isA<Opds2LimitExceededException>().having(
          (final error) => error.message,
          'message',
          contains('nests deeper'),
        ),
      ),
    );
  });

  test('node bound rejects value explosion before mapping', () {
    const limits = Opds2Limits(maxNodes: 50);
    final wide = feedWithManyPublications(30);
    expect(
      () => parseOpds2Feed(wide, limits: limits),
      throwsA(
        isA<Opds2LimitExceededException>().having(
          (final error) => error.message,
          'message',
          contains('value limit'),
        ),
      ),
    );
  });

  test('string bound rejects oversized values', () {
    const limits = Opds2Limits(maxStringLength: 32);
    final longTitle = '$baseFeed"navigation": [{"href": "/a", "title": "${'a' * 100}"}]}';
    expect(
      () => parseOpds2Feed(longTitle, limits: limits),
      throwsA(
        isA<Opds2LimitExceededException>().having(
          (final error) => error.message,
          'message',
          contains('character limit'),
        ),
      ),
    );
  });

  test('publication bound rejects oversized collections', () {
    const limits = Opds2Limits(maxPublications: 10);
    expect(
      () => parseOpds2Feed(feedWithManyPublications(11), limits: limits),
      throwsA(
        isA<Opds2LimitExceededException>().having(
          (final error) => error.message,
          'message',
          contains('publications collection'),
        ),
      ),
    );
  });

  test('group bound rejects oversized group arrays', () {
    const limits = Opds2Limits(maxGroups: 3);
    final groups = <String>[];
    for (var index = 0; index < 4; index++) {
      groups.add(
        '{"metadata": {"title": "G$index"},'
        '"navigation": [{"href": "/g$index", "title": "G$index", "type": "application/opds+json"}]}',
      );
    }
    expect(
      () => parseOpds2Feed('$baseFeed"groups": [${groups.join(',')}]}', limits: limits),
      throwsA(
        isA<Opds2LimitExceededException>().having(
          (final error) => error.message,
          'message',
          contains('groups collection'),
        ),
      ),
    );
  });

  test('link bound rejects oversized link arrays', () {
    const limits = Opds2Limits(maxLinks: 5);
    final links = <String>[];
    for (var index = 0; index < 6; index++) {
      links.add('{"href": "https://x.example/l$index", "rel": "related"}');
    }
    expect(
      () => parseOpds2Feed('$baseFeed"links": [${links.join(',')}]}', limits: limits),
      throwsA(
        isA<Opds2LimitExceededException>().having(
          (final error) => error.message,
          'message',
          contains('links array'),
        ),
      ),
    );
  });

  test('subcollection bound rejects member explosion', () {
    const limits = Opds2Limits(maxSubcollections: 3);
    final members = <String>[];
    for (var index = 0; index < 4; index++) {
      members.add(
        '"topic$index": {"metadata": {"title": "T$index"}, '
        '"links": [{"href": "https://x.example/t$index", "title": "T$index"}]}',
      );
    }
    expect(
      () => parseOpds2Feed(
        '$baseFeed${members.join(',')},'
        '"navigation": [{"href": "/b", "title": "B", "type": "application/opds+json"}]}',
        limits: limits,
      ),
      throwsA(
        isA<Opds2LimitExceededException>().having(
          (final error) => error.message,
          'message',
          contains('subcollection members'),
        ),
      ),
    );
  });

  test('group publications share the publication bound', () {
    const limits = Opds2Limits(maxPublications: 3);
    final publications = <String>[];
    for (var index = 0; index < 4; index++) {
      publications.add(
        '{"metadata": {"title": "B$index"},'
        '"links": [{"rel": "buy", "href": "https://x.example/b$index"}],'
        '"images": [{"href": "https://x.example/b$index.png", "type": "image/png"}]}',
      );
    }
    final grouped =
        '$baseFeed"groups": [{"metadata": {"title": "G"}, "publications": [${publications.join(',')}]}]}';
    expect(
      () => parseOpds2Feed(grouped, limits: limits),
      throwsA(isA<Opds2LimitExceededException>()),
    );
  });

  test('large feeds within generous limits still parse', () {
    final big = feedWithManyPublications(2000);
    final feed = parseOpds2Feed(big);
    expect(feed.publications, hasLength(2000));
    expect(feed.publications.last.metadata.title.resolve(), 'Book 1999');
  });

  test('deep nesting within the default depth parses', () {
    const nested = '''
    {
      "metadata": {"title": "Nested"},
      "links": [{"rel": "self", "href": "https://x.example/feed", "type": "application/opds+json"}],
      "navigation": [{"href": "/b", "title": "B", "type": "application/opds+json"}],
      "top": {
        "metadata": {"title": "Top"},
        "links": [{"href": "/top"}],
        "mid": {
          "metadata": {"title": "Mid"},
          "links": [{"href": "/mid"}],
          "deep": {
            "metadata": {"title": "Deep"},
            "links": [{"href": "/deep"}]
          }
        }
      }
    }
    ''';
    final feed = parseOpds2Feed(nested);
    expect(
      feed.subcollections['top']!.children['mid']!.children['deep']!.links.single.href,
      '/deep',
    );
  });
}
