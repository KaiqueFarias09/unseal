import 'dart:convert';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

HighlightRecord highlight({
  final String color = 'yellow',
  final bool withNote = true,
  final bool withCfi = true,
}) {
  return HighlightRecord(
    id: 'h1',
    sectionIndex: 3,
    start: 120,
    end: 180,
    text: 'highlighted words',
    before: 'context before ',
    after: ' context after',
    color: color == 'yellow'
        ? PaletteHighlightColor.yellow
        : CustomHighlightColor(lightHex: '#12d8ff', darkHex: '#0a5566'),
    decoration: HighlightDecoration.underline,
    note: withNote ? 'a note' : null,
    createdAt: DateTime.utc(2024, 6, 29, 3, 21, 48).add(const Duration(microseconds: 895323)),
    cfi: withCfi ? 'epubcfi(/6/4!/4/2,/1:0,/1:17)' : null,
  );
}

BookmarkRecord bookmark({final bool withNote = true}) {
  return BookmarkRecord(
    id: 'b1',
    title: 'Chapter two',
    sectionIndex: 2,
    charOffset: 340,
    createdAt: DateTime.utc(2024, 7, 1, 10, 0, 0),
    note: withNote ? 'reread here' : null,
  );
}

void main() {
  test('exposes its canonical text locator with relocation context', () {
    final record = highlight();

    expect(
      record.locator,
      const TextLocator(
        sectionIndex: 3,
        start: 120,
        end: 180,
        quote: TextQuote(
          before: 'context before ',
          text: 'highlighted words',
          after: ' context after',
        ),
      ),
    );
  });

  group('encodeAnnotations', () {
    test('writes the versioned envelope with both collections', () {
      final encoded =
          jsonDecode(encodeAnnotations(const AnnotationCollection(highlights: [], bookmarks: [])))
              as Map<String, dynamic>;
      expect(encoded['formatVersion'], 1);
      expect(encoded['highlights'], isEmpty);
      expect(encoded['bookmarks'], isEmpty);
    });

    test('writes the canonical field vocabulary with sectionIndex', () {
      final encoded =
          jsonDecode(
                encodeAnnotations(AnnotationCollection(highlights: [highlight()], bookmarks: [])),
              )
              as Map<String, dynamic>;
      final json = (encoded['highlights'] as List<dynamic>).single as Map<String, dynamic>;
      expect(
        json.keys,
        containsAll(['id', 'sectionIndex', 'start', 'end', 'text', 'before', 'after']),
      );
      expect(json['decoration'], 'underline');
      expect(json['color'], 'yellow');
      expect(json['note'], 'a note');
      expect(json['createdAt'], '2024-06-29T03:21:48.895323Z');
      expect(json['cfi'], 'epubcfi(/6/4!/4/2,/1:0,/1:17)');
    });

    test('omits absent optional highlight and bookmark fields', () {
      final encoded =
          jsonDecode(
                encodeAnnotations(
                  AnnotationCollection(
                    highlights: [highlight(withNote: false, withCfi: false)],
                    bookmarks: [bookmark(withNote: false)],
                  ),
                ),
              )
              as Map<String, dynamic>;
      final highlightJson = (encoded['highlights'] as List<dynamic>).single as Map<String, dynamic>;
      expect(highlightJson.containsKey('note'), isFalse);
      expect(highlightJson.containsKey('cfi'), isFalse);
      final bookmarkJson = (encoded['bookmarks'] as List<dynamic>).single as Map<String, dynamic>;
      expect(bookmarkJson.containsKey('note'), isFalse);
      expect(bookmarkJson['sectionIndex'], 2);
      expect(bookmarkJson['charOffset'], 340);
    });

    test('writes custom colors as a light/dark hex pair', () {
      final encoded =
          jsonDecode(
                encodeAnnotations(
                  AnnotationCollection(
                    highlights: [highlight(color: 'custom')],
                    bookmarks: const [],
                  ),
                ),
              )
              as Map<String, dynamic>;
      final json = (encoded['highlights'] as List<dynamic>).single as Map<String, dynamic>;
      expect(json['color'], {'light': '#12d8ff', 'dark': '#0a5566'});
    });
  });

  group('decodeAnnotations', () {
    test('round-trips a full collection losslessly', () {
      final original = AnnotationCollection(
        highlights: [
          highlight(color: 'custom'),
          highlight(withNote: false, withCfi: false),
        ],
        bookmarks: [bookmark(), bookmark(withNote: false)],
      );
      expect(decodeAnnotations(encodeAnnotations(original)), equals(original));
    });

    test('round-trips every palette token', () {
      for (final token in HighlightPalette.values) {
        final original = AnnotationCollection(
          highlights: [
            HighlightRecord(
              id: 'h',
              sectionIndex: 0,
              start: 0,
              end: 1,
              text: 't',
              before: '',
              after: '',
              color: PaletteHighlightColor(token),
              decoration: HighlightDecoration.background,
              createdAt: DateTime.utc(2024, 1, 1),
            ),
          ],
          bookmarks: const [],
        );
        expect(decodeAnnotations(encodeAnnotations(original)), equals(original));
      }
    });

    test('reads both color wire shapes and all decoration names', () {
      final json = jsonEncode(<String, dynamic>{
        'formatVersion': 1,
        'highlights': <Map<String, dynamic>>[
          for (final decoration in HighlightDecoration.values)
            <String, dynamic>{
              'id': 'h-$decoration',
              'sectionIndex': 0,
              'start': 0,
              'end': 1,
              'text': 't',
              'before': '',
              'after': '',
              'decoration': decoration.name,
              'color': {'light': '#ffcc00', 'dark': '#664400'},
              'createdAt': '2024-01-01T00:00:00Z',
            },
        ],
        'bookmarks': <Map<String, dynamic>>[],
      });
      final decoded = decodeAnnotations(json)!;
      expect(decoded.highlights, hasLength(HighlightDecoration.values.length));
      expect(
        decoded.highlights.map((final h) => h.decoration).toSet(),
        equals(HighlightDecoration.values.toSet()),
      );
      expect(
        decoded.highlights.every((final highlight) {
          return highlight.color == CustomHighlightColor(lightHex: '#ffcc00', darkHex: '#664400');
        }),
        isTrue,
      );
    });

    test('skips invalid entries and keeps the valid ones', () {
      final json = jsonEncode(<String, dynamic>{
        'formatVersion': 1,
        'highlights': [
          'garbage',
          42,
          <String, dynamic>{'id': 'h-no-color', 'sectionIndex': 0, 'start': 0, 'end': 1},
          <String, dynamic>{
            'id': 'h-bad-color',
            'sectionIndex': 0,
            'start': 0,
            'end': 1,
            'text': 't',
            'color': 'mauve',
            'decoration': 'background',
            'createdAt': '2024-01-01T00:00:00Z',
          },
          <String, dynamic>{
            'id': 'h-bad-created',
            'sectionIndex': 0,
            'start': 0,
            'end': 1,
            'text': 't',
            'color': 'green',
            'createdAt': 'not a date',
          },
          <String, dynamic>{
            'id': 'h-file-index-only',
            'fileIndex': 0,
            'start': 0,
            'end': 1,
            'text': 't',
            'color': 'green',
            'createdAt': '2024-01-01T00:00:00Z',
          },
          <String, dynamic>{
            'id': 'h-good',
            'sectionIndex': 1,
            'start': 5,
            'end': 9,
            'text': 'kept',
            'decoration': 'background',
            'color': 'green',
            'createdAt': '2024-01-01T00:00:00Z',
          },
        ],
        'bookmarks': [
          <String, dynamic>{
            'id': 'b-no-position',
            'title': 'lost',
            'createdAt': '2024-01-01T00:00:00Z',
          },
          <String, dynamic>{
            'id': 'b-bad-position',
            'title': 'lost too',
            'sectionIndex': 'x',
            'charOffset': 340,
            'createdAt': '2024-01-01T00:00:00Z',
          },
          <String, dynamic>{
            'id': 'b-good',
            'title': 'kept',
            'sectionIndex': 0,
            'charOffset': 7,
            'createdAt': '2024-01-01T00:00:00Z',
          },
        ],
      });
      final decoded = decodeAnnotations(json)!;
      expect(decoded.highlights.map((final h) => h.id), ['h-good']);
      expect(decoded.bookmarks.map((final b) => b.id), ['b-good']);
    });

    test('rejects custom colors outside the canonical #rrggbb shape', () {
      final json = jsonEncode(<String, dynamic>{
        'formatVersion': 1,
        'highlights': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'h-no-hash',
            'sectionIndex': 0,
            'start': 0,
            'end': 1,
            'text': 't',
            'decoration': 'background',
            'color': {'light': 'ffcc00', 'dark': '#664400'},
            'createdAt': '2024-01-01T00:00:00Z',
          },
        ],
        'bookmarks': <Map<String, dynamic>>[],
      });

      expect(decodeAnnotations(json)!.highlights, isEmpty);
    });

    test('prevents constructing custom colors that cannot round-trip', () {
      expect(
        () => CustomHighlightColor(lightHex: '12d8ff', darkHex: '#0a5566'),
        throwsArgumentError,
      );
      expect(
        () => CustomHighlightColor(lightHex: '#12d8ff', darkHex: '#0a556'),
        throwsArgumentError,
      );
    });

    test('rejects invalid positions at construction and decode boundaries', () {
      expect(
        () => HighlightRecord(
          id: 'invalid',
          sectionIndex: -1,
          start: 20,
          end: 10,
          text: 'invalid',
          before: '',
          after: '',
          color: PaletteHighlightColor.yellow,
          createdAt: DateTime.utc(2024),
        ),
        throwsArgumentError,
      );
      expect(
        () => BookmarkRecord(
          id: 'invalid',
          title: 'invalid',
          sectionIndex: 0,
          charOffset: -1,
          createdAt: DateTime.utc(2024),
        ),
        throwsArgumentError,
      );

      final decoded = decodeAnnotations(
        jsonEncode(<String, Object?>{
          'formatVersion': 1,
          'highlights': [
            <String, Object?>{
              'id': 'invalid',
              'sectionIndex': -1,
              'start': 20,
              'end': 10,
              'text': 'invalid',
              'decoration': 'background',
              'color': 'yellow',
              'createdAt': '2024-01-01T00:00:00Z',
            },
          ],
          'bookmarks': [
            <String, Object?>{
              'id': 'invalid',
              'title': 'invalid',
              'sectionIndex': 0,
              'charOffset': -1,
              'createdAt': '2024-01-01T00:00:00Z',
            },
          ],
        }),
      );

      expect(decoded!.highlights, isEmpty);
      expect(decoded.bookmarks, isEmpty);
    });

    test('returns null for a non-map or undecodable envelope', () {
      expect(decodeAnnotations('not json at all'), isNull);
      expect(decodeAnnotations('[1, 2, 3]'), isNull);
      expect(decodeAnnotations('"just a string"'), isNull);
      expect(decodeAnnotations('42'), isNull);
    });

    test('returns null for an unknown or missing formatVersion', () {
      expect(decodeAnnotations('{"formatVersion": 2, "highlights": [], "bookmarks": []}'), isNull);
      expect(decodeAnnotations('{"highlights": [], "bookmarks": []}'), isNull);
    });

    test('defaults missing collections to empty', () {
      final decoded = decodeAnnotations('{"formatVersion": 1}');
      expect(decoded, equals(const AnnotationCollection(highlights: [], bookmarks: [])));
    });
  });
}
