part of '../book_search.dart';

/// A compiled query: the candidate pattern plus, for proximity searches, the word patterns every
/// candidate window must contain.
final class _CompiledQuery {
  const _CompiledQuery(this.pattern, this.requiredWords, {this.hasTokenSpanGroup = false});

  final RegExp pattern;

  final List<RegExp>? requiredWords;

  /// Whether [pattern] is a Unicode whole-word scan: group 1 captures the token span of a match.
  /// The match's suffix (only a zero-width [_wordBoundaryAhead] lookahead) means a
  /// [SearchMatch.start] is `match.start + match.group(0).length - match.group(1).length`, its end
  /// is `match.end`, and the boundary-behind is verified per candidate with [_isInsideWord]. This
  /// is kept out of the scan pattern because a `\p{...}` class in the per-position scan path makes
  /// the regex engine's automaton an order of magnitude slower.
  final bool hasTokenSpanGroup;
}
