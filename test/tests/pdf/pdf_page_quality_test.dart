import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/unseal.dart';

import 'pdf_fixture_builder.dart';

void main() {
  test('reports readable, empty, and partial page extraction from actual streams', () {
    final readable = parsePdfBook(_textPdf('BT /F1 12 Tf 72 700 Td (Readable) Tj ET'));
    expect(readable.pageTexts.single.quality, PdfTextQuality.readable);
    expect(readable.pageTexts.single.contentStreamCount, 1);
    expect(readable.pageTexts.single.skippedContentStreams, 0);

    final empty = parsePdfBook(twoPageFixture().build());
    expect(empty.pageTexts.map((final page) => page.quality), [
      PdfTextQuality.noExtractedText,
      PdfTextQuality.noExtractedText,
    ]);

    final partial = textPageFixture()
      ..addObject(
        5,
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Contents [7 0 R 13 0 R] '
        '/Resources << /Font << /F1 9 0 R /F2 10 0 R >> >> >>',
      )
      ..addStreamObject(13, ' /Filter /UnsupportedFilter', [1, 2, 3]);
    final page = parsePdfBook(partial.build()).pageTexts.single;
    expect(page.quality, PdfTextQuality.partial);
    expect(page.contentStreamCount, 2);
    expect(page.skippedContentStreams, 1);
    expect(page.text, contains('Hello world'));
  });

  test('recognizes an image placement without claiming OCR or a text layer', () {
    final fixture = PdfFixtureBuilder()
      ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
      ..addObject(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>')
      ..addObject(
        3,
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 5 0 R '
        '/Resources << /XObject << /Im0 6 0 R >> >> >>',
      )
      ..addStreamObject(5, '', 'q 100 0 0 100 0 0 cm /Im0 Do Q'.codeUnits)
      ..addStreamObject(
        6,
        ' /Type /XObject /Subtype /Image /Width 1 /Height 1 '
        '/ColorSpace /DeviceGray /BitsPerComponent 8',
        [0],
      );
    final book = parsePdfBook(fixture.build());

    expect(book.hasTextLayer, isFalse);
    expect(book.pageTexts.single.quality, PdfTextQuality.imageWithoutText);
    expect(book.pageTexts.single.images, isNotEmpty);
  });

  test('reorders clearly separated text columns in reflow and canonical text', () {
    final book = parsePdfBook(
      _textPdf(
        'BT /F1 12 Tf 72 700 Td (Left one has enough prose) Tj ET\n'
        'BT /F1 12 Tf 330 700 Td (Right one has enough prose) Tj ET\n'
        'BT /F1 12 Tf 72 680 Td (Left two has enough prose) Tj ET\n'
        'BT /F1 12 Tf 330 680 Td (Right two has enough prose) Tj ET\n'
        'BT /F1 12 Tf 72 660 Td (Left three has enough prose) Tj ET\n'
        'BT /F1 12 Tf 330 660 Td (Right three has enough prose) Tj ET',
      ),
    );
    final page = book.pageTexts.single;

    expect(page.columnOrderApplied, isTrue);
    expect(
      page.text,
      'Left one has enough prose\nLeft two has enough prose\nLeft three has enough prose\n'
      'Right one has enough prose\nRight two has enough prose\nRight three has enough prose',
    );
    expect(
      book.files.html.single.content.indexOf('Left three has enough prose'),
      lessThan(book.files.html.single.content.indexOf('Right one has enough prose')),
    );
    expect(DocumentTextScanner(book.files.html.single.content).scan(), page.text);

    final (json, blobs) = encodeBookWire(book);
    final restored = decodeBookWire(json, blobs) as PdfBook;
    expect(restored.pageTexts.single.text, page.text);
    expect(restored.pageTexts.single.columnOrderApplied, isTrue);
    expect(restored.pageTexts.single.contentStreamCount, 1);
  });

  test('keeps geometric order for a single indented column', () {
    final page = parsePdfBook(
      _textPdf(
        'BT /F1 12 Tf 72 700 Td (First) Tj ET\n'
        'BT /F1 12 Tf 140 680 Td (Indented) Tj ET\n'
        'BT /F1 12 Tf 72 660 Td (Last) Tj ET',
      ),
    ).pageTexts.single;

    expect(page.columnOrderApplied, isFalse);
    expect(page.text, 'First\nIndented\nLast');
  });

  test('keeps short two-cell table rows in row order', () {
    final page = parsePdfBook(
      _textPdf(
        'BT /F1 12 Tf 72 700 Td (A1) Tj ET\n'
        'BT /F1 12 Tf 330 700 Td (B1) Tj ET\n'
        'BT /F1 12 Tf 72 680 Td (A2) Tj ET\n'
        'BT /F1 12 Tf 330 680 Td (B2) Tj ET\n'
        'BT /F1 12 Tf 72 660 Td (A3) Tj ET\n'
        'BT /F1 12 Tf 330 660 Td (B3) Tj ET',
      ),
    ).pageTexts.single;

    expect(page.columnOrderApplied, isFalse);
    expect(page.text, 'A1 B1\nA2 B2\nA3 B3');
  });
}

Uint8List _textPdf(final String content) =>
    (PdfFixtureBuilder()
          ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
          ..addObject(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>')
          ..addObject(
            3,
            '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R '
            '/Resources << /Font << /F1 9 0 R >> >> >>',
          )
          ..addStreamObject(5, '', content.codeUnits)
          ..addObject(9, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'))
        .build();
