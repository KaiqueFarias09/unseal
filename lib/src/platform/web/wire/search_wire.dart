import '../../../features/search/entities/search_match.dart';
import '../../../features/search/entities/search_results.dart';

/// Encodes [results] into a wire payload. No blobs: matches carry
/// text only.
Map<String, Object?> encodeSearchResultsWire(final SearchResults results) {
  return <String, Object?>{
    'query': results.query,
    'truncated': results.isTruncated,
    'matches': <Object?>[for (final match in results.matches) _encodeSearchMatch(match)],
  };
}

/// Decodes a [SearchResults] wire payload produced by
/// [encodeSearchResultsWire].
SearchResults decodeSearchResultsWire(final Map<String, Object?> json) {
  return SearchResults(
    query: json['query'] as String,
    isTruncated: json['truncated'] as bool,
    matches: <SearchMatch>[
      for (final match in json['matches'] as List<Object?>)
        _decodeSearchMatch(match as Map<String, Object?>),
    ],
  );
}

Map<String, Object?> _encodeSearchMatch(final SearchMatch match) {
  return <String, Object?>{
    'sectionIndex': match.sectionIndex,
    'sectionName': match.sectionName,
    'start': match.start,
    'end': match.end,
    'snippet': match.snippet,
  };
}

SearchMatch _decodeSearchMatch(final Map<String, Object?> json) {
  return SearchMatch(
    sectionIndex: json['sectionIndex'] as int,
    sectionName: json['sectionName'] as String,
    start: json['start'] as int,
    end: json['end'] as int,
    snippet: json['snippet'] as String,
  );
}
