/// The versioned locator currency for positions inside a parsed book.
///
/// A locator addresses one point or range of a book in exactly one of three coordinate systems:
///
/// * [TextLocator] — character offsets in the canonical `documentText` space of one reading-order
///   section, the same space search hits and CFI character offsets address;
/// * [CfiLocator] — an opaque EPUB CFI string;
/// * [PageLocator] — a flat page index for page-based formats such as comics (and, later, PDF).
///
/// The union is sealed, so consumers can switch over all kinds exhaustively. `locator_codec.dart`
/// versioned-encodes every kind to JSON and back, and `fuzzy_relocation.dart` re-anchors a
/// [TextLocator] whose offsets drifted.
library;

/// Base of the locator union: [TextLocator], [CfiLocator] or [PageLocator].
sealed class BookLocator {
  const BookLocator();
}

/// A position or range in the document-text space of one reading-order section.
final class TextLocator extends BookLocator {
  /// Creates a text locator; [start] == [end] addresses a point.
  const TextLocator({
    required this.sectionIndex,
    required this.start,
    required this.end,
    this.quote,
  });

  /// Index of the section inside the book's reading order.
  final int sectionIndex;

  /// First character offset of the located range (inclusive).
  final int start;

  /// One past the last character offset of the located range (exclusive); equals [start] for a
  /// point.
  final int end;

  /// The quoted text around the range, when known — the payload `fuzzy_relocation.dart` needs to
  /// re-anchor these offsets after the section text changed.
  final TextQuote? quote;

  /// Whether this locator addresses a single point (`start == end`).
  bool get isPoint => start == end;

  @override
  int get hashCode => Object.hash(sectionIndex, start, end, quote);

  @override
  bool operator ==(final Object other) {
    return other is TextLocator &&
        other.sectionIndex == sectionIndex &&
        other.start == start &&
        other.end == end &&
        other.quote == quote;
  }

  @override
  String toString() => 'TextLocator($sectionIndex, $start..$end)';
}

/// A position or range addressed by an opaque EPUB CFI string.
final class CfiLocator extends BookLocator {
  /// Creates a CFI locator around [cfi].
  const CfiLocator(this.cfi);

  /// The CFI string — e.g. `epubcfi(/6/4!/4/2:10)` — addressing a point or a comma-separated range;
  /// parsed and resolved by the `cfi` feature.
  final String cfi;

  @override
  int get hashCode => cfi.hashCode;

  @override
  bool operator ==(final Object other) => other is CfiLocator && other.cfi == cfi;

  @override
  String toString() => 'CfiLocator($cfi)';
}

/// A position addressed by flat page index, for page-based formats such as comics (and, in the
/// future, PDF).
final class PageLocator extends BookLocator {
  /// Creates a page locator; [total] carries the page count when the format exposes one.
  const PageLocator({required this.pageIndex, this.total});

  /// Zero-based index of the page.
  final int pageIndex;

  /// Total number of pages, or null when unknown.
  final int? total;

  @override
  int get hashCode => Object.hash(pageIndex, total);

  @override
  bool operator ==(final Object other) {
    return other is PageLocator && other.pageIndex == pageIndex && other.total == total;
  }

  @override
  String toString() => total == null ? 'PageLocator($pageIndex)' : 'PageLocator($pageIndex/$total)';
}

/// The exact text of a located range together with its immediate surrounding context — the W3C
/// TextQuoteSelector analogue that lets `fuzzy_relocation.dart` re-anchor a [TextLocator] when the
/// section text changed under its offsets.
final class TextQuote {
  /// Creates a text quote.
  const TextQuote({required this.before, required this.text, required this.after});

  /// The text immediately before [text], empty at a section start.
  final String before;

  /// The exact text of the located range.
  final String text;

  /// The text immediately after [text], empty at a section end.
  final String after;

  @override
  int get hashCode => Object.hash(before, text, after);

  @override
  bool operator ==(final Object other) {
    return other is TextQuote &&
        other.before == before &&
        other.text == text &&
        other.after == after;
  }

  @override
  String toString() => 'TextQuote(…$text…)';
}
