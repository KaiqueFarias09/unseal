import 'package:test/test.dart';
import 'package:unseal/src/features/pdf/text/pdf_standard_widths.dart';
import 'package:unseal/unseal.dart';

import 'pdf_fixture_builder.dart';

void main() {
  group('standard-14 width tables', () {
    test('carries every canonical BaseFont with 256 entries', () {
      const names = <String>[
        '/Courier',
        '/Courier-Bold',
        '/Courier-Oblique',
        '/Courier-BoldOblique',
        '/Helvetica',
        '/Helvetica-Bold',
        '/Helvetica-Oblique',
        '/Helvetica-BoldOblique',
        '/Times-Roman',
        '/Times-Bold',
        '/Times-Italic',
        '/Times-BoldItalic',
        '/Symbol',
        '/ZapfDingbats',
      ];
      for (final name in names) {
        expect(pdfStandard14Widths[name], isNotNull, reason: name);
        expect(pdfStandard14Widths[name]!.length, 256, reason: name);
      }
    });

    test('Courier is monospaced across the ASCII range', () {
      final row = pdfStandard14Widths['/Courier']!;
      for (var code = 32; code <= 126; code++) {
        expect(row[code], 600, reason: 'code $code');
      }
    });

    test('fixes spot widths against the Adobe AFM data', () {
      // Space, A, H, a, e and tilde for Helvetica.
      final helvetica = pdfStandard14Widths['/Helvetica']!;
      expect(helvetica[32], 278);
      expect(helvetica[65], 667);
      expect(helvetica[72], 722);
      expect(helvetica[97], 556);
      expect(helvetica[101], 556);
      expect(helvetica[126], 584);
      // Times-Roman space and a.
      final times = pdfStandard14Widths['/Times-Roman']!;
      expect(times[32], 250);
      expect(times[65], 722);
      expect(times[97], 444);
      expect(pdfStandard14Widths['/Helvetica-Bold']![65], 722);
      expect(pdfStandard14Widths['/Symbol']![65], 722);
      expect(pdfStandard14Widths['/ZapfDingbats']![97], 789);
      // Codes outside the AFM char metrics stay unmapped.
      expect(helvetica[31], isNull);
      expect(helvetica[127], isNull);
    });
  });

  group('standard-14 measurement without /Widths', () {
    late PdfBook book;

    setUp(() {
      book = parsePdfBook(standardFontPageFixture().build());
    });

    test('measures "Hello" from the AFM row of Helvetica', () {
      final line = book.pageTexts.single.lines.single;

      expect(line.text, 'Hello');
      final row = pdfStandard14Widths['/Helvetica']!;
      const codes = <int>[72, 101, 108, 108, 111];
      var glyphUnits = 0;
      for (final code in codes) {
        glyphUnits += row[code] ?? 0;
      }
      // Width in points: glyph units / 1000 em x font size.
      expect(line.width, closeTo(glyphUnits / 1000 * 12, 0.01));
      expect(glyphUnits, 2278);
    });
  });

  group('Type0 font with an embedded /Encoding CMap', () {
    late PdfBook book;

    setUp(() {
      book = parsePdfBook(type0CMapPageFixture().build());
    });

    test('decodes one-byte codes through ToUnicode to "ABC"', () {
      expect(book.pageTexts.single.text, 'ABC');
    });

    test('measures /W by CID, not by code', () {
      final line = book.pageTexts.single.lines.single;

      // CIDs 500-502 carry widths 600, 700 and 800: (2100/1000) x 12.
      // A lookup keyed by the raw code (65-67) would miss and fall
      // back to /DW 500 for every glyph (18.0 instead).
      expect(line.width, closeTo(2100 / 1000 * 12, 0.01));
    });
  });
}
