import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/platform/web/book_wire.dart';
import 'package:test/test.dart';

import 'pdf_fixture_builder.dart';

void main() {
  group('PDF text extraction', () {
    late PdfBook book;

    setUp(() {
      book = parsePdfBook(textPageFixture().build());
    });

    test('extracts lines in reading order with canonical text', () {
      final page = book.pageTexts.single;

      expect(
        page.text,
        'Hello world\n'
        'Thequick\n'
        'First\n'
        'Second\n'
        'Left Right\n'
        'Hi',
      );
    });

    test('maps PDF-space geometry to the top-left pixel space', () {
      final first = book.pageTexts.single.lines.first;

      // Baseline at 720 inside a 792-point page: the visual top sits
      // ~0.8 em above the baseline.
      expect(first.x, closeTo(72, 0.01));
      expect(first.y, closeTo(792 - 720 - 12 * 0.8, 0.01));
      expect(first.fontSize, closeTo(12, 0.01));
      // Helvetica fallback average: 11 chars x 0.556 em x 12 pt.
      expect(first.width, closeTo(11 * 0.556 * 12, 1.5));
    });

    test('kerning inside TJ stays on one line without a join space', () {
      final kerned = book.pageTexts.single.lines[1];

      expect(kerned.text, 'Thequick');
    });

    test('wide run gaps join with a single space', () {
      final joined = book.pageTexts.single.lines[4];

      expect(joined.text, 'Left Right');
      expect(joined.x, closeTo(72, 0.01));
    });

    test('decodes Type0 text through the ToUnicode CMap', () {
      final cid = book.pageTexts.single.lines.last;

      expect(cid.text, 'Hi');
      expect(cid.y, closeTo(792 - 600 - 12 * 0.8, 0.01));
    });

    test('reports a text layer', () {
      expect(book.hasTextLayer, isTrue);
    });

    test('empty pages keep their slot and report no text', () {
      final empty = parsePdfBook(twoPageFixture().build());

      expect(empty.pageTexts, hasLength(2));
      expect(empty.pageTexts.every((final page) => page.lines.isEmpty), isTrue);
      expect(empty.hasTextLayer, isFalse);
    });

    test('broken content streams degrade per page, not per book', () {
      final fixture = textPageFixture()..corruptXref = true;
      final recovered = parsePdfBook(fixture.build());

      expect(recovered.pageTexts.single.text, contains('Hello world'));
    });
  });

  group('PDF text wire', () {
    test('round-trips the canonical lines', () {
      final book = parsePdfBook(textPageFixture().build());
      final (json, blobs) = encodeBookWire(book);
      final decoded = decodeBookWire(json, blobs) as PdfBook;

      expect(decoded.pageTexts, hasLength(1));
      final lines = decoded.pageTexts.single.lines;
      expect(lines, hasLength(6));
      expect(lines.first.text, 'Hello world');
      expect(lines.first.x, closeTo(72, 0.01));
      expect(lines.first.y, closeTo(book.pageTexts.single.lines.first.y, 0.001));
      expect(lines.first.fontSize, closeTo(12, 0.01));
      expect(lines.last.text, 'Hi');
      expect(decoded.hasTextLayer, isTrue);
    });
  });
}
