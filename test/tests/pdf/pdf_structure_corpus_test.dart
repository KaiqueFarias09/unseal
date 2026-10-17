import 'dart:io';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

/// The structure layer against the real corpus: licensed Project
/// Gutenberg books produced outside this package's builders, several
/// far beyond the 20-page session sample — see
/// `test/resources/pdf/gutenberg/MANIFEST.md`.
void main() {
  final corpusDir = Directory('test/resources/pdf/gutenberg');
  if (!corpusDir.existsSync()) {
    fail('missing $corpusDir; run `dart run tool/fetch_pdf_corpus.dart`');
  }
  final books =
      corpusDir
          .listSync()
          .whereType<File>()
          .where((final file) => file.path.endsWith('.pdf'))
          .toList()
        ..sort((final a, final b) => a.path.compareTo(b.path));
  if (books.isEmpty) {
    fail('empty $corpusDir; run `dart run tool/fetch_pdf_corpus.dart`');
  }

  group('Gutenberg corpus structures', () {
    late File longBook;

    setUpAll(() {
      longBook = books.firstWhere(
        (final file) => parsePdfBook(file.readAsBytesSync()).pageCount > 20,
        orElse: () => throw StateError('the corpus must carry a book over 20 pages'),
      );
    });

    test('every book builds structures with words and blocks', () {
      for (final file in books) {
        final book = parsePdfBook(file.readAsBytesSync());
        final mid = book.pageCount ~/ 2;
        final structure = buildPdfPageStructure(book: book, pageIndex: mid);
        expect(structure.pageIndex, mid, reason: file.path);
        expect(structure.canonicalText, book.pageTexts[mid].text, reason: file.path);
        expect(structure.geometry.width, greaterThan(0), reason: file.path);
        expect(structure.geometry.transformInvertible, isTrue, reason: file.path);
        // cupsfilter pages are dense text: words and blocks exist.
        expect(structure.words, isNotEmpty, reason: file.path);
        expect(structure.blocks, isNotEmpty, reason: file.path);
      }
    });

    test('a body anchor maps exactly in a book beyond the 20-page sample', () {
      final book = parsePdfBook(longBook.readAsBytesSync());
      expect(book.pageCount, greaterThan(20));

      final index = book.pageCount - 1;
      final structure = buildPdfPageStructure(book: book, pageIndex: index);
      expect(structure.sourceLines, isNotEmpty);

      final line = structure.sourceLines.first;
      final anchor = PdfSourceRange(
        pageIndex: index,
        lineIndex: 0,
        start: 0,
        end: line.text.length,
        expectedLineText: line.text,
      );
      final mapping = structure.mapSourceRange(anchor);
      expect(mapping, isA<PdfPositionMapped>(), reason: longBook.path);
      final position = (mapping as PdfPositionMapped).position;
      expect(
        structure.canonicalText.substring(position.offset, position.end),
        line.text,
        reason: longBook.path,
      );
    });

    test('reopening the same file mints the same profiles and structures', () {
      final bytes = longBook.readAsBytesSync();
      final first = buildPdfPageStructure(book: parsePdfBook(bytes), pageIndex: 3);
      final second = buildPdfPageStructure(book: parsePdfBook(bytes), pageIndex: 3);

      expect(first.canonicalProfile.id, second.canonicalProfile.id);
      expect(first.canonicalText, second.canonicalText);
      expect(
        [for (final block in first.blocks) block.text],
        [for (final block in second.blocks) block.text],
      );
    });

    test('every word resolves to a source line range on a text page', () {
      final book = parsePdfBook(books.first.readAsBytesSync());
      final structure = buildPdfPageStructure(book: book, pageIndex: 1);
      var ranged = 0;
      for (var i = 0; i < structure.words.length; i++) {
        if (structure.wordSourceLine(i) != null) {
          expect(structure.wordSourceRange(i), isNotNull, reason: 'word $i');
          ranged++;
        }
      }
      expect(
        ranged,
        greaterThanOrEqualTo(structure.words.length * 9 ~/ 10),
        reason: 'nearly every word sits in a source line',
      );
    });
  });
}
