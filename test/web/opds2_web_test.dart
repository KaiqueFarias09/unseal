@TestOn('browser')
library;

import 'dart:convert' as convert;

import 'package:test/test.dart';

import 'package:unseal/unseal.dart';

import '../support/opds2_corpus_expectation.dart';

import '../support/opds2_shared_cases.dart';

/// The same corpus cases the VM suite runs, executed in the browser to
/// prove the model and parser are platform-neutral (acceptance OJ07).
///
/// OPDS parsing never crosses the worker wire: it is a pure library call
/// on both platforms, so this suite exercises the identical public code
/// without a worker lane.
void main() {
  group('positive corpus in Chrome matches the pinned reference', () {
    for (final shared in opds2SharedCases) {
      if (shared.kind != 'positive') continue;
      test(shared.name, () {
        final feed = parseOpds2Feed(shared.source);
        expect(summarizeFeed(feed, shared.name), decodeExpectation(shared.expectedSummaryJson!));
      });
    }
  });

  group('negative and normative corpus in Chrome fails typed', () {
    for (final shared in opds2SharedCases) {
      if (shared.kind == 'positive') continue;
      test(shared.name, () {
        try {
          parseOpds2Feed(shared.source);
          fail('expected rejection');
        } on Opds2Exception catch (error) {
          if (shared.kind == 'negative') {
            expect(error.pointer, opds2ExpectedFailurePointers[shared.name], reason: shared.name);
          } else {
            expect(error.pointer, isNotNull, reason: shared.name);
          }
        }
      });
    }
  });

  group('relative resolution in Chrome matches the urljoin reference', () {
    final resolution = convert.jsonDecode(opds2SharedResolutionJson) as Map<String, Object?>;
    for (final case_ in (resolution['cases']! as List<Object?>).cast<Map<String, Object?>>()) {
      test('"${case_['relative']}"', () {
        final resolved = resolveOpds2Href(
          case_['relative']! as String,
          baseUrl: Uri.parse(case_['base']! as String),
        );
        expect(resolved.toString(), case_['expected']);
      });
    }
  });

  test('two feeds parsed in sequence share no state', () {
    final feedbooks = parseOpds2Feed(
      opds2SharedCases.firstWhere((final shared) => shared.name == 'feedbooks-home.json').source,
    );
    final synthetic = parseOpds2Feed(
      opds2SharedCases
          .firstWhere((final shared) => shared.name == 'synthetic-facets-groups.json')
          .source,
    );

    expect(feedbooks.metadata.title.resolve(), 'OPDS 2.0 Test Catalog');
    expect(synthetic.metadata.title.resolve(), 'Grouped catalog with facets and subcollections');
    expect(feedbooks.groups, hasLength(3));
    expect(synthetic.facets, hasLength(2));
    expect(synthetic.subcollections['latest'], isNotNull);
  });

  test('byte-independent limits still guard the browser parse', () {
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
  });
}
