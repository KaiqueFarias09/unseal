import 'annotation_merge_engine.dart';
import 'entities/highlight_record.dart';

final AnnotationMergeEngine<HighlightRecord> _highlightMergeEngine = AnnotationMergeEngine(
  keysOf: (final highlight) => [('id', highlight.id)],
  timestampOf: (final highlight) => highlight.createdAt,
  positionOf: (final highlight) => (highlight.sectionIndex, highlight.start),
);

/// Merges [local] and [incoming] highlights: per [HighlightRecord.id], the most recently
/// timestamped copy wins and ties keep the local copy; the survivors are returned in reading
/// position order.
///
/// Records with equal timestamps retain their local copy. `changed` is true when the winning
/// candidate's timestamp differs from the runner-up's, or when the survivor count differs from
/// either input length.
({bool changed, List<HighlightRecord> highlights}) mergeHighlights(
  final List<HighlightRecord> local,
  final List<HighlightRecord> incoming,
) {
  final (:changed, :survivors) = _highlightMergeEngine.merge(local: local, incoming: incoming);

  return (changed: changed, highlights: survivors);
}
