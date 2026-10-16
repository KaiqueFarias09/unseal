/// How an indexed query interprets its tokens.
enum IndexedQueryMode {
  /// Every query token must occur exactly (after the shared
  /// lowercasing/unaccenting normalization). Hits anchor on the first
  /// token's occurrences.
  exact,

  /// Like [exact], with the last token matched as a prefix: every indexed
  /// term starting with it joins the match, weighted by the MiniSearch
  /// prefix decay. Earlier tokens stay exact.
  prefix,

  /// Like [exact], with the last token matched fuzzily within a bounded
  /// Levenshtein distance (MiniSearch's fractional rule: a fraction of
  /// the token length, capped by [SearchIndexLimits.maxFuzzyDistance]).
  /// Earlier tokens stay exact.
  fuzzy,
}

/// Finite work and output caps of the search index.
///
/// Every cap is checked before the allocation or loop it bounds, so an
/// adversarial query or payload fails with
/// `SearchIndexLimitExceededException` instead of hanging or exhausting
/// memory. Defaults target reader-class devices; raising them is an
/// explicit caller decision.
final class SearchIndexLimits {
  /// Creates a limits set; every value is clamped to a sane floor.
  const SearchIndexLimits({
    this.maxSections = 65536,
    this.maxTerms = 2000000,
    this.maxOccurrences = 32000000,
    this.maxTermLength = 256,
    this.maxQueryTokens = 16,
    this.maxExpansions = 200,
    this.maxFuzzyDistance = 6,
    this.maxMatches = 200,
    this.maxSerializedBytes = 268435456,
  });

  /// Largest number of sections one index covers. Above the cap the
  /// build fails with `SearchIndexLimitExceededException`.
  final int maxSections;

  /// Largest number of distinct terms one index holds.
  final int maxTerms;

  /// Largest total number of stored occurrence ranges (postings pairs)
  /// across all terms and sections.
  final int maxOccurrences;

  /// Longest single term (in code units) accepted from text or a
  /// serialized payload.
  final int maxTermLength;

  /// Most tokens one query may carry; queries with more tokens fail as
  /// invalid arguments instead of fanning out unbounded.
  final int maxQueryTokens;

  /// Most terms one prefix/fuzzy token may expand to. An adversarial
  /// token above the cap fails with `SearchIndexLimitExceededException`.
  final int maxExpansions;

  /// Cap applied when the fuzzy mode derives its distance from the
  /// token length (the MiniSearch `maxFuzzy`).
  final int maxFuzzyDistance;

  /// Default cap on returned hits per query. The effective default on
  /// the query itself; `isTruncated` reports a cut result list.
  final int maxMatches;

  /// Largest serialized payload (in UTF-16 code units of its JSON form)
  /// an import accepts before parsing — the first hostile-input gate.
  final int maxSerializedBytes;

  /// The effective section cap after clamping (at least 1).
  int get effectiveMaxSections => maxSections < 1 ? 1 : maxSections;

  /// The effective term cap after clamping (at least 1).
  int get effectiveMaxTerms => maxTerms < 1 ? 1 : maxTerms;

  /// The effective occurrence cap after clamping (at least 1).
  int get effectiveMaxOccurrences => maxOccurrences < 1 ? 1 : maxOccurrences;

  /// The effective term-length cap after clamping (at least 1).
  int get effectiveMaxTermLength => maxTermLength < 1 ? 1 : maxTermLength;

  /// The effective query-token cap after clamping (at least 1).
  int get effectiveMaxQueryTokens => maxQueryTokens < 1 ? 1 : maxQueryTokens;

  /// The effective expansion cap after clamping (at least 1).
  int get effectiveMaxExpansions => maxExpansions < 1 ? 1 : maxExpansions;

  /// The effective fuzzy-distance cap after clamping (at least 0).
  int get effectiveMaxFuzzyDistance => maxFuzzyDistance < 0 ? 0 : maxFuzzyDistance;

  /// The effective match cap after clamping (at least 1).
  int get effectiveMaxMatches => maxMatches < 1 ? 1 : maxMatches;

  /// The effective serialized-payload cap after clamping (at least
  /// 1024 code units).
  int get effectiveMaxSerializedBytes => maxSerializedBytes < 1024 ? 1024 : maxSerializedBytes;
}
