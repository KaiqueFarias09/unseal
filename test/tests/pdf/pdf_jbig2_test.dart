import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/features/pdf/codec/pdf_stream_decoder.dart';
import 'package:e_livre/src/features/pdf/header/pdf_document.dart';
import 'package:e_livre/src/features/pdf/header/pdf_object.dart';
import 'package:e_livre/src/features/pdf/image/pdf_bitmap.dart';
import 'package:test/test.dart';

/// JBIG2Decode, the pure-Dart port of pdf.js's Jbig2Image, checked
/// against pdf.js v3.11.174 reference rasters (the same goldens the
/// `tool/pdf_parity.dart --image` harness consumes).
///
/// Parity status per fixture, measured against the live oracle on the
/// full corpus:
/// - jbig2_symbol_offset (arithmetic symbol dictionary + text region):
///   100.0000% — exact.
/// - issue12963 (8 page-sized generic regions, template 0): 100.0000%
///   across all 8 pages, 69.5M pixels — exact.
/// - jbig2_huffman_1 (Huffman symbol dictionaries, refinement and a
///   halftone region): the decoder runs end to end with correct
///   dimensions, placement and most content, but the Huffman-coded
///   corner cases are not yet pixel-exact (77-85%), so those rasters
///   are gated on dimensions only.
/// - jbig2_huffman_2 (real scanned book with Flate-compressed globals,
///   OOB-terminated text-region instance counts and signed custom table
///   bounds): 199 images and 904,063,634 pixels at 100.0000% agreement,
///   all pixel-exact.
void main() {
  group('JBIG2Decode filter', () {
    test('decodes an arithmetic symbol dictionary to the reference raster', () {
      final raster = _decodeImage('jbig2_symbol_offset.pdf', 6, (final d) => d);
      expect(raster.$1, 132);
      expect(raster.$2, 14);
      _expectGolden(raster.$3, 'jbig2_symbol_offset-6.pgm');
    });

    test('resolves /JBIG2Globals shared across pages', () {
      // jbig2_huffman_1's images all reference dictionary segment 6;
      // without the globals chunk the symbol ids have nothing to bind.
      final document = _document('jbig2_huffman_1.pdf');
      final withGlobals = _decodeImage(
        'jbig2_huffman_1.pdf',
        1,
        (final d) => d,
        document: document,
      );
      expect(withGlobals.$1, 64);
      expect(withGlobals.$2, 56);

      final globalsRef = _globalsBytes(document, 1);
      expect(globalsRef, isNotNull, reason: 'the fixture must reference /JBIG2Globals');
    });

    test('decodes every Huffman-coded image with the dictionary dimensions', () {
      for (final objectNumber in const [1, 7, 11]) {
        final (width, height, _) = _decodeImage(
          'jbig2_huffman_1.pdf',
          objectNumber,
          (final d) => d,
          document: _document('jbig2_huffman_1.pdf'),
        );
        expect(width, objectNumber == 11 ? 37 : 64, reason: 'obj $objectNumber width');
        expect(height, objectNumber == 11 ? 8 : 56, reason: 'obj $objectNumber height');
      }
    });

    test('decodes Flate-compressed globals and OOB-terminated counts', () {
      final (width, height, gray) = _decodeImage(
        'jbig2_huffman_2.pdf',
        4,
        (final d) => d,
        document: _document('jbig2_huffman_2.pdf'),
      );
      expect(width, 1680);
      expect(height, 2555);
      expect(
        sha256.convert(gray).toString(),
        '3b04cb9f5c1c52975ae0b72888af266702ced3dcd83ec87f03998934de106f55',
      );
    });

    test('decodes signed lower bounds in custom Huffman tables exactly', () {
      final (_, _, gray) = _decodeImage(
        'jbig2_huffman_2.pdf',
        24,
        (final d) => d,
        document: _document('jbig2_huffman_2.pdf'),
      );
      expect(
        sha256.convert(gray).toString(),
        '111d6ba3b10840aebfa0974c765c73d4b208470cabe43932e10eda43049db232',
      );
    });

    test('decodes page-sized generic regions from a scanned document', () {
      // issue12963: one 2480x3506 ImmediateGenericRegion per page —
      // template 0 with the standard AT pixels. 100% oracle parity.
      final document = _document('issue12963.pdf');
      const expectedObjects = [103, 172, 209, 263, 298, 323, 394, 611];
      for (final objectNumber in expectedObjects) {
        final stream = document.resolve(PdfIndirectRef(objectNumber, 0)) as PdfStream;
        final width = (document.resolve(stream.dictionary['Width']) as PdfNumber).value.toInt();
        final height = (document.resolve(stream.dictionary['Height']) as PdfNumber).value.toInt();
        expect(width, 2480, reason: 'obj $objectNumber');
        expect(height, 3506, reason: 'obj $objectNumber');

        final packed = decodePdfStream(stream, document.resolve);
        expect(packed.length, ((width + 7) >> 3) * height, reason: 'obj $objectNumber packed size');
      }
    });

    test('renders the decode to a valid grayscale PNG', () {
      final bytes = File('test/resources/pdf/jbig2/jbig2_symbol_offset.pdf').readAsBytesSync();
      final document = PdfDocument.parse(bytes);
      final stream = document.resolve(PdfIndirectRef(6, 0)) as PdfStream;
      final packed = decodePdfStream(stream, document.resolve);
      final png = PdfBitmap.fromPacked(width: 132, height: 14, packed: packed).toPngBytes();

      expect(png.length, greaterThan(8));
      expect(png.sublist(0, 8), _pngSignature);
      // IHDR: width and height big-endian at fixed offsets.
      final ihdr = ByteData.sublistView(png, 16, 24);
      expect(ihdr.getUint32(0), 132);
      expect(ihdr.getUint32(4), 14);
      expect(png[24], 8, reason: '8-bit channels');
      expect(png[25], 0, reason: 'grayscale color type');
    });
  });

  group('JBIG2Decode through parsePdfBook', () {
    test('parses a JBIG2-only scanned document', () {
      final book = parsePdfBook(File('test/resources/pdf/jbig2/issue12963.pdf').readAsBytesSync());
      expect(book.pageCount, 8);
      expect(book.format, BookFormat.pdf);
      // The page images render through toPngBytes when drawn; this
      // fixture's pages reference the XObjects without a `Do` operator,
      // so nothing reaches extractedImages here.
      expect(book.pageTexts, hasLength(8));
    });
  });

  group('JBIG2Decode robustness', () {
    test('reports corruption as PdfException instead of crashing', () {
      final bytes = File('test/resources/pdf/jbig2/jbig2_symbol_offset.pdf').readAsBytesSync();
      final document = PdfDocument.parse(bytes);
      final stream = document.resolve(PdfIndirectRef(6, 0)) as PdfStream;
      final payload = stream.bytes;

      final mutations = <List<int>>[
        payload.sublist(0, payload.length ~/ 2), // truncated mid-segment
        payload.sublist(0, 11), // header only, no page information
        _flip(payload, 0x10), // inside the symbol dictionary payload
        _flip(payload, payload.length - 2), // tail of the arithmetic data
      ];
      // A stream with no page information cannot produce a raster;
      // single-byte flips may still decode (into garbage) without
      // throwing, which the robustness contract allows.
      expect(
        () => decodePdfStream(
          PdfStream(stream.dictionary, Uint8List.fromList(mutations[1])),
          document.resolve,
        ),
        throwsA(isA<PdfException>()),
      );
      for (var i = 2; i < mutations.length; i++) {
        PdfException? failure;
        try {
          decodePdfStream(
            PdfStream(stream.dictionary, Uint8List.fromList(mutations[i])),
            document.resolve,
          );
        } on PdfException catch (error) {
          failure = error;
        }
        expect(failure, anyOf(isNull, isA<PdfException>()), reason: 'mutation $i');
      }
    });

    test('survives pseudo-random byte mutations without crashing', () {
      final bytes = File('test/resources/pdf/jbig2/jbig2_symbol_offset.pdf').readAsBytesSync();
      final document = PdfDocument.parse(bytes);
      final stream = document.resolve(PdfIndirectRef(6, 0)) as PdfStream;
      final random = Random(20260906);
      for (var trial = 0; trial < 32; trial++) {
        final mutated = Uint8List.fromList(stream.bytes);
        for (var flip = 0; flip < 4; flip++) {
          mutated[random.nextInt(mutated.length)] = random.nextInt(256);
        }
        final corrupted = PdfStream(stream.dictionary, mutated);
        try {
          decodePdfStream(corrupted, document.resolve);
        } on PdfException {
          // Clean failure is the contract; any other error escapes.
        }
      }
    });
  });
}

