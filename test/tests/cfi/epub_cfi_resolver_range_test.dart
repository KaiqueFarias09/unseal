import 'dart:io';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  final aliceBytes = File(
    'test/resources/epub/Alices Adventures in Wonderland.epub',
  ).readAsBytesSync();
  final book = parseEpubBook(aliceBytes);

  // First reading order section with real running text (the cover
  // and title pages are skipped) and its parsed document model.
  late final sectionIndex = _textSectionOf(book);
  late final document = EpubCfiDocument.parse(_htmlOf(book, sectionIndex).content);
  late final textLength = document.text.length;

  group('EpubCfiResolver range building', () {
    test('builds a range inside one text node and resolves it back', () {
      final (start, end) = _sameNodeSpan(document, textLength ~/ 3);
      final built = book.buildEpubCfiRange(
        contentIndex: sectionIndex,
        startOffset: start,
        endOffset: end,
      );

      final parsed = EpubCfi.tryParse(built);
      expect(parsed, isNotNull);
      expect(parsed!.isRange, isTrue);

      final location = book.resolveCfi(parsed);
      expect(location, isNotNull);
      expect(location!.contentIndex, sectionIndex);
      expect(location.contentPath, book.readingOrder[sectionIndex].name);
      expect(location.charOffset, start);
      expect(location.endCharOffset, end);
      expect(location.textExcerpt, contains(document.text.substring(start, end)));
    });

    test('builds a range across two elements and resolves it back', () {
      final (start, end) = _crossElementSpan(document, textLength ~/ 3);
      expect(end, greaterThan(start));
      final built = book.buildEpubCfiRange(
        contentIndex: sectionIndex,
        startOffset: start,
        endOffset: end,
      );

      final parsed = EpubCfi.tryParse(built);
      expect(parsed, isNotNull);
      expect(parsed!.isRange, isTrue);

      final location = book.resolveCfi(parsed);
      expect(location, isNotNull);
      expect(location!.contentIndex, sectionIndex);
      expect(location.charOffset, start);
      expect(location.endCharOffset, end);
      expect(location.textExcerpt, contains(document.text.substring(start, end)));
    });

    test('round-trips through parse and encode byte-identically', () {
      final spans = [
        _sameNodeSpan(document, textLength ~/ 3),
        _crossElementSpan(document, textLength ~/ 4),
      ];
      for (final (start, end) in spans) {
        final built = book.buildEpubCfiRange(
          contentIndex: sectionIndex,
          startOffset: start,
          endOffset: end,
        );
        expect(EpubCfi.parse(built).encode(), built);
      }
    });

    test('equal offsets degenerate to the point form', () {
      final offset = textLength ~/ 3;
      final built = book.buildEpubCfiRange(
        contentIndex: sectionIndex,
        startOffset: offset,
        endOffset: offset,
      );
      expect(built, book.buildEpubCfi(contentIndex: sectionIndex, offsetInText: offset));
      expect(built.contains(','), isFalse);

      final location = book.resolveCfi(EpubCfi.parse(built));
      expect(location, isNotNull);
      expect(location!.charOffset, offset);
      expect(location.endCharOffset, isNull);
    });

    test('rejects inverted, out-of-section and out-of-range offsets', () {
      expect(
        () => book.buildEpubCfiRange(contentIndex: sectionIndex, startOffset: 10, endOffset: 5),
        throwsArgumentError,
      );
      expect(
        () => book.buildEpubCfiRange(contentIndex: -1, startOffset: 0, endOffset: 5),
        throwsRangeError,
      );
      expect(
        () => book.buildEpubCfiRange(
          contentIndex: book.readingOrder.length,
          startOffset: 0,
          endOffset: 5,
        ),
        throwsRangeError,
      );
      expect(
        () => book.buildEpubCfiRange(contentIndex: sectionIndex, startOffset: -1, endOffset: 5),
        throwsRangeError,
      );
      expect(
        () => book.buildEpubCfiRange(
          contentIndex: sectionIndex,
          startOffset: 0,
          endOffset: textLength + 1,
        ),
        throwsRangeError,
      );
    });
  });

  group('EpubCfiResolver point locations', () {
    test('keep endCharOffset null', () {
      final offset = textLength ~/ 3;
      final cfi = EpubCfi.parse(
        book.buildEpubCfi(contentIndex: sectionIndex, offsetInText: offset),
      );
      final location = book.resolveCfi(cfi);
      expect(location, isNotNull);
      expect(location!.contentIndex, sectionIndex);
      expect(location.charOffset, offset);
      expect(location.endCharOffset, isNull);
    });
  });

  group('EpubCfiResolver range limits', () {
    test('returns null for ranges whose boundaries cross a spine break', () {
      // Boundary subpaths carrying their own spine segment leave the
      // leading path's section, which cannot be resolved.
      final cfi = EpubCfi.parse('epubcfi(/6/2!/4,/6/2!/1:0,/6/2!/2:5)');
      expect(book.resolveCfi(cfi), isNull);
    });

    test('returns null when a boundary walks past the DOM', () {
      final spine = (sectionIndex + 1) * 2;
      final cfi = EpubCfi.parse('epubcfi(/6/$spine!/4,/1:0,/99999:5)');
      expect(book.resolveCfi(cfi), isNull);
    });
  });
}

/// Two consecutive offsets addressed by the same text step, scanning
/// forward from [from].
(int, int) _sameNodeSpan(final EpubCfiDocument document, final int from) {
  var previous = document.cfiForOffset(from).steps.last;
  for (var offset = from + 1; offset <= from + 500; offset++) {
    final step = document.cfiForOffset(offset).steps.last;
    if (step == previous) {
      return (offset - 1, offset);
    }
    previous = step;
  }
  throw StateError('no two consecutive offsets of one text node after $from');
}

/// Two offsets whose element paths (every step but the final text
/// step) differ, scanning forward from [from].
(int, int) _crossElementSpan(final EpubCfiDocument document, final int from) {
  final parent = _parentPath(document, from);
  for (var end = from + 1; end < document.text.length && end <= from + 50000; end++) {
    if (_parentPath(document, end) != parent) {
      return (from, end);
    }
  }
  throw StateError('no cross-element span after $from');
}

/// The element steps (all but the final text step) addressing
/// [offset]'s text node, joined for comparison.
String _parentPath(final EpubCfiDocument document, final int offset) {
  final steps = document.cfiForOffset(offset).steps;
  return steps.sublist(0, steps.length - 1).join(',');
}

/// Index of the first reading order section whose document text is
/// long enough to slice ranges from.
int _textSectionOf(final EpubBook book) {
  for (var i = 0; i < book.readingOrder.length; i++) {
    if (EpubCfiDocument.parse(_htmlOf(book, i).content).text.length > 2000) {
      return i;
    }
  }
  throw StateError('fixture has no section with running text');
}

TextFile _htmlOf(final EpubBook book, final int contentIndex) {
  final section = book.readingOrder[contentIndex];
  for (final file in book.files.html) {
    if (file.path == section.name) {
      return file;
    }
  }
  throw StateError('missing HTML file for ${section.name}');
}
