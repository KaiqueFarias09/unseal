import 'dart:convert';

import 'package:e_livre/src/features/annotations/annotation_codec.dart';
import 'package:e_livre/src/features/annotations/bookmark_record.dart';
import 'package:e_livre/src/features/annotations/highlight_record.dart';
import 'package:test/test.dart';

HighlightRecord highlight({
  final String color = 'yellow',
  final bool withNote = true,
  final bool withCfi = true,
}) => HighlightRecord(
  id: 'h1',
  sectionIndex: 3,
  start: 120,
  end: 180,
  text: 'highlighted words',
  before: 'context before ',
  after: ' context after',
  color: color == 'yellow'
      ? PaletteHighlightColor.yellow
      : const CustomHighlightColor(lightHex: '#12d8ff', darkHex: '#0a5566'),
  decoration: HighlightDecoration.underline,
  note: withNote ? 'a note' : null,
  createdAt: DateTime.utc(2024, 6, 29, 3, 21, 48).add(const Duration(microseconds: 895323)),
  cfi: withCfi ? 'epubcfi(/6/4!/4/2,/1:0,/1:17)' : null,
);

BookmarkRecord bookmark({final bool withNote = true}) => BookmarkRecord(
  id: 'b1',
  title: 'Chapter two',
  sectionIndex: 2,
  charOffset: 340,
  createdAt: DateTime.utc(2024, 7, 1, 10, 0, 0),
  note: withNote ? 'reread here' : null,
);

void main() {
  group('encodeAnnotations', () {
    test('writes the versioned envelope with both collections', () {
      final encoded =
          jsonDecode(encodeAnnotations(const AnnotationCollection(highlights: [], bookmarks: [])))
              as Map<String, dynamic>;
      expect(encoded['formatVersion'], 1);
      expect(encoded['highlights'], isEmpty);
      expect(encoded['bookmarks'], isEmpty);
    });

    test('writes the viewer field vocabulary with sectionIndex', () {
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

    test('writes an absent highlight note as null, omits cfi and bookmark note', () {
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
      expect(highlightJson['note'], isNull);
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
              'decoration': decoration.wireName,
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
        decoded.highlights.every(
          (final h) =>
              h.color == const CustomHighlightColor(lightHex: '#ffcc00', darkHex: '#664400'),
        ),
        isTrue,
      );
    });

    test('accepts the viewer position string for bookmarks', () {
      final json = jsonEncode(<String, dynamic>{
        'formatVersion': 1,
        'highlights': <Map<String, dynamic>>[],
        'bookmarks': <Map<String, dynamic>>[
          {
            'id': 'b1',
            'title': 'Marked',
            'position': 'eLv1:2:340',
            'createdAt': '2024-07-01T10:00:00Z',
          },
        ],
      });
      expect(
        decodeAnnotations(json),
        equals(
          AnnotationCollection(
            highlights: const [],
            bookmarks: [
              BookmarkRecord(
                id: 'b1',
                title: 'Marked',
                sectionIndex: 2,
                charOffset: 340,
                createdAt: DateTime.utc(2024, 7, 1, 10),
              ),
            ],
          ),
        ),
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
            'position': 'eLv1:x:340',
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
