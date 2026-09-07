import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/platform/web/book_wire.dart';
import 'package:test/test.dart';

import 'pdf_fixture_builder.dart';

void main() {
  group('PDF structure (classic xref)', () {
    test('parses pages, geometry and metadata', () {
      final book = parsePdfBook(twoPageFixture().build());

      expect(book.format, BookFormat.pdf);
      expect(book.pageCount, 2);
      expect(book.pages.first.mediaBox, [0, 0, 612, 792]);
      expect(book.pages.first.width, 612);
      expect(book.pages.first.height, 792);
      expect(book.pages[1].rotate, 90);
      expect(book.metadata.title, "Alice's Adventures in Wonderland");
      expect(book.metadata.authors, ['Lewis Carroll', 'John Tenniel']);
      expect(book.metadata.bookProducer, 'fixture writer');
      expect(book.metadata.subjects, containsAll(['classic', 'fiction']));
      expect(book.metadata.isbn, '9783161484100');
      expect(book.metadata.publishedAt, DateTime.parse('1865-11-26T09:00:00+01:00'));
      expect(book.hasTextLayer, isFalse);
    });

    test('reads the outline into page anchors', () {
      final book = parsePdfBook(twoPageFixture().build());

      expect(book.navigation.navPoints, hasLength(2));
      expect(book.navigation.navPoints.first.label, 'Chapter One');
      expect(book.navigation.navPoints.first.content, 'page_1.html#page_1');
      expect(book.navigation.navPoints[1].content, 'page_2.html#page_2');
    });

    test('metadata-only read skips the page walk', () {
      final metadata = readPdfMetadata(twoPageFixture(withOutline: false).build());

      expect(metadata.format, BookFormat.pdf);
      expect(metadata.title, "Alice's Adventures in Wonderland");
    });

    test('flows through BookReader.parseBook', () {
      final book = BookReader.parseBook(twoPageFixture().build());

      expect(book, isA<PdfBook>());
      expect(book.format, BookFormat.pdf);
    });
  });

  group('PDF structure (xref stream + object stream)', () {
    test('parses compressed cross-reference and packed objects', () {
      final fixture = PdfFixtureBuilder()
        ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
        ..addObject(2, '<< /Type /Pages /Kids [4 0 R 5 0 R] /Count 2 >>')
        ..addObject(3, '<</Title (Stream Alice) /Author (Lewis Carroll)>>')
        ..trailerExtra = ' /Info 3 0 R'
        ..addCompressedObject(
          4,
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 6 0 R /Resources << >> >>',
        )
        ..addCompressedObject(
          5,
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 7 0 R /Resources << >> >>',
        )
        ..addStreamObject(6, '', 'BT ET'.codeUnits, flate: true)
        ..addStreamObject(7, '', 'BT ET'.codeUnits, flate: true);

      final book = parsePdfBook(fixture.buildWithXrefStream());

      expect(book.pageCount, 2);
      expect(book.pages.first.objectNumber, 4);
      expect(book.pages.first.width, 595);
      expect(book.metadata.title, 'Stream Alice');
      expect(book.metadata.authors, ['Lewis Carroll']);
    });
  });

  group('PDF robustness', () {
    test('encrypted documents throw PdfEncryptedException', () {
      final fixture = twoPageFixture(withOutline: false)
        ..addObject(10, '<< /Filter /Standard /V 1 >>')
        ..trailerExtra = ' /Info 3 0 R /Encrypt 10 0 R';

      expect(() => parsePdfBook(fixture.build()), throwsA(isA<PdfEncryptedException>()));
    });

    test('broken xref falls back to scanning objects', () {
      final fixture = twoPageFixture(withOutline: false)..corruptXref = true;

      final book = parsePdfBook(fixture.build());

      expect(book.pageCount, 2);
      expect(book.metadata.title, "Alice's Adventures in Wonderland");
    });

    test('documents without pages throw PdfException', () {
      final fixture = PdfFixtureBuilder()
        ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
        ..addObject(2, '<< /Type /Pages /Kids [] /Count 0 >>');

      expect(() => parsePdfBook(fixture.build()), throwsA(isA<PdfException>()));
    });
  });

  group('PDF header preamble', () {
    test('accepts a bounded UTF-8 BOM and ASCII whitespace', () {
      final fixture = twoPageFixture(withOutline: false)
        ..prefix = [0xEF, 0xBB, 0xBF, 0x0A, 0x20, 0x09, 0x0C, 0x0D];
      final bytes = fixture.build();

      final book = parsePdfBook(bytes);

      expect(book.pageCount, 2);
      expect(book.bytes, bytes);
    });

    test('rejects arbitrary or overlong bytes before the PDF header', () {
      final garbage = twoPageFixture(withOutline: false)..prefix = 'generated\n'.codeUnits;
      final overlong = twoPageFixture(withOutline: false)..prefix = List<int>.filled(1025, 0x20);

      expect(() => parsePdfBook(garbage.build()), throwsA(isA<PdfException>()));
      expect(() => parsePdfBook(overlong.build()), throwsA(isA<PdfException>()));
    });
  });

  group('PDF wire', () {
    test('round-trips bytes, pages, metadata and navigation', () {
      final book = parsePdfBook(twoPageFixture().build());
      book.files.html; // exercise the Files build

      final (json, blobs) = encodeBookWire(book);
      final decoded = decodeBookWire(json, blobs);

      final pdf = decoded as PdfBook;
      expect(pdf.format, BookFormat.pdf);
      expect(pdf.pageCount, 2);
      expect(pdf.bytes, book.bytes);
      expect(pdf.pages[1].rotate, 90);
      expect(pdf.pages[1].mediaBox, book.pages[1].mediaBox);
      expect(pdf.metadata.title, book.metadata.title);
      expect(pdf.metadata.isbn, '9783161484100');
      expect(pdf.navigation.navPoints, hasLength(2));
      expect(pdf.navigation.navPoints[1].content, 'page_2.html#page_2');
      expect(pdf.hasTextLayer, isFalse);
    });
  });
}
