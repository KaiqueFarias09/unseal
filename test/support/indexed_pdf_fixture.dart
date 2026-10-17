import 'dart:typed_data';

import '../tests/pdf/pdf_fixture_builder.dart';

/// A PDF beyond the session's 20-page sample with stable body text.
Uint8List indexedPdfFixture() {
  final builder = PdfFixtureBuilder();
  builder.addObject(1, '<< /Type /Catalog /Pages 2 0 R >>');
  builder.addObject(
    2,
    '<< /Type /Pages /Count 22 /Kids [${[for (var page = 0; page < 22; page++) '${4 + page * 2} 0 R'].join(' ')}] >>',
  );
  builder.addObject(3, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  for (var page = 0; page < 22; page++) {
    final pageObject = 4 + page * 2;
    builder.addObject(
      pageObject,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 3 0 R >> >> /Contents ${pageObject + 1} 0 R >>',
    );
    builder.addStreamObject(
      pageObject + 1,
      '',
      'BT /F1 12 Tf 60 400 Td (Selected needle on page ${page + 1}.) Tj ET'.codeUnits,
    );
  }
  return builder.build();
}
