import 'dart:typed_data';

import 'package:e_livre/src/features/azw4/exceptions/azw4_exception.dart';
import 'package:e_livre/src/features/azw4/utils/azw4_pdf_extractor.dart';
import 'package:e_livre/src/features/azw4/utils/parse_azw4_book.dart';
import 'package:e_livre/src/features/pdf/entities/pdf_book.dart';
import 'package:e_livre/src/foundation/entities/book_format.dart';
import 'package:test/test.dart';

import '../mobi/mobi_fixture_builder.dart';
import '../pdf/pdf_fixture_builder.dart';

void main() {
  final pdf = textPageFixture().build();

  test('parses a synthetic AZW4 and keeps the extracted PDF for the viewer', () {
    final bytes = buildPdb('Synthetic AZW4', <Uint8List>[
      buildMobiRecord0(title: 'Palm title'),
      pdf,
    ]);

    final book = parseAzw4Book(bytes);

    expect(book, isA<PdfBook>());
    expect(book.format, BookFormat.azw4);
    expect(book.metadata.format, BookFormat.azw4);
    expect(book.metadata.title, 'Text Page');
    expect(book.bytes, orderedEquals(pdf));
    expect(book.pageCount, 1);
  });

  test('extracts a PDF split over multiple PalmDB records', () {
    final split = pdf.length ~/ 2;
    final bytes = buildPdb('Split AZW4', <Uint8List>[
      buildMobiRecord0(title: 'Split title'),
      Uint8List.sublistView(pdf, 0, split),
      Uint8List.sublistView(pdf, split),
    ]);

    expect(extractAzw4Pdf(bytes), orderedEquals(pdf));
  });

  test('accepts a bounded preamble before a direct PDF signature', () {
    final bytes = Uint8List.fromList(<int>[0xEF, 0xBB, 0xBF, 0x20, ...pdf]);

    expect(extractAzw4Pdf(bytes), orderedEquals(pdf));
  });

  test('rejects a valid PalmDB/MOBI wrapper without a PDF', () {
    final bytes = buildPdb('No PDF', <Uint8List>[
      buildMobiRecord0(title: 'No PDF title'),
      Uint8List.fromList('not a pdf'.codeUnits),
    ]);

    expect(() => extractAzw4Pdf(bytes), throwsA(isA<Azw4PdfNotFoundException>()));
  });

  test('rejects DRM-protected MOBI wrappers before looking for a PDF', () {
    final bytes = buildPdb('DRM AZW4', <Uint8List>[buildMobiRecord0(encryptionType: 1), pdf]);

    expect(() => extractAzw4Pdf(bytes), throwsA(isA<Azw4DrmProtectedException>()));
  });
}
