import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

/// Returns the fixed UTC timestamp used by the merge fixtures; [year] is added to 2000.
DateTime goldenTime(final int year) {
  return DateTime.utc(2000 + year, 6, 29, 3, 21, 48).add(const Duration(microseconds: 895323));
}

/// Builds a highlight whose group key is [id] and whose reading
/// position is section 0 at offset [offset].
HighlightRecord highlight({
  required final String id,
  required final int year,
  required final int offset,
  final String? note,
}) {
  return HighlightRecord(
    id: id,
    sectionIndex: 0,
    start: offset,
    end: offset + 1,
    text: 'text $id',
    before: '',
    after: '',
    color: PaletteHighlightColor.yellow,
    createdAt: goldenTime(year),
    note: note,
  );
}

/// Builds a bookmark whose merge identity is [title] and whose
/// reading position is section 0 at offset [offset].
BookmarkRecord bookmark({
  required final String title,
  required final int year,
  required final int offset,
  final int section = 0,
  final String? note,
}) {
  return BookmarkRecord(
    id: 'bm-$title',
    title: title,
    sectionIndex: section,
    charOffset: offset,
    createdAt: goldenTime(year),
    note: note,
  );
}

void main() {
  group('mergeHighlights (golden case)', () {
    // The fixture uses HighlightRecord.id as its group key. Newer records replace older ones, and
    // survivors are ordered by reading position as ['one', 'two', 'b', 'a'].
    final local = [
      highlight(id: 'one', year: 20, offset: 2),
      highlight(id: 'two', year: 20, offset: 4),
      highlight(id: 'a', year: 20, offset: 16),
    ];
    final incoming = [
      highlight(id: 'one', year: 30, offset: 2),
      highlight(id: 'two', year: 10, offset: 4),
      highlight(id: 'b', year: 20, offset: 8),
    ];

    test('newest wins per group and survivors re-sort by position', () {
      final (:changed, highlights: merged) = mergeHighlights(local, incoming);

      expect(changed, isTrue);
      // one: incoming is newer (2030 > 2020); two: local is newer
      // (2020 > 2010); b (offset 8) and a (offset 16) sort by
      // position, so the incoming copy of 'one' (offset 2), 'two'
      // (offset 4), 'b' then 'a'.
      expect(merged.map((final h) => h.id).toList(), ['one', 'two', 'b', 'a']);
    });

    test('the surviving copies are the newest of each side', () {
      final localCopy = [
        highlight(id: 'one', year: 20, offset: 2, note: 'local'),
        highlight(id: 'two', year: 20, offset: 4, note: 'local'),
      ];
      final incomingCopy = [
        highlight(id: 'one', year: 30, offset: 2, note: 'incoming'),
        highlight(id: 'two', year: 10, offset: 4, note: 'incoming'),
      ];
      final (changed: _, highlights: merged) = mergeHighlights(localCopy, incomingCopy);

      expect(merged.map((final h) => h.note).toList(), ['incoming', 'local']);
    });
  });

  group('mergeBookmarks (golden case)', () {
    // Same fixture matched on title, with positions mirroring the
    // golden CFI numbers so both identity lookups agree.
    final local = [
      bookmark(title: 'one', year: 20, offset: 2),
      bookmark(title: 'two', year: 20, offset: 4),
      bookmark(title: 'a', year: 20, offset: 16),
    ];
    final incoming = [
      bookmark(title: 'one', year: 30, offset: 2),
      bookmark(title: 'two', year: 10, offset: 4),
      bookmark(title: 'b', year: 20, offset: 8),
    ];

    test('matches the highlight golden order', () {
      final (:changed, bookmarks: merged) = mergeBookmarks(local, incoming);

      expect(changed, isTrue);
      expect(merged.map((final b) => b.title).toList(), ['one', 'two', 'b', 'a']);
    });
  });

  group('mergeHighlights', () {
    test('identical lists merge to no change, keeping the local copies', () {
      final local = [
        highlight(id: 'one', year: 20, offset: 2, note: 'local'),
        highlight(id: 'b', year: 20, offset: 8, note: 'local'),
      ];
      final incoming = [
        highlight(id: 'one', year: 20, offset: 2),
        highlight(id: 'b', year: 20, offset: 8),
      ];

      final (:changed, highlights: merged) = mergeHighlights(local, incoming);

      expect(changed, isFalse);
      expect(merged.map((final h) => h.id).toList(), ['one', 'b']);
      expect(identical(merged[0], local[0]), isTrue);
      expect(identical(merged[1], local[1]), isTrue);
    });

    test('ties keep the local copy without flagging a change', () {
      final local = [highlight(id: 'one', year: 20, offset: 2, note: 'local')];
      final incoming = [highlight(id: 'one', year: 20, offset: 2, note: 'incoming')];

      final (:changed, highlights: merged) = mergeHighlights(local, incoming);

      expect(changed, isFalse);
      expect(merged.single.note, 'local');
    });

    test('differing timestamps flag a change even when the local copy survives', () {
      final local = [highlight(id: 'one', year: 30, offset: 2)];
      final incoming = [highlight(id: 'one', year: 10, offset: 2)];

      final (:changed, highlights: merged) = mergeHighlights(local, incoming);

      expect(changed, isTrue);
      expect(merged.single, equals(local.single));
    });

    test('an added id flags a change and appends the survivor', () {
      final local = [highlight(id: 'one', year: 20, offset: 2)];
      final incoming = [
        highlight(id: 'one', year: 20, offset: 2),
        highlight(id: 'new', year: 20, offset: 40),
      ];

      final (:changed, highlights: merged) = mergeHighlights(local, incoming);

      expect(changed, isTrue);
      expect(merged.map((final h) => h.id).toList(), ['one', 'new']);
    });

    test('re-sorts survivors by section then offset', () {
      HighlightRecord at({
        required final String id,
        required final int section,
        required final int offset,
      }) {
        return HighlightRecord(
          id: id,
          sectionIndex: section,
          start: offset,
          end: offset + 1,
          text: 'text $id',
          before: '',
          after: '',
          color: PaletteHighlightColor.yellow,
          createdAt: goldenTime(20),
        );
      }

      final local = [
        at(id: 'late', section: 0, offset: 5),
        at(id: 'other-section', section: 1, offset: 1),
      ];
      final incoming = [at(id: 'early', section: 0, offset: 30)];

      final (:changed, highlights: merged) = mergeHighlights(local, incoming);

      expect(changed, isTrue);
      expect(merged.map((final h) => h.id).toList(), ['late', 'early', 'other-section']);
    });

    test('empty inputs merge to no change', () {
      final (:changed, highlights: merged) = mergeHighlights(const [], const []);
      expect(changed, isFalse);
      expect(merged, isEmpty);
      final (changed: addedChanged, highlights: added) = mergeHighlights(const [], [
        highlight(id: 'one', year: 20, offset: 2),
      ]);
      expect(addedChanged, isTrue);
      expect(added, hasLength(1));
    });
  });

  group('mergeBookmarks', () {
    test('matches by title across different positions', () {
      final local = [bookmark(title: 'same', year: 20, offset: 1, note: 'local')];
      final incoming = [bookmark(title: 'same', year: 30, offset: 500, note: 'incoming')];

      final (:changed, bookmarks: merged) = mergeBookmarks(local, incoming);

      expect(changed, isTrue);
      expect(merged.single.note, 'incoming');
      expect(merged.single.charOffset, 500);
    });

    test('matches by position across different titles', () {
      final local = [bookmark(title: 'old title', year: 20, offset: 7)];
      final incoming = [bookmark(title: 'renamed', year: 30, offset: 7)];

      final (:changed, bookmarks: merged) = mergeBookmarks(local, incoming);

      expect(changed, isTrue);
      expect(merged.single.title, 'renamed');
    });

    test('the earliest matching index wins when both lookups hit', () {
      final first = bookmark(title: 'shared', year: 20, offset: 100);
      final second = bookmark(title: 'other', year: 20, offset: 200);
      final incoming = bookmark(title: 'shared', year: 30, offset: 200);

      final (:changed, bookmarks: merged) = mergeBookmarks([first, second], [incoming]);

      expect(changed, isTrue);
      expect(merged, hasLength(2));
      expect(merged[0].title, 'shared');
      expect(merged[0].createdAt.year, 2030);
      expect(identical(merged[1], second), isTrue);
    });

    test('an older incoming never displaces the local copy', () {
      final local = [bookmark(title: 'kept', year: 30, offset: 1)];
      final incoming = [bookmark(title: 'kept', year: 10, offset: 1)];

      final (:changed, bookmarks: merged) = mergeBookmarks(local, incoming);

      expect(changed, isTrue);
      expect(identical(merged.single, local.single), isTrue);
    });

    test('local-only and incoming-only survivors both survive, position-sorted', () {
      final local = [bookmark(title: 'local-only', year: 20, offset: 10)];
      final incoming = [
        bookmark(title: 'far', year: 20, offset: 5, section: 1),
        bookmark(title: 'incoming-only', year: 20, offset: 20),
      ];

      final (:changed, bookmarks: merged) = mergeBookmarks(local, incoming);

      expect(changed, isTrue);
      expect(merged.map((final b) => b.title).toList(), ['local-only', 'incoming-only', 'far']);
    });

    test('empty inputs merge to no change', () {
      final (:changed, bookmarks: merged) = mergeBookmarks(const [], const []);
      expect(changed, isFalse);
      expect(merged, isEmpty);
    });
  });
}
