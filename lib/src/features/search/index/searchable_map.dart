/// A string-keyed radix tree (compressed prefix tree) — the Dart port
/// of MiniSearch's `SearchableMap`
/// ([revision `3d239d1c`](https://github.com/lucaong/minisearch/tree/3d239d1c3ae7aef1bf5d8945dd7b5f0709f646f5),
/// MIT — see `THIRD_PARTY_NOTICES.md`), reduced to what the search
/// index needs: exact lookup, prefix iteration, and bounded fuzzy
/// iteration.
///
/// Nodes are plain maps; a term's value sits under a private sentinel
/// key, so terms can never collide with it. Child iteration follows
/// insertion order like the JavaScript `Map` the original relies on,
/// keeping traversal deterministic for a fixed insert order.
///
/// Prefix iteration yields *full* terms. The port's query weighting
/// derives from the full term (documented in `index_ranking.dart`),
/// unlike the original, which weights relative view keys; the exact
/// term under a prefix query is skipped instead of passing through the
/// original's negative-distance quirk (which scores it at `-0`, a
/// no-op).
library;

/// Sentinel key holding a node's leaf value.
final Object _leaf = Object();

/// Radix tree over [T] values with prefix and fuzzy iteration.
final class SearchableMap<T> {
  final Map<Object?, Object?> _tree = <Object?, Object?>{};

  /// Stored values, in insertion order (depth-first).
  Iterable<T> get values sync* {
    yield* _valuesOf(_tree);
  }

  Iterable<T> _valuesOf(final Map<Object?, Object?> node) sync* {
    final leaf = node[_leaf];
    if (leaf is T) yield leaf;
    for (final entry in node.entries) {
      if (identical(entry.key, _leaf)) continue;
      final child = entry.value;
      if (child is Map<Object?, Object?>) yield* _valuesOf(child);
    }
  }

  /// The value stored at [key], or null.
  T? get(final String key) {
    final node = _lookup(_tree, key);

    return node?[_leaf] as T?;
  }

  /// Whether [key] is present.
  bool containsKey(final String key) => _lookup(_tree, key)?.containsKey(_leaf) ?? false;

  /// Stores [value] at [key], creating the compressed path on demand.
  void set(final String key, final T value) {
    _createPath(_tree, key)[_leaf] = value;
  }

  /// Every `(term, value)` whose term starts with [prefix], walking
  /// only the matching subtree. Terms come out in traversal order.
  Iterable<(String, T)> entriesAtPrefix(final String prefix) sync* {
    yield* _entriesUnder(_tree, prefix, '');
  }

  Iterable<(String, T)> _entriesUnder(
    final Map<Object?, Object?> node,
    final String remaining,
    final String base,
  ) sync* {
    if (remaining.isEmpty) {
      yield* _wholeSubtree(node, base);

      return;
    }
    for (final entry in node.entries) {
      if (identical(entry.key, _leaf)) continue;
      final edge = entry.key as String;
      final child = entry.value as Map<Object?, Object?>;
      if (remaining.startsWith(edge)) {
        yield* _entriesUnder(child, remaining.substring(edge.length), base + edge);
      } else if (edge.startsWith(remaining)) {
        // The prefix cuts this edge: the whole child subtree shares the
        // prefix, so yield it in one pass.
        yield* _wholeSubtree(child, base + edge);
      }
    }
  }

  Iterable<(String, T)> _wholeSubtree(final Map<Object?, Object?> node, final String base) sync* {
    final leaf = node[_leaf];
    if (leaf is T) yield (base, leaf);
    for (final entry in node.entries) {
      if (identical(entry.key, _leaf)) continue;
      final edge = entry.key as String;
      yield* _wholeSubtree(entry.value as Map<Object?, Object?>, base + edge);
    }
  }

  /// Every `(term, value, distance)` within [maxDistance] Levenshtein
  /// edits of [query], walking only the branches that can still land
  /// inside the distance — the shared incremental matrix traversal of
  /// MiniSearch's `fuzzySearch`
  /// ([stevehanov's trie walk](http://stevehanov.me/blog/?id=114)),
  /// updated in place across nodes. The original relied on typed-array
  /// out-of-bounds writes vanishing; this port prunes explicitly at the
  /// row budget, which the distance bound makes semantically exact.
  Iterable<(String, T, int)> fuzzyEntries(final String query, final int maxDistance) sync* {
    final columns = query.length + 1;
    // Matching terms can never be longer than the query plus the
    // distance budget.
    final rows = columns + maxDistance;
    final matrix = List<int>.filled(rows * columns, maxDistance + 1);
    for (var j = 0; j < columns; j++) {
      matrix[j] = j;
    }
    for (var i = 1; i < rows; i++) {
      matrix[i * columns] = i;
    }
    yield* _fuzzyWalk(_tree, query, maxDistance, matrix, 1, columns, rows, '');
  }

