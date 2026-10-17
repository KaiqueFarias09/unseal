/// Ranking of the per-publication search index: the BM25+ scoring of
/// MiniSearch ([revision
/// `3d239d1c`](https://github.com/lucaong/minisearch/blob/3d239d1c3ae7aef1bf5d8945dd7b5f0709f646f5/src/MiniSearch.ts),
/// MIT — see `THIRD_PARTY_NOTICES.md`) with Tantivy's postings/positions
/// model ([revision
/// `e1acb3e0`](https://github.com/quickwit-oss/tantivy/tree/e1acb3e0112f2b4819946aa4ea5742bf429853d8),
/// MIT) as the reference for what the index stores.
///
/// A section scores `sum over matched terms of termWeight * idf * (d +
/// tf * (k + 1) / (tf + k * (1 - b + b * length / avgLength)))` with
/// the MiniSearch defaults k=1.2, b=0.7, d=0.5. Expansion weights:
///
/// * an exact term weighs 1;
/// * a prefix expansion weighs `prefixWeight * rl / (rl + 0.3 * rl)`
///   with `rl` the expansion's length beyond the query token. The
///   original derives the same expression from the relative view key
///   and skips the exact term; this port states it in relative terms
///   and skips `rl == 0` explicitly.
/// * a fuzzy expansion weighs `fuzzyWeight * term.length / (term.length
///   + distance)`, skipping distance 0 (the exact term).
///
/// Defaults: `prefixWeight` 0.375, `fuzzyWeight` 0.45.
library;

import 'dart:math' as math;

/// BM25+ parameters (the MiniSearch defaults).
final class Bm25PlusParameters {
  /// Creates the parameter set.
  const Bm25PlusParameters({this.k = 1.2, this.b = 0.7, this.d = 0.5});

  /// Term-frequency saturation point.
  final double k;

  /// Length-normalization impact.
  final double b;

  /// BM25+ frequency normalization lower bound (δ).
  final double d;
}

/// The default scoring parameters.
const Bm25PlusParameters defaultBm25Plus = Bm25PlusParameters();

/// Weight of exact-term matches.
const double exactTermWeight = 1.0;

/// Weight scale of prefix expansions (the MiniSearch default).
const double prefixWeight = 0.375;

/// Weight scale of fuzzy expansions (the MiniSearch default).
const double fuzzyWeight = 0.45;

/// Decay rate of prefix weights with expansion length (the MiniSearch
/// `0.3` factor).
const double prefixDecay = 0.3;

/// The BM25+ score of one term in one section.
double bm25PlusScore({
  required final int termFrequency,
  required final int matchingSections,
  required final int totalSections,
  required final int sectionLength,
  required final double averageLength,
  final Bm25PlusParameters parameters = defaultBm25Plus,
}) {
  if (totalSections <= 0 || averageLength <= 0 || matchingSections <= 0) return 0;
  final inverseDocFrequency = math.log(
    1 + (totalSections - matchingSections + 0.5) / (matchingSections + 0.5),
  );
  final tf = termFrequency.toDouble();
  final normalization =
      parameters.k * (1 - parameters.b + parameters.b * sectionLength / averageLength);

  return inverseDocFrequency * (parameters.d + tf * (parameters.k + 1) / (tf + normalization));
}

/// The weight of one prefix expansion: [extraLength] code units beyond
/// the query token. The exact term (`extraLength == 0`) weighs nothing —
/// the exact match already carries weight 1.
double prefixExpansionWeight({required final int extraLength, required final int queryLength}) {
  if (extraLength <= 0 || queryLength <= 0) return 0;

  return prefixWeight * extraLength / (extraLength + prefixDecay * extraLength);
}

/// The weight of one fuzzy expansion at Levenshtein [distance] from a
/// [termLength]-code-unit term. Distance 0 weighs nothing.
double fuzzyExpansionWeight({required final int termLength, required final int distance}) {
  if (distance <= 0 || termLength <= 0) return 0;

  return fuzzyWeight * termLength / (termLength + distance);
}
