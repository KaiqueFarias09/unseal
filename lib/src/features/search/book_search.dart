import '../../foundation/entities/entities.dart';
import '../../foundation/text/canonical_document_text.dart';

import 'entities/search_match.dart';
import 'entities/search_mode.dart';
import 'entities/search_results.dart';
import 'query_compiler.dart';

/// Default proximity interval in characters for queries without an explicit trailing interval.
const int _defaultNearChars = 60;

/// Full-text search over a book's plain text.
///
/// Finds every occurrence of the query across the book's HTML sections (in reading order). Matching
/// is case-insensitive by default and, in the tolerant mode, ignores soft hyphens and zero-width
/// characters and collapses whitespace runs. Match offsets address the `documentText` space of each
/// section, so a hit can be highlighted in a rendered page or turned into a reading position.
extension BookSearch on Book {
  /// Searches the book's document text for [query].
  ///
  /// [mode] selects how [query] is interpreted (see [SearchMode]). [isCaseSensitive] disables case
  /// folding on every mode. [isTolerant] enables the hyphenation/whitespace leniency on the
  /// non-regex modes (disable for exact matching). [nearChars] is the proximity interval used when
  /// the query carries no trailing number. [contextChars] controls how much surrounding text each
  /// snippet carries on either side; [maxMatches] caps the result size.
  ///
  /// Throws [FormatException] for an invalid [SearchMode.regex] pattern or a [SearchMode.proximity]
  /// query with fewer than two words.
  SearchResults search(
    final String query, {
    final SearchMode mode = SearchMode.contains,
    final bool isCaseSensitive = false,
    final bool isTolerant = true,
    final int nearChars = _defaultNearChars,
    final int contextChars = 48,
    final int maxMatches = 200,
  }) {
    final results = <SearchMatch>[];
    final trimmed = query.trim();
    if (trimmed.isEmpty) return SearchResults(query: query, matches: results, isTruncated: false);

    final compiled = compileSearchQuery(
      trimmed,
      mode: mode,
      isCaseSensitive: isCaseSensitive,
      isTolerant: isTolerant,
      nearChars: nearChars,
    );
    final htmlByPath = <String, TextFile>{for (final file in files.html) file.path: file};
    final sections = readingOrder;
    var isTruncated = false;
    for (var sectionIndex = 0; sectionIndex < sections.length; sectionIndex++) {
      final section = sections[sectionIndex];
      if (!section.isHtml) continue;

      final file = htmlByPath[section.name];
      if (file == null) continue;

      final text = documentTextOf(file);
      for (final match in compiled.findMatches(text)) {
        if (results.length >= maxMatches) {
          isTruncated = true;
          break;
        }

        results.add(
          SearchMatch(
            sectionIndex: sectionIndex,
            sectionName: section.name,
            start: match.start,
            end: match.end,
            snippet: _snippet(text, match.start, match.end, contextChars),
          ),
        );
      }

      if (isTruncated) break;
    }

    return SearchResults(query: query, matches: results, isTruncated: isTruncated);
  }

  /// Builds a context snippet around `[start, end)` with ellipses where the surrounding text was
  /// cut.
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
