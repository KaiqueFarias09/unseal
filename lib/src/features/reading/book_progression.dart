import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/features/text/document_text.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';

/// Reading progression of a book as fractions of its canonical text.
///
/// The canonical text space of a section is the `documentText` of its
/// HTML file — the same space search, CFI and navigation anchors
/// address. Character lengths are computed once at construction
/// (`documentTextOf` is memoized per file, so the pass is cheap and
/// shared with other consumers). Non-HTML sections (comic pages)
/// count as length 0 but keep their index, so section indexes stay
/// aligned with `Book.readingOrder`.
final class BookProgression {
  /// Builds the progression of [book], measuring every HTML reading
  /// order section once.
  factory BookProgression.of(final Book book) {
    final sections = book.readingOrder;
    final filesByPath = <String, TextFile>{for (final file in book.files.html) file.path: file};
    final lengths = List<int>.filled(sections.length, 0);
    for (var i = 0; i < sections.length; i++) {
      if (!sections[i].isHtml) continue;
      final file = filesByPath[sections[i].name];
      if (file == null) continue;
      lengths[i] = documentTextOf(file).length;
    }
    final starts = List<int>.filled(sections.length, 0);
    var total = 0;
    for (var i = 0; i < lengths.length; i++) {
      starts[i] = total;
      total += lengths[i];
    }
    return BookProgression._(
      sectionStarts: starts,
      sectionLengths: lengths,
      totalCharacters: total,
    );
  }

  const BookProgression._({
    required List<int> sectionStarts,
    required List<int> sectionLengths,
    required int totalCharacters,
  }) : _sectionStarts = sectionStarts,
       _sectionLengths = sectionLengths,
       _totalCharacters = totalCharacters;

  final List<int> _sectionStarts;

  final List<int> _sectionLengths;

  final int _totalCharacters;

  /// Number of sections in the reading order.
  int get sectionCount => _sectionLengths.length;

  /// Total characters of canonical text across all sections. Fully
  /// non-text books (comics) measure 0.
  int get totalCharacters => _totalCharacters;

  /// Progress across the whole book at [charOffset] inside
  /// [sectionIndex]: the characters before the section plus the
  /// in-section offset, over [totalCharacters].
  ///
  /// Negative positions measure 0 and positions past the last section
  /// measure 1; inside the reading order, [charOffset] clamps to the
  /// section's length. A fully non-text book (comic) falls back to
  /// [sectionIndex] over [sectionCount].
  double fractionOf({required final int sectionIndex, final int charOffset = 0}) {
    if (sectionCount == 0 || sectionIndex < 0) return 0;
    if (sectionIndex >= sectionCount) return 1;
    if (_totalCharacters == 0) return sectionIndex / sectionCount;
    final offset = _clamped(charOffset, _sectionLengths[sectionIndex]);
    return (_sectionStarts[sectionIndex] + offset) / _totalCharacters;
  }

  /// Progress within [sectionIndex] at [charOffset]: 0 at the
  /// section's first character, 1 at its end (or past it).
  ///
  /// [charOffset] clamps to the section's length; empty sections
  /// (non-HTML entries) and queries outside the reading order measure
  /// 0.
  double sectionFraction({required final int sectionIndex, required final int charOffset}) {
    if (sectionIndex < 0 || sectionIndex >= sectionCount) return 0;
    final length = _sectionLengths[sectionIndex];
    if (length == 0) return 0;
    return _clamped(charOffset, length) / length;
  }

  @override
  String toString() => 'BookProgression(sections: $sectionCount, characters: $totalCharacters)';
}

/// [value] clamped into `[0, limit]`.
int _clamped(final int value, final int limit) => value < 0 ? 0 : (value > limit ? limit : value);
