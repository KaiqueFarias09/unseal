import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

String _feed({String metadata = '', String extraLinks = ''}) =>
    '{"metadata":{"title":"T"$metadata},"links":[{"href":".","rel":"self"}$extraLinks],'
    '"navigation":[{"href":"x","title":"X"}]}';

void main() {
  test('resource preflight rejects hostile structure before JSON decoding', () {
    // Each source is also syntactically incomplete. A post-decode check
    // would report malformed JSON instead of refusing its allocation.
    for (final (source, limits) in [
      ('[[[[', const Opds2Limits(maxDepth: 3)),
      ('[0,0,', const Opds2Limits(maxNodes: 2)),
      ('{"x":"aaaa', const Opds2Limits(maxStringLength: 3)),
      ('{"x":"\\u0061\\u0062\\u0063', const Opds2Limits(maxStringLength: 2)),
    ]) {
      expect(
        () => parseOpds2Feed(source, limits: limits),
        throwsA(isA<Opds2LimitExceededException>()),
      );
    }
  });

  test('string entry point counts UTF-8 bytes without allocating an encoded copy', () {
    final ascii = _feed();
    final unicode = ascii.replaceFirst('"T"', '"𝄞é"');
    expect(
      () => parseOpds2Feed(unicode, limits: Opds2Limits(maxBytes: unicode.length)),
      throwsA(isA<Opds2LimitExceededException>()),
    );
    expect(
      parseOpds2Feed(unicode, limits: Opds2Limits(maxBytes: utf8.encode(unicode).length)),
      isA<Opds2Feed>(),
    );
  });

  test('nonfinite JSON numbers are typed failures on strings and bytes', () {
    for (final number in ['1e999', '-1e999']) {
      for (final source in [
        _feed(metadata: ',"numberOfItems":$number'),
        _feed(extraLinks: ',{"href":"x","width":$number}'),
        _feed(extraLinks: ',{"href":"x","duration":$number}'),
        _feed(extraLinks: ',{"href":"x","properties":{"price":{"value":$number}}}'),
      ]) {
        expect(() => parseOpds2Feed(source), throwsA(isA<Opds2MalformedException>()));
        expect(
          () => parseOpds2FeedBytes(Uint8List.fromList(utf8.encode(source))),
          throwsA(isA<Opds2MalformedException>()),
        );
      }
    }
  });

  test('query can appear after other template expressions', () {
    final feed = parseOpds2Feed(
      _feed(extraLinks: ',{"href":"{lang}/search{?query}","rel":"search","templated":true}'),
    );
    expect(feed.links[1].href, '{lang}/search{?query}');
    expect(
      expandOpds2Template(feed.links[1].href, {'lang': 'pt', 'query': 'café'}),
      'pt/search?query=caf%C3%A9',
    );
  });

  test('calendar and clock overflow cannot normalize invalid modified dates', () {
    for (final timestamp in [
      '2026-02-31T00:00:00Z',
      '2026-13-01T00:00:00Z',
      '2026-01-01T24:00:00Z',
      '2026-01-01T00:60:00Z',
      '2026-01-01T00:00:61Z',
      '2026-01-01T00:00:00+24:00',
      '2026-01-01T00:00:00+00:60',
      '2026-01-01T00:00:00',
      '2026-01-01 00:00:00Z',
    ]) {
      expect(
        () => parseOpds2Feed(_feed(metadata: ',"modified":"$timestamp"')),
        throwsA(isA<Opds2MalformedException>()),
        reason: timestamp,
      );
    }
    for (final timestamp in [
      '2024-02-29T12:34:56.123Z',
      '2026-01-01t00:00:00z',
      '2026-01-01T00:00:00-03:00',
    ]) {
      expect(
        parseOpds2Feed(_feed(metadata: ',"modified":"$timestamp"')).metadata.modified,
        DateTime.parse(timestamp.toUpperCase()),
      );
    }
  });
}
