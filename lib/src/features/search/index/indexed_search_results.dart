import '../../locators/book_locator.dart';
import 'indexed_query_mode.dart';

/// Coverage of an index over a book's eligible sections (C05): the
/// counters distinguish eligible occurrences, indexed ones, and
/// pending/failed ones, so a partial index never masquerades as
/// complete. `complete` means every eligible section is indexed and no
/// failure gaps remain.
final class SearchIndexCoverage {
  /// Creates a coverage snapshot.
  const SearchIndexCoverage({
    required this.eligibleSections,
    required this.indexedSections,
    required this.pendingSections,
    required this.failedSections,
    required this.totalTokens,
    required this.totalOccurrences,
    required this.termCount,
    this.isComplete = false,
    this.wasCancelled = false,
    this.limitHit,
  });

  /// Sections the index is eligible to cover (the sections the legacy
  /// full-text search would scan).
  final int eligibleSections;

  /// Sections indexed so far.
  final int indexedSections;

  /// Eligible sections not yet reached by an incremental build.
  final int pendingSections;

  /// Eligible sections that failed to index (missing document text).
  final int failedSections;

  /// Total tokens across indexed sections (the BM25 corpus length
  /// total).
  final int totalTokens;

  /// Total stored occurrence ranges.
  final int totalOccurrences;

  /// Distinct terms in the index.
  final int termCount;

  /// Whether every eligible section is indexed with no gaps.
  final bool isComplete;

  /// Whether a cancellation stopped the build (coverage stops moving).
  final bool wasCancelled;

  /// The limit that stopped the build, when one did.
  final String? limitHit;

  /// Whether at least one eligible section is still missing.
  bool get isPartial => !isComplete;

  /// The wire map of the coverage counters.
  Map<String, Object?> toWire() {
    return <String, Object?>{
      'eligibleSections': eligibleSections,
      'indexedSections': indexedSections,
      'pendingSections': pendingSections,
      'failedSections': failedSections,
      'totalTokens': totalTokens,
      'totalOccurrences': totalOccurrences,
      'termCount': termCount,
      'complete': isComplete,
      'cancelled': wasCancelled,
      'limitHit': limitHit,
    };
  }

  /// Rebuilds coverage from its wire map with pre-allocation bounds.
  static SearchIndexCoverage fromWire(final Object? wire) {
    if (wire is! Map<String, Object?>) {
      throw const FormatException('searchIndex coverage must be an object.');
    }

    return SearchIndexCoverage(
      eligibleSections: _bounded(wire['eligibleSections'], 'eligibleSections'),
      indexedSections: _bounded(wire['indexedSections'], 'indexedSections'),
      pendingSections: _bounded(wire['pendingSections'], 'pendingSections'),
      failedSections: _bounded(wire['failedSections'], 'failedSections'),
      totalTokens: _bounded(wire['totalTokens'], 'totalTokens'),
      totalOccurrences: _bounded(wire['totalOccurrences'], 'totalOccurrences'),
      termCount: _bounded(wire['termCount'], 'termCount'),
      isComplete: wire['complete'] == true,
      wasCancelled: wire['cancelled'] == true,
      limitHit: wire['limitHit'] is String ? wire['limitHit'] as String : null,
    );
  }

  static int _bounded(final Object? value, final String field) {
    // 2^40 as a literal: dart2js shifts wrap at 32 bits, so `1 << 40`
    // miscompares on the web (the VM gives the 64-bit result).
    if (value is! int || value < 0 || value > 1099511627776) {
      throw FormatException('searchIndex coverage field $field is out of bounds.');
    }

    return value;
  }
}

/// One hit of an indexed query: an anchored occurrence of the query in
/// one section's canonical text, with the section's score. Offsets are
/// UTF-16 code units in the same space `Book.search` and CFI address.
final class IndexedSearchHit {
  /// Creates a hit.
  const IndexedSearchHit({
    required this.sectionIndex,
    required this.sectionName,
    required this.start,
    required this.end,
    required this.snippet,
    required this.score,
  });

  /// Zero-based reading-order index of the section (the occurrence id
  /// of the shared contract; repeated paths stay distinct sections).
  final int sectionIndex;

  /// Exact resource path of the section.
  final String sectionName;

  /// Inclusive start of the hit, in UTF-16 code units.
  final int start;

  /// Exclusive end of the hit, in UTF-16 code units.
  final int end;

  /// Surrounding text with `…` markers where context was cut.
  final String snippet;

  /// The section's BM25+ score for the query. Ties break by section
  /// index, then start, then end — never by map order.
  final double score;

  @override
  String toString() => 'IndexedSearchHit(section: $sectionIndex, $start..$end, score: $score)';
}

/// The result of an indexed query.
final class IndexedSearchResults {
  /// Creates a result set.
  const IndexedSearchResults({
    required this.query,
    required this.mode,
    required this.hits,
    required this.isTruncated,
    required this.coverage,
  });

  /// The raw query text.
  final String query;

  /// The mode the query ran in.
  final IndexedQueryMode mode;

  /// Hits in the shared deterministic order: score descending, then
  /// section (occurrence) ascending, start ascending, end ascending.
  final List<IndexedSearchHit> hits;

  /// Whether [hits] was cut short by the match cap — a result cut, not
  /// a coverage statement.
  final bool isTruncated;

  /// Coverage of the index that produced the hits: over a partial
  /// index, an empty result never proves absence in the book.
  final SearchIndexCoverage coverage;

  @override
  String toString() =>
      'IndexedSearchResults(query: $query, hits: ${hits.length}, '
      'truncated: $isTruncated, complete: ${coverage.isComplete})';
}

/// Locator conversions for [IndexedSearchHit] — the same bridge the
/// legacy `SearchMatch` uses.
extension IndexedSearchHitLocators on IndexedSearchHit {
  /// The hit as a [TextLocator]: the same section and offsets, end
  /// exclusive.
  TextLocator toTextLocator() => TextLocator(sectionIndex: sectionIndex, start: start, end: end);
}
