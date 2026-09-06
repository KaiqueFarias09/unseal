import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/src/features/pdf/header/pdf_document.dart';
import 'package:e_livre/src/features/pdf/header/pdf_object.dart';
import 'package:e_livre/src/features/pdf/reader/pdf_content_stream.dart';
import 'package:e_livre/src/features/pdf/reader/pdf_page_tree.dart';
import 'package:e_livre/src/features/pdf/utils/pdf_bitmap.dart';
import 'package:e_livre/src/features/pdf/utils/pdf_ccitt.dart';
import 'package:e_livre/src/features/pdf/utils/pdf_stream_filters.dart';
import 'package:test/test.dart';

import 'pdf_fixture_builder.dart';

void main() {
  group('decodeCcittFax (Group 3 1D)', () {
    test('decodes runs MSB first and pads rows to whole bytes', () {
      // Two rows of 10 columns, each 3 white / 4 black / 3 white.
      // Expected bytes are pdf.js's own output (BlackIs1 convention),
      // captured through tool/reference/_ccitt_expect.mjs.
      final decoded = decodeCcittFax(
        Uint8List.fromList([135, 16, 224]),
        const PdfDictionary({'K': PdfNumber(0), 'Columns': PdfNumber(10)}),
        (final object) => object,
      );
      expect(decoded, hasLength(3));
      expect(decoded, <int>[0xE1, 0xC0, 0xE1]);
    });

    test('decodes G3 1D through decodePdfStream end to end', () {
      final bytes = _ccittFixture(
        imageEntries:
            '/Width 10 /Height 2 /ColorSpace /DeviceGray '
            '/BitsPerComponent 1 /Filter /CCITTFaxDecode',
        decodeParms: '<< /K 0 /Columns 10 /Rows 2 >>',
        data: Uint8List.fromList([135, 16, 224]),
      );
      final document = PdfDocument.parse(bytes);
      final stream = document.resolve(const PdfIndirectRef(6, 0)) as PdfStream;
      final packed = decodePdfStream(stream, document.resolve);
      // pdf.js oracle bytes: row 1 plus row 2's first byte (the EOF
      // fires before row 2's tail pixels leave the decoder).
      expect(packed, <int>[0xE1, 0xC0, 0xE1]);

      final bitmap = PdfBitmap.fromPacked(width: 10, height: 2, packed: packed);
      final gray = bitmap.toGrayBytes();
      expect(bitmap.width, 10);
      expect(bitmap.height, 2);
      // Row 1 pattern: 3 white (255), 4 black (0), 3 white (255).
      expect(gray.sublist(0, 10), <int>[255, 255, 255, 0, 0, 0, 0, 255, 255, 255]);
    });
  });

  group('decodeCcittFax (Group 3 2D)', () {
    test('decodes K > 0 rows', () {
      // Expected bytes are pdf.js's own output (BlackIs1 convention).
      final rows = decodeCcittFax(
        Uint8List.fromList([67, 143]),
        const PdfDictionary({'K': PdfNumber(1), 'Columns': PdfNumber(10), 'Rows': PdfNumber(2)}),
        (final object) => object,
      );
      expect(rows, hasLength(5));
      expect(rows, <int>[0xFF, 0xC0, 0xFF, 0xC0, 0xE7]);
    });

    test('decodes G3 2D through decodePdfStream end to end', () {
      final bytes = _ccittFixture(
        imageEntries:
            '/Width 10 /Height 2 /ColorSpace /DeviceGray '
            '/BitsPerComponent 1 /Filter /CCITTFaxDecode',
        decodeParms: '<< /K 1 /Columns 10 /Rows 2 >>',
        data: Uint8List.fromList([67, 143]),
      );
      final document = PdfDocument.parse(bytes);
      final stream = document.resolve(const PdfIndirectRef(6, 0)) as PdfStream;
      final packed = decodePdfStream(stream, document.resolve);
      // pdf.js oracle bytes, row-aligned (0 = black convention).
      expect(packed, _g32dOracle);
      final gray = PdfBitmap.fromPacked(width: 10, height: 2, packed: packed).toGrayBytes();
      expect(gray, hasLength(20));
    });
  });

  group('decodeCcittFax (Group 4)', () {
    test('honours EndOfBlock and stops decoding at the EOFB', () {
      // One G4 row (3w/4b/3w via horizontal mode) followed by the EOFB
      // (two EOL codes). pdf.js oracle bytes.
      final parms = const PdfDictionary({
        'K': PdfNumber(-1),
        'Columns': PdfNumber(10),
        'Rows': PdfNumber(1),
      });
      final decoded = decodeCcittFax(
        Uint8List.fromList([48, 224, 0, 64, 4]),
        parms,
        (final object) => object,
      );
      expect(decoded, hasLength(3));
      expect(decoded, <int>[0xE1, 0xC0, 0xFF]);
    });

    test('EndOfBlock false keeps reading to the end of the data', () {
      final parms = const PdfDictionary({
        'K': PdfNumber(-1),
        'Columns': PdfNumber(10),
        'Rows': PdfNumber(1),
        'EndOfBlock': PdfBool(false),
      });
      final decoded = decodeCcittFax(
        Uint8List.fromList([48, 224, 0, 64, 4]),
        parms,
        (final object) => object,
      );
      expect(decoded, <int>[0xE1, 0xC0]);
    });

    test('decodes G4 through decodePdfStream end to end', () {
      final bytes = _ccittFixture(
        imageEntries:
            '/Width 10 /Height 1 /ColorSpace /DeviceGray '
            '/BitsPerComponent 1 /Filter /CCITTFaxDecode',
        decodeParms: '<< /K -1 /Columns 10 /Rows 1 >>',
        data: Uint8List.fromList([48, 224, 0, 64, 4]),
      );
      final document = PdfDocument.parse(bytes);
      final stream = document.resolve(const PdfIndirectRef(6, 0)) as PdfStream;
      final packed = decodePdfStream(stream, document.resolve);
      // pdf.js oracle bytes, row-aligned (0 = black convention).
      expect(packed, <int>[0xE1, 0xC0, 0xFF]);
      final gray = PdfBitmap.fromPacked(width: 10, height: 1, packed: packed).toGrayBytes();
      expect(gray, hasLength(10));
      expect(gray.sublist(0, 10), <int>[255, 255, 255, 0, 0, 0, 0, 255, 255, 255]);
    });
  });

  group('decodeCcittFax parameters', () {
    test('BlackIs1 keeps the output black-as-1 like the default', () {
      // BlackIs1 and the default flip cancel out to the same
      // normalized rows (pdf.js oracle agrees byte for byte).
      final parms = const PdfDictionary({
        'K': PdfNumber(-1),
        'Columns': PdfNumber(10),
        'Rows': PdfNumber(1),
        'BlackIs1': PdfBool(true),
      });
      final decoded = decodeCcittFax(
        Uint8List.fromList([48, 224, 0, 64, 4]),
        parms,
        (final object) => object,
      );
      expect(decoded, <int>[0x1E, 0x3F, 0x00]);
    });

    test('a [1 0] /Decode array inverts like BlackIs1', () {
      final parms = const PdfDictionary({
        'K': PdfNumber(-1),
        'Columns': PdfNumber(10),
        'Rows': PdfNumber(1),
        'Decode': PdfArray(<PdfObject>[PdfNumber(1), PdfNumber(0)]),
      });
      final decoded = decodeCcittFax(
        Uint8List.fromList([48, 224, 0, 64, 4]),
        parms,
        (final object) => object,
      );
      expect(decoded, <int>[0x1E, 0x3F, 0x00]);
    });

    test('EncodedByteAlign re-aligns rows to byte boundaries', () {
      // Two identical byte-aligned G4 rows (pdf.js oracle bytes).
      final parms = const PdfDictionary({
        'K': PdfNumber(-1),
        'Columns': PdfNumber(10),
        'Rows': PdfNumber(2),
        'EncodedByteAlign': PdfBool(true),
      });
      final decoded = decodeCcittFax(
        Uint8List.fromList([48, 224, 48, 224]),
        parms,
        (final object) => object,
      );
      expect(decoded, hasLength(3));
      expect(decoded, <int>[0xE1, 0xC0, 0xE1]);
    });

    test('EndOfBlock ends the stream even with Rows left', () {
      // Rows=4 does not pad the output: the EOFB terminates first
      // (pdf.js oracle bytes).
      final parms = const PdfDictionary({
        'K': PdfNumber(-1),
        'Columns': PdfNumber(10),
        'Rows': PdfNumber(4),
      });
      final decoded = decodeCcittFax(
        Uint8List.fromList([48, 224, 0, 64, 4]),
        parms,
        (final object) => object,
      );
      expect(decoded, <int>[0xE1, 0xC0, 0xFF]);
    });

    test('empty input produces the degenerate white row pdf.js emits', () {
      final decoded = decodeCcittFax(
        Uint8List(0),
        const PdfDictionary({'K': PdfNumber(-1), 'Columns': PdfNumber(10)}),
        (final object) => object,
      );
      expect(decoded, <int>[0xFF]);
    });

    test('follows indirect DecodeParms references', () {
      final bytes = _ccittFixture(
        imageEntries:
            '/Width 10 /Height 1 /ColorSpace /DeviceGray '
            '/BitsPerComponent 1 /Filter /CCITTFaxDecode',
        decodeParms: '8 0 R',
        data: Uint8List.fromList([48, 224, 0, 64, 4]),
        extraObjects: {8: '<< /K -1 /Columns 10 /Rows 1 >>'},
      );
      final document = PdfDocument.parse(bytes);
      final stream = document.resolve(const PdfIndirectRef(6, 0)) as PdfStream;
      final packed = decodePdfStream(stream, document.resolve);
      expect(packed, hasLength(3));
      expect(packed[0], 0xE1);
    });
  });

  group('CCITT reference fixtures (pdf.js corpus)', () {
    for (final name in _placedImageFixtures.keys) {
      test('decodes every CCITT image drawn in $name', () {
        final bytes = _fixtureBytes(name);
        final document = PdfDocument.parse(bytes);
        final captured = <int, Uint8List>{};
        final extractor = PdfTextExtractor(document);
        for (final page in PdfPageTree.parse(document)) {
          extractor.extract(
            page,
            onImage: (final objectNumber, final imageBytes, final extension) {
              captured[objectNumber] = imageBytes;
            },
          );
        }
        final expected = _placedImageFixtures[name]!;
        expect(captured, isNotEmpty, reason: '$name should place its images');
        expect(captured.keys.toSet(), expected.toSet(), reason: '$name image object numbers');
        for (final number in captured.keys) {
          expect(
            captured[number]!.sublist(0, 8),
            _pngSignature,
            reason: '$name obj $number should be a PNG',
          );
        }
      });
    }

    test('fixture images decode to their dictionary dimensions', () {
      for (final name in _resourceFixtureDims.keys) {
        final document = PdfDocument.parse(_fixtureBytes(name));
        final xobjects = _resourceImages(document);
        expect(xobjects, isNotEmpty, reason: '$name should carry image XObjects');
        for (final entry in xobjects.entries) {
          final stream = document.resolve(entry.value);
          if (stream is! PdfStream) continue;
          final width = _intValue(document, stream, 'Width', 'W');
          final height = _intValue(document, stream, 'Height', 'H');
          final packed = decodePdfStream(stream, document.resolve);
          final bitmap = PdfBitmap.fromPacked(width: width, height: height, packed: packed);
          expect(bitmap.width, width, reason: '$name obj ${entry.key} width');
          expect(bitmap.height, height, reason: '$name obj ${entry.key} height');
          final png = bitmap.toPngBytes();
          expect(png.sublist(0, 8), _pngSignature, reason: '$name obj ${entry.key} PNG');
        }
      }
    });
  });
}

