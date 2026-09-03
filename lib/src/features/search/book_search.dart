import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/features/text/document_text.dart';
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

  /// Start offset of the match within the section's document text.
  final int start;

  /// End offset (exclusive) of the match within the section's
  /// document text.
  final int end;

  /// The surrounding text, with `…` markers where context was cut.
  final String snippet;

  @override
  String toString() => 'SearchMatch(section: $sectionIndex, $start..$end, snippet: $snippet)';
}

/// The result of a full-text search over a [Book].
final class SearchResults {
  /// Creates [SearchResults].
  const SearchResults({required this.query, required this.matches, required this.truncated});

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
/// sections (in reading order). Matching is case-insensitive by
/// default and, in the tolerant mode, ignores soft hyphens and
/// zero-width characters and collapses whitespace runs — the same
/// leniency Calibre's reader applies. Match offsets address the
/// `documentText` space of each section, so a hit can be highlighted
/// in a rendered page or turned into a reading position.
extension BookSearch on Book {
  /// Searches the book's document text for [query].
  ///
  /// [contextChars] controls how much surrounding text each snippet
  /// carries on either side; [maxMatches] caps the result size;
  /// [tolerant] enables the hyphenation/whitespace leniency (disable
  /// for exact substring matching).
  SearchResults search(
    final String query, {
    final bool caseSensitive = false,
    final bool tolerant = true,
    final int contextChars = 48,
    final int maxMatches = 200,
  }) {
    final results = <SearchMatch>[];
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return SearchResults(query: query, matches: results, truncated: false);
    }

    final pattern = tolerant
        ? _tolerantPattern(trimmed, caseSensitive: caseSensitive)
        : RegExp(RegExp.escape(trimmed), caseSensitive: caseSensitive);

    final sections = readingOrder;
    var truncated = false;
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

      final text = documentText(file.content);
      for (final match in pattern.allMatches(text)) {
        if (results.length >= maxMatches) {
          truncated = true;
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
      if (truncated) break;
    }

    return SearchResults(query: query, matches: results, truncated: truncated);
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

/// Optional separators between query characters: soft hyphens and
/// zero-width characters inserted by typesetting.
const String _invisibleSeparators = r'[\u00AD\u200B\u200C\u200D]?';

/// Builds the lenient match pattern for [query]: each whitespace run
/// in the query matches any whitespace run in the text, invisible
/// separators may appear between characters, and the match is
/// case-insensitive. Parity with Calibre's reader search.
RegExp _tolerantPattern(final String query, {required final bool caseSensitive}) {
  final buffer = StringBuffer();
  for (final char in query.trim().split('')) {
    if (buffer.isNotEmpty) {
      buffer.write(_invisibleSeparators);
    }
    if (RegExp(r'\s').hasMatch(char)) {
      buffer.write(r'\s+');
    } else {
      buffer.write(RegExp.escape(char));
    }
  }
  return RegExp(buffer.toString(), caseSensitive: caseSensitive);
}
