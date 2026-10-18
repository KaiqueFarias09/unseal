import 'dart:convert' as convert;

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:unseal/unseal.dart';

/// Typed failures, extension policy, and out-of-scope families for the
/// OPDS 2.0 parser (acceptance OJ05).
void main() {
  Opds2Exception failureFor(String source) {
    try {
      parseOpds2Feed(source);
    } on Opds2Exception catch (error) {
      return error;
    }
    fail('expected rejection');
  }

  group('wrong value types fail with a JSON pointer', () {
    test('metadata as array', () {
      final error = failureFor('{"metadata": [], "links": []}');
      expect(error, isA<Opds2MalformedException>());
      expect(error.pointer, '/metadata');
    });

    test('title as number', () {
      final error = failureFor('{"metadata": {"title": 42}, "links": []}');
      expect(error.pointer, '/metadata/title');
    });

    test('links as object', () {
      final error = failureFor('{"metadata": {"title": "x"}, "links": {}}');
      expect(error.pointer, '/links');
    });

    test('link without href', () {
      final error = failureFor(
        '{"metadata": {"title": "x"}, "links": [{"rel": "self", "type": "application/opds+json"}]}',
      );
      expect(error.pointer, '/links/0/href');
    });

    test('rel as number', () {
      final error = failureFor(
        '{"metadata": {"title": "x"}, "links": [{"rel": 1, "href": "/a"}], "navigation": [{"href": "/b", "title": "B"}]}',
      );
      expect(error.pointer, '/links/0/rel');
    });

    test('modified not a date-time', () {
      final error = failureFor(
        '{"metadata": {"title": "x", "modified": "last week"}, "links": [], "navigation": [{"href": "/b", "title": "B"}]}',
      );
      expect(error.pointer, '/metadata/modified');
    });

    test('contributor object without name', () {
      final error = failureFor(
        '{"metadata": {"title": "x"}, "links": [{"rel": "self", "href": "https://x.example/feed", "type": "application/opds+json"}], '
        '"publications": [{"metadata": {"title": "B", "author": {"identifier": "urn:a"}}, "links": [{"rel": "buy", "href": "/b"}]}]}',
      );
      expect(error.pointer, '/publications/0/metadata/author/0/name');
    });

    test('price without value', () {
      final error = failureFor(
        '{"metadata": {"title": "x"}, "links": [{"rel": "self", "href": "https://x.example/feed", "type": "application/opds+json"}], '
        '"publications": [{"metadata": {"title": "B"}, "links": [{"rel": "buy", "href": "/b", "properties": {"price": {"currency": "BRL"}}}]}]}',
      );
      expect(error.pointer, '/publications/0/links/0/properties/price/value');
    });

    test('availability with unknown state', () {
      final error = failureFor(
        '{"metadata": {"title": "x"}, "links": [{"rel": "self", "href": "https://x.example/feed", "type": "application/opds+json"}], '
        '"publications": [{"metadata": {"title": "B"}, "links": [{"rel": "borrow", "href": "/b", "properties": {"availability": {"state": "maybe"}}}]}]}',
      );
      expect(error.pointer, '/publications/0/links/0/properties/availability/state');
    });

    test('encrypted without algorithm', () {
      final error = failureFor(
        '{"metadata": {"title": "x"}, "links": [{"rel": "self", "href": "https://x.example/feed", "type": "application/opds+json"}], '
        '"publications": [{"metadata": {"title": "B"}, "links": [{"rel": "buy", "href": "/b", "properties": {"encrypted": {}}}]}]}',
      );
      expect(error.pointer, '/publications/0/links/0/properties/encrypted/algorithm');
    });
  });

  group('truncated and broken input fails typed', () {
    test('mid-string truncation', () {
      final error = failureFor('{"metadata": {"title": "Trunc');
      expect(error, isA<Opds2MalformedException>());
      expect(error.message, contains('not valid JSON'));
    });

    test('empty input', () {
      expect(failureFor('').message, contains('not valid JSON'));
    });

    test('top-level array', () {
      final error = failureFor('[1, 2, 3]');
      expect(error.pointer, '');
    });

    test('invalid UTF-8 bytes through the byte entry point', () {
      expect(
        () => parseOpds2FeedBytes(Uint8List.fromList(<int>[0x7b, 0x22, 0xff, 0xfe, 0x7d])),
        throwsA(
          isA<Opds2MalformedException>().having(
            (final error) => error.message,
            'message',
            contains('UTF-8'),
          ),
        ),
      );
    });
  });

  group('out-of-scope JSON families fail typed, not silently', () {
    test('OPDS Authentication Document', () {
      const authentication = '''
      {
        "id": "https://auth.example/authn",
        "title": "Library authentication",
        "authentication": [
          {"type": "http://opds-spec.org/auth/basic", "links": [{"rel": "authenticate", "href": "https://auth.example/login"}]}
        ],
        "links": [{"rel": "self", "href": "https://auth.example/authn", "type": "application/opds-authentication+json"}]
      }
      ''';
      final error = failureFor(authentication);
      // Authentication Documents are not feeds: they lack feed metadata
      // (and any collection role).
      expect(error.pointer, '/metadata');
    });

    test('Open Distribution to Libraries (ODL) loan document', () {
      const odl = '''
      {
        "@context": "https://schema.org",
        "loanLinks": [{"href": "https://odl.example/loan/1"}]
      }
      ''';
      final error = failureFor(odl);
      expect(error, isA<Opds2MalformedException>());
    });

    test('an ordinary webpub manifest is not an OPDS feed', () {
      const webpub = '''
      {
        "metadata": {"title": "A webpub"},
        "links": [{"rel": "self", "href": "https://x.example/pub.json"}],
        "readingOrder": [{"href": "https://x.example/ch1.html", "type": "text/html"}]
      }
      ''';
      // readingOrder is an unknown member: the feed schema maps it as a
      // subcollection, but a member that is neither a collection nor a
      // valid subcollection rejects. Here it is a valid compact array, so
      // the failure is the missing collection role.
      final error = failureFor(webpub);
      expect(error.message, contains('at least one navigation, publications, or groups'));
    });
  });

  group('unknown extensions follow the documented policy', () {
    test('unknown feed member must still be a valid subcollection', () {
      final error = failureFor(
        '{"metadata": {"title": "x"}, "links": [{"rel": "self", "href": "https://x.example/feed"}], '
        '"latest": "just a string", "navigation": [{"href": "/b", "title": "B"}]}',
      );
      expect(error.pointer, '/latest');
    });

    test('valid subcollection members map as data', () {
      const withSubcollection = '''
      {
        "metadata": {"title": "With subcollection"},
        "links": [{"rel": "self", "href": "https://x.example/feed", "type": "application/opds+json"}],
        "navigation": [{"href": "/b", "title": "B", "type": "application/opds+json"}],
        "latest": {
          "metadata": {"title": "Latest"},
          "links": [{"href": "https://x.example/latest", "title": "Latest", "type": "application/opds+json"}]
        }
      }
      ''';
      final parsed = parseOpds2Feed(withSubcollection);
      final latest = parsed.subcollections['latest']!;
      expect(latest.metadata['title'], 'Latest');
      expect(latest.links.single.href, 'https://x.example/latest');
      // No speculative alias hides the same data elsewhere.
      expect(parsed.navigation, hasLength(1));
    });

    test('nested subcollections keep their children', () {
      const nested = '''
      {
        "metadata": {"title": "Nested"},
        "links": [{"rel": "self", "href": "https://x.example/feed", "type": "application/opds+json"}],
        "navigation": [{"href": "/b", "title": "B", "type": "application/opds+json"}],
        "topics": {
          "metadata": {"title": "Topics"},
          "links": [{"href": "https://x.example/topics", "title": "Topics"}],
          "science": {
            "metadata": {"title": "Science"},
            "links": [{"href": "https://x.example/science", "title": "Science"}]
          }
        }
      }
      ''';
      final parsed = parseOpds2Feed(nested);
      final topics = parsed.subcollections['topics']!;
      expect(topics.children['science']!.links.single.href, 'https://x.example/science');
    });
  });

  group('required-member policy', () {
    test('feed without metadata fails at the pointer', () {
      final error = failureFor('{"links": []}');
      expect(error.pointer, '/metadata');
    });

    test('feed without links fails at the pointer', () {
      final error = failureFor('{"metadata": {"title": "x"}}');
      expect(error.pointer, '/links');
    });

    test('valid minimal feed parses without extra state', () {
      const minimal = '''
      {
        "metadata": {"title": "Minimal"},
        "links": [{"rel": "self", "href": "https://x.example/feed", "type": "application/opds+json"}],
        "navigation": [{"href": "https://x.example/a", "title": "A", "type": "application/opds+json"}]
      }
      ''';
      final parsed = parseOpds2Feed(minimal);
      expect(convert.jsonEncode(parsed.metadata.title.resolve()), '"Minimal"');
    });
  });
}