const List<int> _pngSignature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// The pdf.js oracle bytes for the G3 2D fixture (BlackIs1 output),
/// emitted by tool/reference/_ccitt_expect.mjs.
const List<int> _g32dOracle = <int>[0xFF, 0xC0, 0xFF, 0xC0, 0xE7];

/// Expands [from]..[from + count) oracle bytes to gray values: bit 1
/// codes white, matching the decode contract.
List<int> oracleInverse(final List<int> bytes, final int from, final int count) {
  final out = <int>[];
  for (var i = 0; i < count; i++) {
    final byte = bytes[from + (i >> 3)];
    final bit = (byte >> (7 - (i & 7))) & 1;
    out.add(bit == 1 ? 255 : 0);
  }
  return out;
}

int _intValue(
  final PdfDocument document,
  final PdfStream stream,
  final String long,
  final String short,
) {
  final value = document.resolve(
    stream.dictionary[long] ?? stream.dictionary[short] ?? const PdfNull(),
  );
  if (value is PdfNumber) return value.intValue;
  return 0;
}

/// The image XObjects of every page's resource dictionary, keyed by
/// object number.
Map<int, PdfObject> _resourceImages(final PdfDocument document) {
  final images = <int, PdfObject>{};
  for (final page in PdfPageTree.parse(document)) {
    final resources = document.resolve(page.resources);
    if (resources is! PdfDictionary) continue;
    final xobjects = document.resolve(resources['XObject']);
    if (xobjects is! PdfDictionary) continue;
    for (final entry in xobjects.entries.entries) {
      final stream = document.resolve(entry.value);
      if (stream is! PdfStream) continue;
      final subtype = document.resolve(stream.dictionary['Subtype']);
      if (subtype is! PdfName || subtype.value != 'Image') continue;
      final number = entry.value is PdfIndirectRef
          ? (entry.value as PdfIndirectRef).objectNumber
          : 0;
      if (number != 0) images[number] = entry.value;
    }
  }
  return images;
}

