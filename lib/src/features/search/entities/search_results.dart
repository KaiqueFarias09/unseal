import '../../../foundation/entities/entities.dart';
import 'search_match.dart';

/// The result of a full-text search over a [Book].
final class SearchResults {
  /// Creates [SearchResults].
  const SearchResults({required this.query, required this.matches, required this.isTruncated});

  /// The search query.
  final String query;

  /// The matches, in reading order.
  final List<SearchMatch> matches;

  /// Whether [matches] was cut short by `maxMatches`.
  final bool isTruncated;

  @override
  String toString() {
    return 'SearchResults(query: $query, matches: ${matches.length}, isTruncated: $isTruncated)';
  }
}
