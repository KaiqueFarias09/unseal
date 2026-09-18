import 'annotation_merge_engine.dart';
import 'bookmark_record.dart';

final AnnotationMergeEngine<BookmarkRecord> _bookmarkMergeEngine = AnnotationMergeEngine(
  keysOf: (final bookmark) {
    return [('title', bookmark.title), ('position', bookmark.sectionIndex, bookmark.charOffset)];
  },
  timestampOf: (final bookmark) => bookmark.createdAt,
  positionOf: (final bookmark) => (bookmark.sectionIndex, bookmark.charOffset),
);

/// Merges [local] and [incoming] bookmarks: a local and an incoming bookmark match when their
/// bookmark titles match OR their position (sectionIndex, charOffset) matches — the
/// earliest matching index winning when both lookups hit. Within a group the most recently
/// timestamped copy wins and ties keep the local copy; the survivors are returned in reading
/// position order, with the `changed` flag following the same rules as `mergeHighlights`.
///
/// Matching on title or position lets bookmarks survive changes to one of those fields during
/// import.
({bool changed, List<BookmarkRecord> bookmarks}) mergeBookmarks(
  final List<BookmarkRecord> local,
  final List<BookmarkRecord> incoming,
) {
  final (:changed, :survivors) = _bookmarkMergeEngine.merge(local: local, incoming: incoming);

  return (changed: changed, bookmarks: survivors);
}
