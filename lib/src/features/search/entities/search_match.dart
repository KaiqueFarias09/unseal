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

  /// End offset (exclusive) of the match within the section's document text.
  final int end;

  /// The surrounding text, with `…` markers where context was cut.
  final String snippet;

  @override
  String toString() => 'SearchMatch(section: $sectionIndex, $start..$end, snippet: $snippet)';
}
