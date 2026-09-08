import 'package:e_livre/src/features/search/entities/search_match.dart';
import 'package:e_livre/src/features/search/entities/search_mode.dart';
import 'package:e_livre/src/features/search/entities/search_results.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/utils/document_text.dart';

part 'entities/compiled_query.dart';
part 'query_compiler.dart';

/// Default proximity interval in characters for queries without an explicit trailing interval.
const int _defaultNearChars = 60;

/// A character that is not a Unicode word character: anything outside `\p{L}` (letters), `\p{N}`
/// (numbers) and `_` — the negated image of the Python `re` `\w` class (see
/// [SearchMode.wholeWords]).
const String _nonWordChar = r'[^\p{L}\p{N}_]';

/// A single Unicode word character, anchored. Only ever run on the one or two code units preceding
/// a candidate match — never on the scanned text (see [_isInsideWord]).
final RegExp _wordChar = RegExp(r'^[\p{L}\p{N}_]$', unicode: true);

/// Consumed boundary-behind prefix: string start or one non-word character. Used where the scanned
/// string is tiny (the proximity required-word patterns run against the candidate window only); the
/// whole-text scan patterns use the per-candidate [_isInsideWord] check instead (see
/// [_CompiledQuery.hasTokenSpanGroup]).
const String _wordBoundaryBehind = '(?:^|$_nonWordChar)';

/// Zero-width boundary after a whole-word token: a non-word character or the end of the text. Kept
/// as a lookahead in the scan patterns — it runs once per candidate, where a boundary-behind class
/// would run once per scanned position.
const String _wordBoundaryAhead = '(?=$_nonWordChar|\$)';

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

    final compiled = _compile(
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
      final requiredWords = compiled.requiredWords;

      for (final candidate in compiled.pattern.allMatches(text)) {
        if (requiredWords != null && !_hasAllWordsInWindow(candidate, requiredWords)) continue;
        // The token span is group 1; only a zero-width lookahead follows the match's suffix, so its
        // start is recovered from the two lengths.
        final start = compiled.hasTokenSpanGroup
            ? candidate.start + candidate.group(0)!.length - candidate.group(1)!.length
            : candidate.start;
        if (compiled.hasTokenSpanGroup && _isInsideWord(text, start)) continue;

        if (results.length >= maxMatches) {
          isTruncated = true;

          break;
        }

        results.add(
          SearchMatch(
            sectionIndex: sectionIndex,
            sectionName: section.name,
            start: start,
            end: candidate.end,
            snippet: _snippet(text, start, candidate.end, contextChars),
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
