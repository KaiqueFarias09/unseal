import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';

/// One hit of a full-text search over a book's content.
final class SearchMatch {
  /// Creates a [SearchMatch].
  const SearchMatch({
    required this.sectionIndex,
    required this.sectionName,
    required this.start,
    required this.end,
    required this.snippet,
  });

  /// Index of the content section inside the book's reading order.
  final int sectionIndex;

  /// Path of the content file holding the match.
  final String sectionName;

  /// Start offset of the match within the section's plain text.
  final int start;

  /// End offset (exclusive) of the match within the section's plain text.
  final int end;

  /// The surrounding text, with `…` markers where context was cut.
  final String snippet;

  @override
  String toString() =>
      'SearchMatch(section: $sectionIndex, $start..$end, snippet: $snippet)';
}

/// The result of a full-text search over a [Book].
final class SearchResults {
  /// Creates [SearchResults].
  const SearchResults({
    required this.query,
    required this.matches,
    required this.truncated,
  });

  /// The search query.
  final String query;

  /// The matches, in reading order.
  final List<SearchMatch> matches;

  /// Whether [matches] was cut short by `maxMatches`.
  final bool truncated;

  @override
  String toString() =>
      'SearchResults(query: $query, matches: ${matches.length}, truncated: $truncated)';
}

/// Full-text search over a book's plain text.
///
/// Finds every occurrence of the query across the book's HTML
/// sections (in reading order), case-insensitively by default.
/// Matches carry the section they were found in plus offsets and a
/// context snippet within that section's plain text.
extension BookSearch on Book {
  /// Searches the book's plain text for [query].
  ///
  /// [contextChars] controls how much surrounding text each snippet
  /// carries on either side; [maxMatches] caps the result size.
  SearchResults search(
    final String query, {
    final bool caseSensitive = false,
    final int contextChars = 48,
    final int maxMatches = 200,
  }) {
    final results = <SearchMatch>[];
    if (query.isEmpty) {
      return SearchResults(query: query, matches: results, truncated: false);
    }

    final sections = readingOrder;
    for (var sectionIndex = 0; sectionIndex < sections.length; sectionIndex++) {
      final section = sections[sectionIndex];
      if (!section.isHtml) continue;

      TextFile? file;
      for (final candidate in files.html) {
        if (candidate.path == section.name) {
          file = candidate;
          break;
        }
      }
      if (file == null) continue;

      final text = file.plainText;
      final haystack = caseSensitive ? text : text.toLowerCase();
      final needle = caseSensitive ? query : query.toLowerCase();

      var from = 0;
      while (from <= haystack.length - needle.length) {
        final start = haystack.indexOf(needle, from);
        if (start == -1) break;
        final end = start + needle.length;

        if (results.length >= maxMatches) {
          return SearchResults(query: query, matches: results, truncated: true);
        }
        results.add(
          SearchMatch(
            sectionIndex: sectionIndex,
            sectionName: section.name,
            start: start,
            end: end,
            snippet: _snippet(text, start, end, contextChars),
          ),
        );
        from = end;
      }
    }

    return SearchResults(query: query, matches: results, truncated: false);
  }

  /// Builds a context snippet around `[start, end)` with ellipses
  /// where the surrounding text was cut.
  static String _snippet(
    final String text,
    final int start,
    final int end,
    final int contextChars,
  ) {
    final from = (start - contextChars).clamp(0, text.length);
    final to = (end + contextChars).clamp(0, text.length);
    final prefix = from > 0 ? '…' : '';
    final suffix = to < text.length ? '…' : '';
    return '$prefix${text.substring(from, to)}$suffix';
  }
}
