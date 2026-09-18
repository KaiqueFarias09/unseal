/// Fuzzy relocation of text locators across changed section text.
///
/// Character offsets in a section's document-text space break when the section is re-rendered or
/// its source changes. A [TextLocator] carrying a [TextQuote] survives: the quote's exact text is
/// searched again — first in the locator's own section, then, when it moved, across the other
/// sections — and candidate occurrences are ranked by how much of the surrounding context
/// ([TextQuote.before]/[TextQuote.after]) still agrees with the text around the occurrence. Pure
/// function: no book, no I/O, only the list of section texts in reading order.
library;

import 'dart:math' as math;

import 'book_locator.dart';

/// Relocates [locator] against [sectionTexts], the document texts of the reading-order sections.
///
/// The exact `locator.quote.text` is searched with plain `indexOf` scanning — first in
/// `sectionTexts[locator.sectionIndex]`, then in every other section in reading order. When an
/// occurrence appears multiple times, the one with the best context score wins (how much of
/// `quote.before` still matches the text immediately before the occurrence plus how much of
/// `quote.after` matches right after); the earliest section and offset break ties. A hit in the
/// locator's own section always wins over the other sections.
///
/// Returns a locator addressing the found occurrence — its range starts at the found text and keeps
/// the original span clamped to the quote length — carrying the same quote for further relocations.
/// Returns null when the locator has no quote, the quote text is empty, or the quote is found
/// nowhere.
TextLocator? relocateTextLocator(final TextLocator locator, final List<String> sectionTexts) {
  final quote = locator.quote;
  if (quote == null || quote.text.isEmpty) return null;

  final sameSectionHit = _bestHitInSection(locator.sectionIndex, sectionTexts, quote);
  if (sameSectionHit != null) {
    return _buildRelocatedLocator(locator, sameSectionHit.section, sameSectionHit.offset);
  }

  _Hit? bestOtherSectionHit;
  for (var section = 0; section < sectionTexts.length; section++) {
    if (section == locator.sectionIndex) continue;

    final candidate = _bestHitInSection(section, sectionTexts, quote);
    if (candidate != null &&
        (bestOtherSectionHit == null || candidate.score > bestOtherSectionHit.score)) {
      bestOtherSectionHit = candidate;
    }
  }

  if (bestOtherSectionHit == null) return null;

  return _buildRelocatedLocator(locator, bestOtherSectionHit.section, bestOtherSectionHit.offset);
}

/// One occurrence of a quote inside a section, with its context score.
typedef _Hit = ({int section, int offset, int score});

/// Finds the best-scoring occurrence of `quote.text` in `sectionTexts[section]` — highest context
/// score, earliest offset on ties — or null when the section index is out of range or the text
/// holds no occurrence.
_Hit? _bestHitInSection(final int section, final List<String> sectionTexts, final TextQuote quote) {
  if (section < 0 || section >= sectionTexts.length) return null;

  final text = sectionTexts[section];
  _Hit? bestHit;
  var from = 0;
  while (true) {
    final offset = text.indexOf(quote.text, from);
    if (offset < 0) break;

    final score = _contextScore(text, offset, quote);
    if (bestHit == null || score > bestHit.score) {
      bestHit = (section: section, offset: offset, score: score);
    }
    from = offset + 1;
  }

  return bestHit;
}

/// Counts the characters of context agreement around the occurrence at [offset]: how long a suffix
/// of `quote.before` matches the text immediately before the occurrence, plus how long a prefix of
/// `quote.after` matches the text immediately after it.
int _contextScore(final String text, final int offset, final TextQuote quote) {
  var score = 0;
  final maxBefore = math.min(quote.before.length, offset);
  for (var i = 1; i <= maxBefore; i++) {
    if (text.codeUnitAt(offset - i) != quote.before.codeUnitAt(quote.before.length - i)) break;
    score++;
  }

  final afterOffset = offset + quote.text.length;
  final maxAfter = math.min(quote.after.length, text.length - afterOffset);
  for (var i = 0; i < maxAfter; i++) {
    if (text.codeUnitAt(afterOffset + i) != quote.after.codeUnitAt(i)) break;
    score++;
  }

  return score;
}

/// Builds the relocated locator: the range starts at the found occurrence and keeps the original
/// span, clamped to the quote length so it never points past the found text.
TextLocator _buildRelocatedLocator(final TextLocator locator, final int section, final int offset) {
  final quote = locator.quote!;
  final span = math.max(0, math.min(locator.end - locator.start, quote.text.length));

  return TextLocator(
    sectionIndex: section,
    start: offset,
    end: offset + span,
    quote: locator.quote,
  );
}