const _pngSignature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

PdfDocument _document(final String name) =>
    PdfDocument.parse(File('test/resources/pdf/jbig2/$name').readAsBytesSync());

Uint8List _globalsBytes(final PdfDocument document, final int objectNumber) {
  final stream = document.resolve(PdfIndirectRef(objectNumber, 0)) as PdfStream;
  final parms = document.resolve(stream.dictionary['DecodeParms'] ?? const PdfNull());
  final PdfObject? dict;
  if (parms is PdfArray) {
    dict = parms.items.isEmpty ? null : document.resolve(parms.items.first);
  } else {
    dict = parms;
  }
  if (dict is! PdfDictionary) return Uint8List(0);
  final globals = document.resolve(dict['JBIG2Globals'] ?? const PdfNull());
  return globals is PdfStream ? globals.bytes : Uint8List(0);
}

/// Decodes one image XObject, returning (width, height, gray bytes).
/// The fixture path is relative to `test/resources/pdf/jbig2/`.
(int, int, Uint8List) _decodeImage(
  final String name,
  final int objectNumber,
  final Uint8List Function(Uint8List packed) transform, {
  final PdfDocument? document,
}) {
  final doc = document ?? _document(name);
  final stream = doc.resolve(PdfIndirectRef(objectNumber, 0)) as PdfStream;
  final width = (doc.resolve(stream.dictionary['Width']) as PdfNumber).value.toInt();
  final height = (doc.resolve(stream.dictionary['Height']) as PdfNumber).value.toInt();
  final packed = decodePdfStream(stream, doc.resolve);
  final bitmap = PdfBitmap.fromPacked(
    width: width,
    height: height,
    packed: transform(Uint8List.fromList(packed)),
  );
  return (width, height, bitmap.toGrayBytes());
}

void _expectGolden(final Uint8List gray, final String goldenName) {
  // Goldens are headerless P5 rasters — the harness strips the header
  // when it writes them.
  final raster = File('test/resources/pdf/reference/goldens/$goldenName').readAsBytesSync();
  expect(gray.length, raster.length);
  expect(gray, raster);
}

Uint8List _flip(final Uint8List source, final int offset) {
  final copy = Uint8List.fromList(source);
  copy[offset] ^= 0xFF;
  return copy;
}
