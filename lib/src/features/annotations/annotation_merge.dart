import 'bookmark_record.dart';
import 'highlight_record.dart';

/// Merges [local] and [incoming] highlights: per
/// [HighlightRecord.id], the most recently timestamped copy wins and
/// ties keep the local copy; the survivors are returned in reading
/// position order.
///
/// `changed` mirrors the reference semantics: true when any group's
/// candidates carried differing timestamps (even if the local copy
/// survived), or when the survivor count differs from either input
/// length.
///
/// Parity: calibre src/pyj/read_book/annotations.pyj:46-108
/// (merge_annots_with_identical_field / merge_annotation_maps), with
/// the golden case from src/pyj/test_annotations.pyj.
({bool changed, List<HighlightRecord> highlights}) mergeHighlights(
  final List<HighlightRecord> local,
  final List<HighlightRecord> incoming,
) {
  final (:changed, :survivors) = _mergeGroups(
    local: local,
    incoming: incoming,
    adapter: _highlightAdapter,
  );
  return (changed: changed, highlights: survivors);
}

/// Merges [local] and [incoming] bookmarks: a local and an incoming
/// bookmark match when their [BookmarkRecord.title] matches OR their
/// position (sectionIndex, charOffset) matches — the earliest
/// matching index winning when both lookups hit. Within a group the
/// most recently timestamped copy wins and ties keep the local copy;
/// the survivors are returned in reading position order, with the
/// `changed` flag following [mergeHighlights].
///
/// Parity: calibre src/pyj/read_book/annotations.pyj:46-108
/// (merge_annots_with_identical_field / merge_annotation_maps), with
/// bookmarks matched on title-or-position like the companion
/// viewer's import.
({bool changed, List<BookmarkRecord> bookmarks}) mergeBookmarks(
  final List<BookmarkRecord> local,
  final List<BookmarkRecord> incoming,
) {
  final (:changed, :survivors) = _mergeGroups(
    local: local,
    incoming: incoming,
    adapter: _bookmarkAdapter,
  );
  return (changed: changed, bookmarks: survivors);
}

/// The per-type merge vocabulary: the lookup keys a record is
/// matched by, its timestamp and its reading-position sort key.
final class _MergeAdapter<T> {
  const _MergeAdapter({required this.keysOf, required this.timestampOf, required this.positionOf});

  /// Every key the record answers to: one for highlights, title and
  /// position for bookmarks.
  final List<Object> Function(T record) keysOf;

  /// The merge ordering timestamp.
  final DateTime Function(T record) timestampOf;

  /// The reading position: section index and in-section offset.
  final (int, int) Function(T record) positionOf;
}

/// One merge candidate: the record plus its appearance index, which
/// breaks timestamp ties in favor of the earlier (local) copy.
final class _Candidate<T> {
  const _Candidate(this.record, this.appearance);

  final T record;

  final int appearance;
}

final _MergeAdapter<HighlightRecord> _highlightAdapter = _MergeAdapter(
  keysOf: (final highlight) => [('id', highlight.id)],
  timestampOf: (final highlight) => highlight.createdAt,
  positionOf: (final highlight) => (highlight.sectionIndex, highlight.start),
);

final _MergeAdapter<BookmarkRecord> _bookmarkAdapter = _MergeAdapter(
  keysOf: (final bookmark) => [
    ('title', bookmark.title),
    ('position', bookmark.sectionIndex, bookmark.charOffset),
  ],
  timestampOf: (final bookmark) => bookmark.createdAt,
  positionOf: (final bookmark) => (bookmark.sectionIndex, bookmark.charOffset),
);

/// Groups [local] then [incoming] by shared lookup keys — each record
/// joins the earliest group claiming one of its keys (the earliest
/// index wins on both bookmark lookups), or starts a new group
/// claiming all of its keys — keeps the newest candidate per group
/// with ties going to the earlier candidate, then re-sorts the
/// survivors by reading position.
({bool changed, List<T> survivors}) _mergeGroups<T>({
  required final List<T> local,
  required final List<T> incoming,
  required final _MergeAdapter<T> adapter,
}) {
  final groups = <List<_Candidate<T>>>[];
  final groupByKey = <Object, int>{};
  var appearance = 0;
  void admit(final T record) {
    final keys = adapter.keysOf(record);
    var target = -1;
    for (final key in keys) {
      final at = groupByKey[key];
      if (at != null && (target < 0 || at < target)) {
        target = at;
      }
    }
    final candidate = _Candidate(record, appearance++);
    if (target < 0) {
      target = groups.length;
      groups.add(<_Candidate<T>>[]);
      for (final key in keys) {
        groupByKey.putIfAbsent(key, () => target);
      }
    }
    groups[target].add(candidate);
  }

  for (final record in local) {
    admit(record);
  }
  for (final record in incoming) {
    admit(record);
  }

  var changed = false;
  final winners = <_Candidate<T>>[];
  for (final group in groups) {
    // Parity: annotations.pyj annots_descending_cmp — newest
    // timestamp first; the appearance index keeps ties on the local
    // copy.
    group.sort((final x, final y) {
      final byTimestamp = adapter.timestampOf(y.record).compareTo(adapter.timestampOf(x.record));
      if (byTimestamp != 0) {
        return byTimestamp;
      }
      return x.appearance.compareTo(y.appearance);
    });
    // Parity: annotations.pyj — changed once a group's top two
    // candidates carry differing timestamps.
    if (!changed &&
        group.length > 1 &&
        adapter.timestampOf(group[0].record) != adapter.timestampOf(group[1].record)) {
      changed = true;
    }
    winners.add(group[0]);
  }
  if (winners.length != local.length || winners.length != incoming.length) {
    changed = true;
  }
  if (!changed) {
    return (changed: false, survivors: [for (final candidate in winners) candidate.record]);
  }
  // Parity: annotations.pyj sort_annot_list — order survivors by
  // reading position; ties keep the pre-sort winner order (Calibre's
  // list sort is stable).
  final ranked = [for (var i = 0; i < winners.length; i++) (winners[i], i)];
  ranked.sort((final x, final y) {
    final (xCandidate, xIndex) = x;
    final (yCandidate, yIndex) = y;
    final (xSection, xOffset) = adapter.positionOf(xCandidate.record);
    final (ySection, yOffset) = adapter.positionOf(yCandidate.record);
    final bySection = xSection.compareTo(ySection);
    if (bySection != 0) {
      return bySection;
    }
    final byOffset = xOffset.compareTo(yOffset);
    if (byOffset != 0) {
      return byOffset;
    }
    return xIndex.compareTo(yIndex);
  });
  return (changed: true, survivors: [for (final (candidate, _) in ranked) candidate.record]);
}
