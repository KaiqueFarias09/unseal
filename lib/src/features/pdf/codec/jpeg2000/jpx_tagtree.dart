import 'jpx_bitreader.dart';
import 'jpx_exception.dart';

/// Unknown node value before any threshold reaches it (OpenJPEG
/// initializes nodes to 999).
const int _kUnknown = 999;

/// Tag tree over a leaf rectangle (15444-1 Annex B.10.3), following
/// OpenJPEG's `tgt.c`: nodes are laid out by level, each node links to
/// a parent, and decoding walks from a leaf to the root reading one
/// bit per threshold increment.
final class JpxTagTree {
  /// Builds the tree for a `leafCountX` x `leafCountY` rectangle.
  /// Counts must already be bounded (they derive from code-block grid
  /// geometry that the caller validates).
  JpxTagTree(this._leafCountX, this._leafCountY) {
    final levelWidths = <int>[_leafCountX];
    final levelHeights = <int>[_leafCountY];
    var totalNodes = 0;
    while (true) {
      final nodesAtLevel = levelWidths.last * levelHeights.last;
      totalNodes += nodesAtLevel;
      if (nodesAtLevel <= 1) {
        break;
      }
      levelWidths.add((levelWidths.last + 1) >> 1);
      levelHeights.add((levelHeights.last + 1) >> 1);
    }
    _low = List<int>.filled(totalNodes, 0);
    _value = List<int>.filled(totalNodes, _kUnknown);
    _parent = List<int>.filled(totalNodes, -1);
    var nodeIndex = 0;
    var parentIndex = _leafCountX * _leafCountY;
    var parentGroupStart = parentIndex;
    for (var level = 0; level < levelWidths.length - 1; level++) {
      for (var y = 0; y < levelHeights[level]; y++) {
        var remaining = levelWidths[level];
        while (--remaining >= 0) {
          _parent[nodeIndex++] = parentIndex;
          if (--remaining >= 0) {
            _parent[nodeIndex++] = parentIndex;
          }
          parentIndex++;
        }
        if ((y & 1) != 0 || y == levelHeights[level] - 1) {
          parentGroupStart = parentIndex;
        } else {
          parentIndex = parentGroupStart;
        }
      }
    }
  }

  final int _leafCountX;
  final int _leafCountY;
  late final List<int> _low;
  late final List<int> _value;
  late final List<int> _parent;

  /// Resets every node so the tree can be reused for the next quality
  /// layer (OpenJPEG `opj_tgt_reset`).
  void reset() {
    _low.fillRange(0, _low.length, 0);
    _value.fillRange(0, _value.length, _kUnknown);
  }

  /// Decodes whether leaf [leafNo] reaches [threshold]; returns 1 when
  /// the leaf's value is below the threshold (OpenJPEG semantics).
  int decode(final JpxBitReader reader, final int leafNo, final int threshold) {
    if (leafNo < 0 || leafNo >= _leafCountX * _leafCountY) {
      throw const JpxException('Tag tree leaf outside the code-block grid.');
    }
    final stack = <int>[];
    var node = leafNo;
    while (_parent[node] >= 0) {
      stack.add(node);
      node = _parent[node];
    }
    var low = 0;
    while (true) {
      if (low > _low[node]) {
        _low[node] = low;
      } else {
        low = _low[node];
      }
      while (low < threshold && low < _value[node]) {
        if (reader.read(1) == 1) {
          _value[node] = low;
        } else {
          low++;
        }
      }
      _low[node] = low;
      if (stack.isEmpty) {
        break;
      }
      node = stack.removeLast();
    }
    return _value[node] < threshold ? 1 : 0;
  }
}