  Iterable<(String, T, int)> _fuzzyWalk(
    final Map<Object?, Object?> node,
    final String query,
    final int maxDistance,
    final List<int> matrix,
    final int nextRow,
    final int columns,
    final int rows,
    final String base,
  ) sync* {
    walk:
    for (final entry in node.entries) {
      if (identical(entry.key, _leaf)) {
        final distance = matrix[nextRow * columns - 1];
        if (distance <= maxDistance) {
          yield (base, entry.value as T, distance);
        }

        continue;
      }
      final edge = entry.key as String;
      // A term this long is already further than the budget allows.
      if (nextRow + edge.length > rows) continue;
      var row = nextRow;
      for (var pos = 0; pos < edge.length; pos++, row++) {
        final char = edge.codeUnitAt(pos);
        final thisRow = row * columns;
        final prevRow = thisRow - columns;
        var minDistance = matrix[thisRow];
        final jMin = row - maxDistance - 1 < 0 ? 0 : row - maxDistance - 1;
        final jMax = row + maxDistance < columns - 1 ? row + maxDistance : columns - 1;
        for (var j = jMin; j < jMax; j++) {
          final different = char != query.codeUnitAt(j) ? 1 : 0;
          final replace = matrix[prevRow + j] + different;
          final remove = matrix[prevRow + j + 1] + 1;
          final insert = matrix[thisRow + j] + 1;
          var best = replace;
          if (remove < best) best = remove;
          if (insert < best) best = insert;
          matrix[thisRow + j + 1] = best;
          if (best < minDistance) minDistance = best;
        }

        // Distance never decreases down a branch: prune the subtree.
        if (minDistance > maxDistance) continue walk;
      }
      yield* _fuzzyWalk(
        entry.value as Map<Object?, Object?>,
        query,
        maxDistance,
        matrix,
        row,
        columns,
        rows,
        base + edge,
      );
    }
  }
}

/// The node at the end of [key], creating intermediate nodes and
/// splitting compressed edges — the `createPath` hot path of the
/// original, iterative to avoid recursion on long terms.
Map<Object?, Object?> _createPath(final Map<Object?, Object?> node, final String key) {
  var current = node;
  var pos = 0;
  outer:
  while (pos < key.length) {
    for (final entry in current.entries.toList()) {
      final edge = entry.key;
      if (identical(edge, _leaf)) continue;
      final edgeText = edge as String;
      if (key.codeUnitAt(pos) == edgeText.codeUnitAt(0)) {
        final common = _commonPrefixLength(key, pos, edgeText);
        final child = entry.value as Map<Object?, Object?>;
        if (common == edgeText.length) {
          // Full edge consumed; descend.
          current = child;
        } else {
          // Split the edge at the divergence point: the head keeps the
          // matched prefix of the EDGE (not of the key), the tail moves
          // under the intermediate node.
          final middle = <Object?, Object?>{edgeText.substring(common): child};
          current[edgeText.substring(0, common)] = middle;
          current.remove(edge);
          current = middle;
        }
        pos += common;

        continue outer;
      }
    }

    final child = <Object?, Object?>{};
    current[key.substring(pos)] = child;

    return child;
  }

  return current;
}

int _commonPrefixLength(final String key, final int pos, final String edge) {
  final max = key.length - pos < edge.length ? key.length - pos : edge.length;
  var length = 1;
  while (length < max && key.codeUnitAt(pos + length) == edge.codeUnitAt(length)) {
    length++;
  }

  return length;
}

Map<Object?, Object?>? _lookup(final Map<Object?, Object?> node, final String key) {
  var current = node;
  var pos = 0;
  while (pos < key.length) {
    Map<Object?, Object?>? next;
    for (final entry in current.entries) {
      if (identical(entry.key, _leaf)) continue;
      final edge = entry.key as String;
      if (key.startsWith(edge, pos)) {
        next = entry.value as Map<Object?, Object?>;
        pos += edge.length;

        break;
      }
    }
    if (next == null) return null;
    current = next;
  }

  return current;
}