/// Builds a one-page minimal PDF wrapping a CCITT image stream as
/// object 6 with an 8 0 R style indirect params option.
Uint8List _ccittFixture({
  required final String imageEntries,
  required final String decodeParms,
  required final List<int> data,
  final Map<int, String> extraObjects = const <int, String>{},
}) {
  final builder = PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [3 0 R] /Count 1 >>')
    ..addObject(
      3,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 5 0 R '
      '/Resources << /XObject << /Im0 6 0 R >> >> >>',
    )
    ..addStreamObject(5, '', Uint8List.fromList('q 100 0 0 100 0 0 cm /Im0 Do Q\n'.codeUnits))
    ..addStreamObject(6, '$imageEntries /DecodeParms $decodeParms', data);
  extraObjects.forEach(builder.addObject);
  return builder.build();
}

/// Fixtures whose CCITT images are actually drawn on a page, mapped
/// to the object numbers the extractor places.
const Map<String, List<int>> _placedImageFixtures = <String, List<int>>{
  'ccitt_EndOfBlock_false.pdf': <int>[6, 7, 8, 9, 10, 11],
};

/// Fixtures carrying CCITT images in their page resources (drawn or
/// not), with their expected dictionary dimensions. The placed-image
/// case above already covers ccitt_EndOfBlock_false.pdf.
const Map<String, (int, int)> _resourceFixtureDims = <String, (int, int)>{
  'issue4379.pdf': (1000, 800),
  'issue13372.pdf': (646, 761),
};

/// Resources are resolved through `page.resources`, so the fixture
/// bytes only need to parse.
final Map<String, Uint8List> _fixtureCache = <String, Uint8List>{};

Uint8List _fixtureBytes(final String name) {
  return _fixtureCache.putIfAbsent(name, () {
    final file = File('test/resources/pdf/reference/ccitt/$name');
    return file.readAsBytesSync();
  });
}
