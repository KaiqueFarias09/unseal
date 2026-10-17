import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_decoder.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_exception.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/pdf_jpx.dart';
import 'package:unseal/src/features/pdf/header/pdf_document.dart';
import 'package:unseal/src/features/pdf/header/pdf_object.dart';
import 'package:unseal/src/features/pdf/reader/pdf_byte_source.dart';
import 'package:unseal/src/features/pdf/reader/pdf_content_stream.dart';
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/unseal.dart';

import 'pdf_fixture_builder.dart';

const String _fixturesDir = 'test/resources/pdf/jpeg2000';

PdfDocument _document(final PdfFixtureBuilder builder) =>
    PdfDocument.parse(MemoryPdfByteSource(builder.build()));

/// JPXDecode: the pure-Dart JPEG 2000 Part 1 port of the pinned
/// OpenJPEG revision (8314119b), accepted against the committed oracle
/// payloads.
///
/// - Lossless fixtures must match the oracle byte-exact.
/// - Lossy fixtures must stay inside the `tolerances.json` ceilings,
///   which were fixed from inter-build OpenJPEG deltas *before* the
///   first Dart comparison; loosening them invalidates acceptance.
/// - Everything outside the subset (arithmetic bypass, CMYK, palettes,
///   SMaskInData, geometry conflicts) rejects typed; corrupt input
///   normalizes to `JpxException`, never to a RangeError or invented
///   pixels.
void main() {
  final tolerances =
      const JsonDecoder().convert(File('$_fixturesDir/tolerances.json').readAsStringSync())
          as Map<String, Object?>;
  final ceilings = (tolerances['fixtures']! as Map<String, Object?>)
      .cast<String, Map<String, Object?>>();

  final fixtureNames = <String>[
    for (final entry in Directory(_fixturesDir).listSync())
      if (entry is File && (entry.path.endsWith('.j2k') || entry.path.endsWith('.jp2')))
        entry.uri.pathSegments.last.replaceFirst(RegExp(r'\.(j2k|jp2)$'), ''),
  ]..sort();

  group('JPEG 2000 codec vs the pinned OpenJPEG oracle', () {
    for (final name in fixtureNames) {
      final ceiling = ceilings[name];
      if (name.contains('-bypass')) {
        test('$name rejects arithmetic bypass with a typed error', () {
          final bytes = File('$_fixturesDir/$name.j2k').readAsBytesSync();
          expect(
            () => decodeJpxImage(bytes),
            throwsA(
              isA<JpxUnsupportedException>().having(
                (final e) => e.message,
                'message',
                contains('bypass'),
              ),
            ),
          );
        });
        continue;
      }
      test(
        ceiling == null
            ? '$name matches the oracle byte-exact'
            : '$name stays inside the fixed lossy ceiling',
        () {
          final oracle = File('$_fixturesDir/oracle/$name.raw').readAsBytesSync();
          final extension = name.contains('jp2') ? '.jp2' : '.j2k';
          final image = decodeJpxImage(File('$_fixturesDir/$name$extension').readAsBytesSync());
          final actual = <int>[for (final plane in image.samples) ...plane];
          expect(actual, hasLength(oracle.length), reason: name);
          if (ceiling == null) {
            expect(actual, oracle, reason: name);
            return;
          }
          final maxAllowed = (ceiling['maxAbsError']! as num).toDouble();
          final rmseAllowed = (ceiling['rmse']! as num).toDouble();
          var max = 0;
          var sumSquares = 0;
          for (var index = 0; index < oracle.length; index++) {
            final delta = actual[index] - oracle[index];
            if (delta.abs() > max) max = delta.abs();
            sumSquares += delta * delta;
          }
          final rmse = sqrt(sumSquares / oracle.length);
          expect(max <= maxAllowed, isTrue, reason: '$name max |err| $max');
          expect(rmse <= rmseAllowed, isTrue, reason: '$name rmse ${rmse.toStringAsFixed(4)}');
        },
      );
    }
  });

  group('budgets before allocation', () {
    // The gray 64x64 lossless fixture with its SIZ geometry patched:
    // SOC/Lsiz/Rsiz occupy the first 8 bytes, then Xsiz (8-11) and
    // Ysiz (12-15) big-endian, Csiz at 40-41.
    final baseSiz = File('$_fixturesDir/gray53-lossless-lrcp.j2k').readAsBytesSync();

    test('a raster beyond the sample budget rejects before allocating', () {
      final patched = Uint8List.fromList(baseSiz);
      // Height 2^26 keeps every declared coordinate inside 31 bits but
      // pushes 64 x 2^26 samples far above the 2^28-sample cap.
      patched[12] = 0x04;
      expect(
        () => decodeJpxImage(patched),
        throwsA(isA<JpxException>().having((final e) => e.message, 'message', contains('budget'))),
      );
    });

    test('a component count beyond the budget rejects typed', () {
      final patched = Uint8List.fromList(baseSiz);
      patched[40] = 0x42;
      patched[41] = 0x20; // 16928 > 16384 declared components.
      expect(() => decodeJpxImage(patched), throwsA(isA<JpxException>()));
    });

    test('a truncated payload inside the budget decodes-or-fails typed', () {
      // A 256x256 lossy fixture with a legal SIZ but cut short: the
      // failure surfaces as JpxException, never RangeError/StateError.
      final full = File('$_fixturesDir/gray97-lossy-256.j2k').readAsBytesSync();
      expect(() => decodeJpxImage(full.sublist(0, 120)), throwsA(isA<JpxException>()));
    });
  });

  group('corruption normalizes to typed failures', () {
    final base = File('$_fixturesDir/gray53-lossless-lrcp.j2k').readAsBytesSync();

    test('truncations at a stride never leak untyped errors', () {
      for (var cut = 2; cut < base.length; cut += 37) {
        try {
          decodeJpxImage(base.sublist(0, cut));
        } on JpxException {
          // Expected: the codec's typed failure (the refusal of an
          // out-of-subset feature is a subtype of it). Any other
          // exception type fails the test by propagating.
        }
      }
    });

    test('single-byte mutations either decode or reject typed', () {
      final generator = Random(20261017);
      for (var trial = 0; trial < 64; trial++) {
        final mutated = Uint8List.fromList(base);
        final position = generator.nextInt(mutated.length);
        mutated[position] = generator.nextInt(256);
        try {
          final image = decodeJpxImage(mutated);
          // A mutation that still decodes must keep the geometry.
          expect(image.width, 64);
          expect(image.height, 64);
        } on JpxException {
          // Typed rejection is the documented path.
        }
      }
    });
  });

  group('PDF JPXDecode adapter', () {
    final grayJ2k = File('$_fixturesDir/gray53-lossless-lrcp.j2k').readAsBytesSync();
    final rgbJ2k = File('$_fixturesDir/rgb53-lossless-rct.j2k').readAsBytesSync();

    test('a gray JPXDecode XObject extracts as a 64x64 PNG', () {
      final document = _document(jpxImagePageFixture(grayJ2k, width: 64, height: 64));
      final result = decodePdfImageObject(document, 8);
      expect(result, isNotNull);
      expect(result!.$2, 'png');
      // PNG signature + IHDR geometry.
      final png = result.$1;
      expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
      expect((png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19], 64);
      expect((png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23], 64);
    });

    test('an RGB codestream extracts as truecolor PNG', () {
      final document = _document(jpxImagePageFixture(rgbJ2k, width: 64, height: 64, components: 3));
      final result = decodePdfImageObject(document, 8);
      expect(result, isNotNull);
      // Color type 2 (truecolor) lives at IHDR byte offset 9.
      expect(result!.$1[25], 2);
    });

    test('an /ASCII85Decode /JPXDecode chain decodes through both filters', () {
      final document = _document(
        jpxImagePageFixture(grayJ2k, width: 64, height: 64, ascii85: true),
      );
      final result = decodePdfImageObject(document, 8);
      expect(result, isNotNull);
      final direct = decodePdfImageObject(
        _document(jpxImagePageFixture(grayJ2k, width: 64, height: 64)),
        8,
      );
      expect(result!.$1, direct!.$1, reason: 'ASCII85 is transport-only');
    });

    test('an indirect /ColorSpace reference binds like a direct one', () {
      final document = _document(
        jpxImagePageFixture(grayJ2k, width: 64, height: 64, indirectColorSpace: true),
      );
      final result = decodePdfImageObject(document, 8);
      expect(result, isNotNull);
      expect(result!.$2, 'png');
    });

    test('a /Width conflict with the codestream rejects typed', () {
      final document = _document(jpxImagePageFixture(grayJ2k, width: 63, height: 64));
      expect(
        () => decodePdfJpxSamples(document, document.object(8)! as PdfStream),
        throwsA(isA<JpxException>()),
      );
    });

    test('an /ICCBased N mismatch rejects typed', () {
      final fixture = PdfFixtureBuilder()
        ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
        ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
        ..addObject(
          5,
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
          '/Resources << /XObject << /Im0 8 0 R >> >> >>',
        )
        ..addStreamObject(7, '', 'q 200 0 0 150 72 500 cm /Im0 Do Q\n'.codeUnits)
        ..addStreamObject(
          8,
          ' /Subtype /Image /Width 64 /Height 64 /BitsPerComponent 8'
          ' /ColorSpace [/ICCBased 11 0 R] /Filter /JPXDecode',
          grayJ2k,
        )
        ..addStreamObject(11, ' /N 3', [0, 0, 0, 0]);
      final document = _document(fixture);
      expect(
        () => decodePdfJpxSamples(document, document.object(8)! as PdfStream),
        throwsA(isA<JpxException>()),
      );
    });

    test('a corrupted codestream degrades to geometry-only, never throws', () {
      final corrupted = Uint8List.fromList(grayJ2k);
      for (var i = 40; i < 40 + 24; i++) {
        corrupted[i] = 0xFF;
      }
      final document = _document(jpxImagePageFixture(corrupted, width: 64, height: 64));
      // The adapter's documented degradation: no raster, no crash.
      expect(decodePdfImageObject(document, 8), isNull);
    });
  });

  group('JPXDecode through extraction and the session engine', () {
    final grayJ2k = File('$_fixturesDir/gray53-lossless-lrcp.j2k').readAsBytesSync();

    test('parsePdfBook extracts the JPX image as a drawable PNG', () {
      final book =
          Unseal.parse(jpxImagePageFixture(grayJ2k, width: 64, height: 64).build()) as PdfBook;
      expect(book.files.images, hasLength(1));
      final image = book.files.images.single;
      expect(image.path, 'images/pdf-image-8.png');
      expect(image.content.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    });

    test('the session engine serves the same JPX bytes on demand', () {
      final bytes = Uint8List.fromList(jpxImagePageFixture(grayJ2k, width: 64, height: 64).build());
      final book = Unseal.parse(bytes) as PdfBook;
      final engine = SessionEngine.openBytes(bytes);
      addTearDown(engine.close);

      final eagerImage = book.files.images.single;
      expect(engine.resource(eagerImage.path), eagerImage.content);
      expect(engine.resourceLength(eagerImage.path), eagerImage.content.length);
    });
  });
}
