/// Wire codecs of the indexed search: the shape the session engine and
/// the worker ops exchange for indexed queries. Pure maps of
/// primitives — structured-clone-safe and JSON-safe — so the isolate
/// and Web Worker transports share one encoding.
library;

import 'indexed_query_mode.dart';
import 'indexed_search_results.dart';

/// Encodes [results] of an indexed query: hits with their original
/// UTF-16 ranges and scores plus the coverage that produced them.
Map<String, Object?> encodeIndexedSearchResultsWire(final IndexedSearchResults results) {
  return <String, Object?>{
    'query': results.query,
    'mode': results.mode.name,
    'truncated': results.isTruncated,
    'coverage': results.coverage.toWire(),
    'hits': <Object?>[for (final hit in results.hits) _encodeIndexedHit(hit)],
  };
}

/// Decodes an [IndexedSearchResults] wire payload produced by
/// [encodeIndexedSearchResultsWire].
IndexedSearchResults decodeIndexedSearchResultsWire(final Map<String, Object?> json) {
  return IndexedSearchResults(
    query: json['query'] as String,
    mode: IndexedQueryMode.values.byName(json['mode'] as String),
    isTruncated: json['truncated'] as bool,
    coverage: SearchIndexCoverage.fromWire(json['coverage']),
    hits: <IndexedSearchHit>[
      for (final hit in json['hits'] as List<Object?>)
        _decodeIndexedHit(hit as Map<String, Object?>),
    ],
  );
}

Map<String, Object?> _encodeIndexedHit(final IndexedSearchHit hit) {
  return <String, Object?>{
    'sectionIndex': hit.sectionIndex,
    'sectionName': hit.sectionName,
    'start': hit.start,
    'end': hit.end,
    'snippet': hit.snippet,
    'score': hit.score,
  };
}

IndexedSearchHit _decodeIndexedHit(final Map<String, Object?> json) {
  return IndexedSearchHit(
    sectionIndex: json['sectionIndex'] as int,
    sectionName: json['sectionName'] as String,
    start: json['start'] as int,
    end: json['end'] as int,
    snippet: json['snippet'] as String,
    score: (json['score'] as num).toDouble(),
  );
}
