import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_codestream.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_color.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_decoder.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_exception.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_limits.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/pdf_jpx.dart';
import 'package:unseal/src/features/pdf/header/pdf_document.dart';
import 'package:unseal/src/features/pdf/header/pdf_object.dart';
import 'package:unseal/src/features/pdf/reader/pdf_byte_source.dart';
import 'package:unseal/src/features/pdf/reader/pdf_content_stream.dart';
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/unseal.dart';

import '../../../tool/jpx_precision/lanes.dart';
import 'pdf_fixture_builder.dart';

const String _dir = kJpxPrecisionCorpusDir;

Uint8List _fixture(final String file) => File('$_dir/$file').readAsBytesSync();

PdfDocument _document(final PdfFixtureBuilder builder) =>
    PdfDocument.parse(MemoryPdfByteSource(builder.build()));

/// Parsed PNG: IHDR fields, optional sBIT and the inflated scanlines.
final class _Png {
  _Png(final Uint8List bytes) {
    expect(bytes.sublist(0, 8), <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    final data = ByteData.sublistView(bytes);
    var cursor = 8;
    final idat = BytesBuilder(copy: false);
    while (cursor + 8 <= bytes.length) {
      final length = data.getUint32(cursor);
      final type = String.fromCharCodes(bytes.sublist(cursor + 4, cursor + 8));
      final body = bytes.sublist(cursor + 8, cursor + 8 + length);
      chunks.add(type);
      switch (type) {
        case 'IHDR':
          width = data.getUint32(cursor + 8);
          height = data.getUint32(cursor + 12);
          bitDepth = body[8];
          colorType = body[9];
        case 'sBIT':
          sbit = body;
        case 'IDAT':
          idat.add(body);
      }
      cursor += 12 + length;
    }
    rows = Uint8List.fromList(const ZLibDecoder().decodeBytes(idat.toBytes()));
  }

  late final int width;
  late final int height;
  late final int bitDepth;
  late final int colorType;
  Uint8List? sbit;
  late final Uint8List rows;
  final List<String> chunks = <String>[];

  int get channels => colorType == 2 ? 3 : 1;

  /// Sample [channel] of pixel ([x], [y]) at the PNG bit depth.
  int sample(final int x, final int y, final int channel) {
    final bytesPerSample = bitDepth == 16 ? 2 : 1;
    final stride = 1 + width * channels * bytesPerSample;
    final offset = y * stride + 1 + (x * channels + channel) * bytesPerSample;
    return bytesPerSample == 1 ? rows[offset] : (rows[offset] << 8) | rows[offset + 1];
  }
}

/// Offsets inside a bare codestream's SIZ marker.
({int ssiz, int xrsiz, int yrsiz}) _sizComponent(final int component) =>
    (ssiz: 42 + component * 3, xrsiz: 43 + component * 3, yrsiz: 44 + component * 3);

/// Rewrites one byte of a committed fixture.
Uint8List _patched(final String file, final Map<int, int> bytes) {
  final out = Uint8List.fromList(_fixture(file));
  bytes.forEach((final offset, final value) => out[offset] = value);
  return out;
}

/// Offset of the COD multiple-component-transform byte (SGcod) in a
/// bare codestream.
int _codMctOffset(final Uint8List codestream) {
  var cursor = 2;
  while (cursor + 4 <= codestream.length) {
    final marker = (codestream[cursor] << 8) | codestream[cursor + 1];
    final length = (codestream[cursor + 2] << 8) | codestream[cursor + 3];
    if (marker == kMarkerCod) {
      return cursor + 4 + 1 + 1 + 2; // Scod, progression, layers.
    }
    cursor += 2 + length;
  }
  throw StateError('COD not found');
}

/// JPEG 2000 precision and subsampling (doc/jpeg2000-precision.md):
/// every corpus fixture against the libopenjp2 2.5.4 reference on the
/// native, upsample and rgb lanes, the output contract, typed refusals,
/// budgets, PDF integration through the eager and session paths, and
/// the comparator's own negative cases.
void main() {
  final corpus = loadPrecisionCorpus();
  final tolerances = loadPrecisionTolerances();

  group('corpus lanes against the OpenJPEG reference', () {
    test('the corpus is the committed 37-fixture matrix', () {
      expect(corpus, hasLength(37));
    });
    for (final fixture in corpus) {
      test('${fixture.name} (${fixture.precision}-bit, ${fixture.lossless ? 'lossless' : 'lossy'}, '
          '${fixture.lanes.join('+')})', () {
        final outcome = comparePrecisionFixture(fixture, tolerances);
        expect(outcome.decodeError, isNull, reason: fixture.name);
        expect(outcome.geometryProblems, isEmpty, reason: fixture.name);
        for (final lane in outcome.lanes) {
          expect(lane.passed, isTrue, reason: '${fixture.name} ${lane.lane}: ${lane.reason}');
          if (fixture.lossless) {
            expect(lane.stats.exact, isTrue, reason: '${fixture.name} ${lane.lane}');
          } else {
            expect(lane.stats.maxAbsError, lessThanOrEqualTo(tolerances.globalMaxAbsError));
          }
        }
      });
    }

    test('the corpus covers every precision from 8 to 16 that the contract names', () {
      final precisions = corpus.map((final f) => f.precision).toSet();
      expect(precisions, containsAll(<int>[8, 9, 10, 12, 16]));
      expect(
        corpus.where((final f) => f.producer.startsWith('ffmpeg')),
        hasLength(greaterThanOrEqualTo(7)),
      );
      expect(
        corpus.where((final f) => f.lanes.contains('rgb')),
        hasLength(greaterThanOrEqualTo(12)),
      );
      expect(
        corpus.where((final f) => f.lanes.contains('upsample')),
        hasLength(greaterThanOrEqualTo(7)),
      );
    });
  });

  group('native sample contract', () {
    test('16-bit planes keep the full range without reduction to 8 bits', () {
      final image = decodeJpxImage(_fixture('synth-gray16-lossless.j2k'));
      expect(image.precision, 16);
      final plane = image.components.single.samples;
      expect(plane, isA<Uint16List>());
      expect(plane.reduce(max), greaterThan(255));
      expect(
        image.outputPlanes.single,
        same(plane),
        reason: 'full-resolution planes project in place',
      );
    });

    test('subsampled components report their own grid and origin', () {
      final image = decodeJpxImage(_fixture('synth-gray8-sub2x1-origin.j2k'));
      final plane = image.components.single;
      expect((image.x0, image.y0, image.width, image.height), (3, 0, 63, 48));
      expect(
        (plane.dx, plane.dy, plane.x0, plane.y0, plane.width, plane.height),
        (2, 1, 2, 0, 31, 48),
      );
      expect(plane.samples, isA<Uint8List>());
    });

    test('COC and QCC overrides parse without the SGcod bytes COD carries', () {
      final plain = decodeJpxImage(_fixture('synth-gray9-lossless.j2k'));
      final overridden = decodeJpxImage(_fixture('synth-gray12-lossless-coc-qcc.j2k'));
      expect(overridden.precision, 12);
      expect(overridden.components.single.samples.length, plain.components.single.samples.length);
    });
  });

  group('output contract', () {
    test('8-bit images still produce 8-bit PNGs without sBIT', () {
      final image = decodeJpxImage(_fixture('synth-gray8-sub2x1-origin.j2k'));
      final png = _Png(image.toPngBytes());
      expect((png.width, png.height, png.bitDepth, png.colorType), (63, 48, 8, 0));
      expect(png.sbit, isNull);
      expect(png.chunks, <String>['IHDR', 'IDAT', 'IEND']);
      for (var x = 0; x < 63; x++) {
        expect(png.sample(x, 5, 0), image.outputPlanes.single[5 * 63 + x]);
      }
    });

    for (final (file, precision, channels) in <(String, int, int)>[
      ('synth-gray9-lossless.j2k', 9, 1),
      ('synth-gray12-lossless-tiles.j2k', 12, 1),
      ('synth-gray16-lossless.j2k', 16, 1),
      ('synth-rgb12-rct-lossless.j2k', 12, 3),
      ('real-rgb16-lossless-ffmpeg.j2k', 16, 3),
      ('synth-sycc16-420-lossy.jp2', 16, 3),
      ('real-sycc10-420-lossless-ffmpeg.jp2', 10, 3),
    ]) {
      test('$precision-bit $file produces a 16-bit PNG that recovers the native samples', () {
        final image = decodeJpxImage(_fixture(file));
        final png = _Png(image.toPngBytes());
        expect((png.bitDepth, png.channels), (16, channels));
        expect(png.width, image.width);
        expect(png.height, image.height);
        if (precision == 16) {
          expect(png.sbit, isNull);
        } else {
          expect(png.sbit, List<int>.filled(channels, precision));
          expect(png.chunks.indexOf('sBIT'), lessThan(png.chunks.indexOf('IDAT')));
        }
        final planes = image.outputPlanes;
        final shift = 16 - precision;
        for (var y = 0; y < image.height; y += 7) {
          for (var x = 0; x < image.width; x += 5) {
            for (var channel = 0; channel < channels; channel++) {
              final native = planes[channel][y * image.width + x];
              final scaled = png.sample(x, y, channel);
              expect(scaled >> shift, native, reason: '$file ($x,$y) channel $channel');
            }
          }
        }
      });
    }

    test('bit replication maps full scale to full scale at every precision', () {
      for (var precision = 9; precision <= 16; precision++) {
        final shift = 16 - precision;
        final maxValue = (1 << precision) - 1;
        final scaled = shift == 0
            ? maxValue
            : (maxValue << shift) | (maxValue >> (precision - shift));
        expect(scaled, 65535, reason: 'precision $precision');
        expect(scaled >> shift, maxValue);
        expect(shift == 0 ? 0 : (0 << shift) | (0 >> (precision - shift)), 0);
      }
    });

    test('nearest-neighbour upsampling follows the opj_decompress -upsample phase', () {
      final source = Uint8List.fromList(<int>[10, 20, 30, 40, 50, 60]);
      final target = JpxColor.upsample(
        source: source,
        sourceWidth: 3,
        sourceHeight: 2,
        dx: 2,
        dy: 2,
        xoff: 1,
        yoff: 0,
        width: 6,
        height: 3,
      );
      expect(target, <int>[
        0, 10, 10, 20, 20, 30, //
        0, 10, 10, 20, 20, 30, //
        0, 40, 40, 50, 50, 60, //
      ]);
    });

    test('three subsampled components outside the sYCC rule upsample as RGB', () {
      final image = decodeJpxImage(_fixture('synth-rgb10-sub2x2-all.j2k'));
      expect(image.colorModel, JpxColorModel.rgb);
      expect(image.outputPlanes, hasLength(3));
      expect(image.outputPlanes[0], hasLength(64 * 48));
    });

    test('a bare codestream in the 4:2:0 layout is converted as sYCC', () {
      final image = decodeJpxImage(_fixture('synth-3comp-420-bare-lossless.j2k'));
      expect(image.isJp2, isFalse);
      expect(image.colorModel, JpxColorModel.sycc);
    });
  });

  group('typed refusals', () {
    final gray16 = 'synth-gray16-lossless.j2k';
    final rgb12 = 'synth-rgb12-rct-lossless.j2k';

    test('signed components', () {
      final ssiz = _sizComponent(0).ssiz;
      expect(
        () => decodeJpxImage(_patched(gray16, <int, int>{ssiz: 0x8F})),
        throwsA(
          isA<JpxUnsupportedException>().having(
            (final e) => e.message,
            'message',
            contains('signed'),
          ),
        ),
      );
    });

    for (final (bits, ssiz) in <(int, int)>[(7, 6), (17, 16), (1, 0), (32, 31)]) {
      test('$bits-bit precision', () {
        expect(
          () => decodeJpxImage(_patched(gray16, <int, int>{_sizComponent(0).ssiz: ssiz})),
          throwsA(
            isA<JpxUnsupportedException>().having(
              (final e) => e.message,
              'message',
              contains('precision'),
            ),
          ),
        );
      });
    }

    test('mixed component precisions', () {
      expect(
        () => decodeJpxImage(_patched(rgb12, <int, int>{_sizComponent(1).ssiz: 7})),
        throwsA(
          isA<JpxUnsupportedException>().having(
            (final e) => e.message,
            'message',
            contains('mixed'),
          ),
        ),
      );
    });

    test('a zero subsampling factor is corruption', () {
      expect(
        () => decodeJpxImage(_patched(gray16, <int, int>{_sizComponent(0).xrsiz: 0})),
        throwsA(
          isA<JpxException>().having((final e) => e.message, 'message', contains('subsampling')),
        ),
      );
    });

    test('a component grid with no samples is corruption', () {
      // XOsiz 1 and Xsiz 2 with dx 2: ceil(2/2) - ceil(1/2) = 0 columns.
      final bytes = _patched(gray16, <int, int>{_sizComponent(0).xrsiz: 2});
      final data = ByteData.sublistView(bytes);
      data.setUint32(8, 2); // Xsiz
      data.setUint32(16, 1); // XOsiz
      expect(
        () => decodeJpxImage(bytes),
        throwsA(
          isA<JpxException>().having((final e) => e.message, 'message', contains('no samples')),
        ),
      );
    });

    test('MCT over components on different grids is refused as corruption', () {
      final bytes = Uint8List.fromList(_fixture('synth-3comp-420-bare-lossless.j2k'));
      bytes[_codMctOffset(bytes)] = 1;
      expect(
        () => decodeJpxImage(bytes),
        throwsA(
          isA<JpxException>().having(
            (final e) => e.message,
            'message',
            contains('one sample grid'),
          ),
        ),
      );
    });

    test('JP2 sYCC with a chroma layout outside 4:4:4, 4:2:2 and 4:2:0 is refused', () {
      // Making component 0 subsampled too leaves three equally subsampled
      // components under colr 18.
      final bytes = Uint8List.fromList(_fixture('synth-sycc8-420-lossless.jp2'));
      final soc = _codestreamOffset(bytes);
      bytes[soc + _sizComponent(0).xrsiz] = 2;
      bytes[soc + _sizComponent(0).yrsiz] = 2;
      expect(
        () => decodeJpxImage(bytes),
        throwsA(
          isA<JpxUnsupportedException>().having(
            (final e) => e.message,
            'message',
            contains('sYCC'),
          ),
        ),
      );
    });

    test('JP2 palettes (pclr), channel definitions (cdef) and ICC profiles are refused', () {
      final base = _fixture('synth-gray9-lossless.j2k');
      expect(
        () => decodeJpxImage(_jp2(base, extraHeaderBoxes: <Uint8List>[_box('pclr', Uint8List(8))])),
        throwsA(
          isA<JpxUnsupportedException>().having(
            (final e) => e.message,
            'message',
            contains('palette'),
          ),
        ),
      );
      expect(
        () => decodeJpxImage(_jp2(base, extraHeaderBoxes: <Uint8List>[_box('cdef', Uint8List(8))])),
        throwsA(
          isA<JpxUnsupportedException>().having(
            (final e) => e.message,
            'message',
            contains('alpha'),
          ),
        ),
      );
      expect(
        () => decodeJpxImage(_jp2(base, colrMethod: 2)),
        throwsA(
          isA<JpxUnsupportedException>().having((final e) => e.message, 'message', contains('ICC')),
        ),
      );
    });

    test('the JP2 ihdr BPC byte is informative, the SIZ precision rules', () {
      final base = _fixture('synth-gray16-lossless.j2k');
      // ffmpeg 9.0.2 writes the depth instead of depth - 1.
      final image = decodeJpxImage(_jp2(base, ihdrBpc: 16, enumcs: 17));
      expect(image.precision, 16);
      expect(decodeJpxImage(_jp2(base, ihdrBpc: 7, enumcs: 17)).precision, 16);
    });

    test('JP2 colr 17 on three components and 16/18 on one component mismatch', () {
      final rgb = _fixture('synth-rgb12-rct-lossless.j2k');
      final gray = _fixture('synth-gray9-lossless.j2k');
      expect(() => decodeJpxImage(_jp2(rgb, enumcs: 17)), throwsA(isA<JpxUnsupportedException>()));
      expect(() => decodeJpxImage(_jp2(gray, enumcs: 16)), throwsA(isA<JpxUnsupportedException>()));
      expect(() => decodeJpxImage(_jp2(gray, enumcs: 18)), throwsA(isA<JpxUnsupportedException>()));
      expect(decodeJpxImage(_jp2(rgb, enumcs: 16)).colorModel, JpxColorModel.rgb);
      expect(decodeJpxImage(_jp2(rgb, enumcs: 18)).colorModel, JpxColorModel.sycc);
    });
  });

  group('budgets before allocation', () {
    test('a native plane beyond the sample budget rejects before decoding tiles', () {
      final bytes = _patched('synth-gray16-lossless.j2k', <int, int>{});
      // Ysiz = 2^26 rows keeps the coordinates in 31 bits; 64 columns x
      // 2^26 rows x 2 bytes exceeds every budget.
      ByteData.sublistView(bytes).setUint32(12, 1 << 26); // Ysiz
      expect(
        () => decodeJpxImage(bytes),
        throwsA(isA<JpxException>().having((final e) => e.message, 'message', contains('budget'))),
      );
    });

    test('a reference-grid projection beyond the budget rejects before upsampling', () {
      final small = Uint8List(4);
      final image = JpxImage(
        width: 1 << 20,
        height: 1 << 9,
        x0: 0,
        y0: 0,
        precision: 8,
        components: <JpxComponentPlane>[
          JpxComponentPlane(dx: 255, dy: 255, x0: 0, y0: 0, width: 2, height: 2, samples: small),
        ],
        colorModel: JpxColorModel.gray,
        isJp2: false,
        enumcs: null,
      );
      expect(
        () => image.outputPlanes,
        throwsA(isA<JpxException>().having((final e) => e.message, 'message', contains('budget'))),
      );
      expect(image.toPngBytes, throwsA(isA<JpxException>()));
    });

    test('a PNG beyond the raw scanline budget rejects before encoding', () {
      final plane = Uint16List(2);
      final image = JpxImage(
        width: 1 << 24,
        height: 1 << 5,
        x0: 0,
        y0: 0,
        precision: 16,
        components: <JpxComponentPlane>[
          JpxComponentPlane(
            dx: 1,
            dy: 1,
            x0: 0,
            y0: 0,
            width: 1 << 24,
            height: 1 << 5,
            samples: plane,
          ),
        ],
        colorModel: JpxColorModel.gray,
        isJp2: false,
        enumcs: null,
      );
      expect(image.toPngBytes, throwsA(isA<JpxException>()));
    });

    test('limits agree with the documented contract', () {
      expect((kJpxMinPrecision, kJpxMaxPrecision, kJpxMaxSubsampling), (8, 16, 255));
      expect(kJpxMaxImageBytes, 256 << 20);
      expect(kJpxMaxBands, 97);
    });
  });

  group('corruption normalizes to typed failures', () {
    for (final file in <String>[
      'synth-gray16-lossless-origin-tiles.j2k',
      'synth-sycc12-420-lossless-origin-tiles.jp2',
      'real-sycc8-420-lossless-odd-ffmpeg.jp2',
      'synth-gray16-lossy.j2k',
    ]) {
      final base = _fixture(file);

      test('$file: truncations never leak untyped errors', () {
        for (var cut = 2; cut < base.length; cut += 23) {
          try {
            decodeJpxImage(base.sublist(0, cut));
          } on JpxException {
            // The documented typed path.
          }
        }
      });

      test('$file: seeded mutations either decode or reject typed', () {
        final generator = Random(file.hashCode ^ 20261018);
        for (var trial = 0; trial < 96; trial++) {
          final mutated = Uint8List.fromList(base);
          final flips = 1 + generator.nextInt(3);
          for (var flip = 0; flip < flips; flip++) {
            mutated[generator.nextInt(mutated.length)] = generator.nextInt(256);
          }
          try {
            final image = decodeJpxImage(mutated);
            expect(image.outputPlanes.first.length, image.width * image.height);
            image.toPngBytes();
          } on JpxException {
            // Typed rejection is the documented path.
          }
        }
      });
    }
  });

  group('PDF JPXDecode integration', () {
    final gray16 = _fixture('synth-gray16-lossless.j2k');
    final gray12Tiles = _fixture('synth-gray12-lossless-tiles.j2k');
    final sycc420 = _fixture('real-sycc8-420-lossless-odd-ffmpeg.jp2');
    final sycc12 = _fixture('synth-sycc12-420-lossless-origin-tiles.jp2');
    final gray8Sub = _fixture('synth-gray8-sub2x1-origin.j2k');

    for (final bitsPerComponent in <int?>[8, 16, 12, null]) {
      test('/BitsPerComponent $bitsPerComponent is ignored for JPXDecode (codestream rules)', () {
        final document = _document(
          jpxImagePageFixture(gray16, width: 64, height: 48, bitsPerComponent: bitsPerComponent),
        );
        final result = decodePdfImageObject(document, 8);
        expect(result, isNotNull);
        final png = _Png(result!.$1);
        expect((png.width, png.height, png.bitDepth, png.colorType), (64, 48, 16, 0));
      });
    }

    test('/DeviceRGB with a sYCC 4:2:0 JP2 extracts a truecolor PNG at the luma size', () {
      final document = _document(
        jpxImagePageFixture(sycc420, width: 63, height: 45, components: 3),
      );
      final png = _Png(decodePdfImageObject(document, 8)!.$1);
      expect((png.width, png.height, png.bitDepth, png.colorType), (63, 45, 8, 2));
    });

    test('/DeviceRGB with a 12-bit sYCC JP2 extracts a 16-bit truecolor PNG with sBIT 12', () {
      final document = _document(jpxImagePageFixture(sycc12, width: 63, height: 45, components: 3));
      final png = _Png(decodePdfImageObject(document, 8)!.$1);
      expect((png.bitDepth, png.colorType), (16, 2));
      expect(png.sbit, <int>[12, 12, 12]);
    });

    test('a subsampled grayscale image extracts at the reference-grid size', () {
      final document = _document(jpxImagePageFixture(gray8Sub, width: 63, height: 48));
      final png = _Png(decodePdfImageObject(document, 8)!.$1);
      expect((png.width, png.height, png.bitDepth), (63, 48, 8));
      expect(png.sample(0, 0, 0), 0, reason: 'origin 3 with dx 2 zero-fills the first column');
      expect(png.sample(1, 0, 0), png.sample(2, 0, 0), reason: 'replicated sample');
    });

    test('/ColorSpace inconsistent with the component count rejects typed', () {
      final grayOnColor = _document(
        jpxImagePageFixture(
          sycc420,
          width: 63,
          height: 45,
          components: 3,
          colorSpace: 'DeviceGray',
        ),
      );
      expect(
        () => decodePdfJpxSamples(grayOnColor, grayOnColor.object(8)! as PdfStream),
        throwsA(isA<JpxException>()),
      );
      expect(decodePdfImageObject(grayOnColor, 8), isNull);
      final colorOnGray = _document(
        jpxImagePageFixture(gray16, width: 64, height: 48, colorSpace: 'DeviceRGB'),
      );
      expect(
        () => decodePdfJpxSamples(colorOnGray, colorOnGray.object(8)! as PdfStream),
        throwsA(isA<JpxException>()),
      );
    });

    test('/Width or /Height disagreeing with the reference grid rejects typed', () {
      final wrongWidth = _document(jpxImagePageFixture(gray8Sub, width: 31, height: 48));
      expect(
        () => decodePdfJpxSamples(wrongWidth, wrongWidth.object(8)! as PdfStream),
        throwsA(isA<JpxException>().having((final e) => e.message, 'message', contains('31x48'))),
      );
      final wrongHeight = _document(
        jpxImagePageFixture(sycc420, width: 63, height: 23, components: 3),
      );
      expect(
        () => decodePdfJpxSamples(wrongHeight, wrongHeight.object(8)! as PdfStream),
        throwsA(isA<JpxException>()),
      );
    });

    test('an /ASCII85Decode /JPXDecode chain yields the same 16-bit PNG as the direct stream', () {
      final direct = decodePdfImageObject(
        _document(jpxImagePageFixture(gray12Tiles, width: 100, height: 67)),
        8,
      );
      final chained = decodePdfImageObject(
        _document(jpxImagePageFixture(gray12Tiles, width: 100, height: 67, ascii85: true)),
        8,
      );
      expect(chained!.$1, direct!.$1);
      expect(_Png(direct.$1).bitDepth, 16);
    });

    test('a repeated placement extracts one image and leaves the page text untouched', () {
      final twice =
          Unseal.parse(jpxImagePageFixture(gray16, width: 64, height: 48, drawTwice: true).build())
              as PdfBook;
      final once =
          Unseal.parse(jpxImagePageFixture(gray16, width: 64, height: 48).build()) as PdfBook;
      final eightBit =
          Unseal.parse(
                jpxImagePageFixture(
                  File('test/resources/pdf/jpeg2000/gray53-lossless-lrcp.j2k').readAsBytesSync(),
                  width: 64,
                  height: 64,
                ).build(),
              )
              as PdfBook;
      expect(twice.files.images, hasLength(1));
      expect(twice.files.images.single.content, once.files.images.single.content);
      expect(twice.pageTexts.single.images, hasLength(2));
      expect(once.pageTexts.single.text, eightBit.pageTexts.single.text);
      expect(twice.pageTexts.single.text, once.pageTexts.single.text);
      expect(twice.pageTexts.single.lines.length, once.pageTexts.single.lines.length);
      expect(twice.pageLayouts.single.words.length, once.pageLayouts.single.words.length);
      expect(_Png(twice.files.images.single.content).bitDepth, 16);
    });

    test('the session engine serves the eager 16-bit and sYCC bytes on demand', () async {
      for (final (bytes, width, height, components) in <(Uint8List, int, int, int)>[
        (gray16, 64, 48, 1),
        (sycc420, 63, 45, 3),
      ]) {
        final pdf = Uint8List.fromList(
          jpxImagePageFixture(bytes, width: width, height: height, components: components).build(),
        );
        final book = Unseal.parse(pdf) as PdfBook;
        final engine = await SessionEngine.openBytes(pdf);
        addTearDown(engine.close);
        final eagerImage = book.files.images.single;
        expect(await engine.resource(eagerImage.path), eagerImage.content);
        expect(engine.resourceLength(eagerImage.path), eagerImage.content.length);
      }
    });
  });

  group('comparator negative cases', () {
    final fixture = corpus.firstWhere((final f) => f.name == 'synth-sycc8-420-lossless');

    test('a missing reference payload fails the lane', () {
      final temp = Directory.systemTemp.createTempSync('jpx-precision-missing');
      addTearDown(() => temp.deleteSync(recursive: true));
      final outcome = comparePrecisionFixture(fixture, tolerances, oracleDir: temp.path);
      expect(outcome.passed, isFalse);
      expect(outcome.lanes.map((final lane) => lane.reason), everyElement(contains('missing')));
    });

    test('a corrupted reference payload fails the lane', () {
      final temp = Directory.systemTemp.createTempSync('jpx-precision-corrupt');
      addTearDown(() => temp.deleteSync(recursive: true));
      for (final suffix in <String>['native.bin', 'native.json', 'rgb.rawl']) {
        final source = File('$_dir/oracle/${fixture.name}.$suffix');
        final bytes = Uint8List.fromList(source.readAsBytesSync());
        if (suffix != 'native.json') {
          bytes[bytes.length ~/ 2] ^= 0x40;
        }
        File('${temp.path}/${fixture.name}.$suffix').writeAsBytesSync(bytes);
      }
      final outcome = comparePrecisionFixture(fixture, tolerances, oracleDir: temp.path);
      expect(outcome.passed, isFalse);
      expect(outcome.lanes.where((final lane) => !lane.passed), hasLength(2));
      expect(outcome.lanes.first.stats.differing, 1);
    });

    test('a truncated reference payload fails as a size mismatch', () {
      final temp = Directory.systemTemp.createTempSync('jpx-precision-short');
      addTearDown(() => temp.deleteSync(recursive: true));
      final source = File('$_dir/oracle/${fixture.name}.native.bin').readAsBytesSync();
      File(
        '${temp.path}/${fixture.name}.native.bin',
      ).writeAsBytesSync(source.sublist(0, source.length - 1));
      File(
        '${temp.path}/${fixture.name}.rgb.rawl',
      ).writeAsBytesSync(File('$_dir/oracle/${fixture.name}.rgb.rawl').readAsBytesSync());
      final outcome = comparePrecisionFixture(fixture, tolerances, oracleDir: temp.path);
      expect(outcome.lanes.first.stats.sizeMismatch, isTrue);
      expect(outcome.lanes.first.passed, isFalse);
      expect(outcome.lanes.last.passed, isTrue);
    });
  });
}

/// Offset of the SOC marker inside a JP2 file (start of the jp2c body).
int _codestreamOffset(final Uint8List jp2) {
  var cursor = 0;
  while (cursor + 8 <= jp2.length) {
    final length = ByteData.sublistView(jp2).getUint32(cursor);
    final type = String.fromCharCodes(jp2.sublist(cursor + 4, cursor + 8));
    if (type == 'jp2c') {
      return cursor + 8;
    }
    cursor += length == 0 ? jp2.length : length;
  }
  throw StateError('jp2c not found');
}

Uint8List _box(final String type, final Uint8List body) {
  final out = BytesBuilder(copy: false);
  final header = Uint8List(8);
  ByteData.sublistView(header).setUint32(0, 8 + body.length);
  header.setRange(4, 8, type.codeUnits);
  out.add(header);
  out.add(body);
  return out.toBytes();
}

/// Wraps a bare codestream in a minimal JP2 (signature, ftyp, jp2h with
/// ihdr + colr, optional extra header boxes, jp2c).
Uint8List _jp2(
  final Uint8List codestream, {
  final int enumcs = 17,
  final int colrMethod = 1,
  final int? ihdrBpc,
  final List<Uint8List> extraHeaderBoxes = const <Uint8List>[],
}) {
  final info = parseCodestream(codestream);
  final ihdr = Uint8List(14);
  final data = ByteData.sublistView(ihdr);
  data.setUint32(0, info.image.gridHeight);
  data.setUint32(4, info.image.gridWidth);
  data.setUint16(8, info.image.componentCount);
  ihdr[10] = ihdrBpc ?? (info.image.precision - 1);
  ihdr[11] = 7;
  final Uint8List colr;
  if (colrMethod == 1) {
    colr = Uint8List(7);
    colr[0] = 1;
    ByteData.sublistView(colr).setUint32(3, enumcs);
  } else {
    colr = Uint8List.fromList(<int>[2, 0, 0, 0, 0, 0, 0, 0]);
  }
  final header = BytesBuilder(copy: false)
    ..add(_box('ihdr', ihdr))
    ..add(_box('colr', colr));
  for (final box in extraHeaderBoxes) {
    header.add(box);
  }
  final out = BytesBuilder(copy: false)
    ..add(_box('jP  ', Uint8List.fromList(<int>[0x0D, 0x0A, 0x87, 0x0A])))
    ..add(
      _box('ftyp', Uint8List.fromList(<int>[...'jp2 '.codeUnits, 0, 0, 0, 0, ...'jp2 '.codeUnits])),
    )
    ..add(_box('jp2h', header.toBytes()))
    ..add(_box('jp2c', codestream));
  return out.toBytes();
}
