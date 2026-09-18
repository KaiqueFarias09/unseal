/// The shared reconciliation engine used by highlight and bookmark merges.
///
/// The concrete merge functions remain in their own owner files so callers can
/// understand which annotation type they are reconciling. This engine contains
/// only the type-independent grouping, winner selection, and ordering rules.
final class AnnotationMergeEngine<T> {
  /// Creates an engine for one annotation type.
  const AnnotationMergeEngine({
    required this.keysOf,
    required this.timestampOf,
    required this.positionOf,
  });

  /// Returns every identity key answered by `record`.
  final List<Object> Function(T record) keysOf;

  /// Returns the timestamp used to choose the winning candidate.
  final DateTime Function(T record) timestampOf;

  /// Returns the reading position used to order surviving records.
  final (int, int) Function(T record) positionOf;

  /// Reconciles [local] and [incoming] records.
  ///
  /// Records with equal timestamps retain the local copy. When reconciliation
  /// changes the result, survivors are sorted by reading position.
  ({bool changed, List<T> survivors}) merge({
    required final List<T> local,
    required final List<T> incoming,
  }) {
    final groups = <List<_MergeCandidate<T>>>[];
    final groupByKey = <Object, int>{};
    var appearanceIndex = 0;
    for (final record in local) {
      appearanceIndex = _admit(
        record: record,
        groups: groups,
        groupByKey: groupByKey,
        appearanceIndex: appearanceIndex,
      );
    }
    for (final record in incoming) {
      appearanceIndex = _admit(
        record: record,
        groups: groups,
        groupByKey: groupByKey,
        appearanceIndex: appearanceIndex,
      );
    }

    var changed = false;
    final winners = <_MergeCandidate<T>>[];
    for (final group in groups) {
      // Newest timestamps win; the appearance index keeps ties on the local
      // copy because local records are admitted first.
      group.sort((final left, final right) {
        final byTimestamp = timestampOf(right.record).compareTo(timestampOf(left.record));
        if (byTimestamp != 0) return byTimestamp;

        return left.appearance.compareTo(right.appearance);
      });

      // A timestamp conflict means reconciliation changed the result, even
      // when the local candidate remains the winner.
      if (!changed &&
          group.length > 1 &&
          timestampOf(group[0].record) != timestampOf(group[1].record)) {
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

    // Order survivors by reading position; the explicit winner index keeps
    // ties in their pre-sort order.
    final rankedWinners = [for (var i = 0; i < winners.length; i++) (winners[i], i)];
    rankedWinners.sort((final left, final right) {
      final (leftCandidate, leftIndex) = left;
      final (rightCandidate, rightIndex) = right;
      final (leftSection, leftOffset) = positionOf(leftCandidate.record);
      final (rightSection, rightOffset) = positionOf(rightCandidate.record);
      final bySection = leftSection.compareTo(rightSection);
      if (bySection != 0) return bySection;

      final byOffset = leftOffset.compareTo(rightOffset);
      if (byOffset != 0) return byOffset;

      return leftIndex.compareTo(rightIndex);
    });

    return (
      changed: true,
      survivors: [for (final (candidate, _) in rankedWinners) candidate.record],
    );
  }

  int _admit({
    required final T record,
    required final List<List<_MergeCandidate<T>>> groups,
    required final Map<Object, int> groupByKey,
    required final int appearanceIndex,
  }) {
    final keys = keysOf(record);
    var targetGroupIndex = -1;
    for (final key in keys) {
      final existingGroupIndex = groupByKey[key];
      if (existingGroupIndex != null &&
          (targetGroupIndex < 0 || existingGroupIndex < targetGroupIndex)) {
        targetGroupIndex = existingGroupIndex;
      }
    }

    final candidate = _MergeCandidate(record, appearanceIndex);
    if (targetGroupIndex < 0) {
      targetGroupIndex = groups.length;
      groups.add(<_MergeCandidate<T>>[]);
      for (final key in keys) {
        groupByKey.putIfAbsent(key, () => targetGroupIndex);
      }
    }

    groups[targetGroupIndex].add(candidate);

    return appearanceIndex + 1;
  }
}

/// One merge candidate: the record plus its appearance index, which breaks
/// timestamp ties in favor of the earlier (local) copy.
final class _MergeCandidate<T> {
  const _MergeCandidate(this.record, this.appearance);

  final T record;

  final int appearance;
}
