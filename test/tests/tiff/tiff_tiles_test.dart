import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/src/features/tiff/tiff_limits.dart';
import 'package:unseal/tiff.dart' as tiff;
import 'package:unseal/unseal.dart';

import '../../support/tiff_tiled_embedded.dart';
import '../../support/tiff_tiled_fixture.dart';
import '../../support/tiff_tiled_goldens.dart';

const _tiledDir = 'test/resources/tiff/tiled';

Uint8List _fixture(final String name) =>
    Uint8List.fromList(File('$_tiledDir/$name').readAsBytesSync());

Uint8List _stripFixture(final String name) =>
    Uint8List.fromList(File('test/resources/tiff/$name').readAsBytesSync());

String _hash(final List<int> bytes) => sha256.convert(bytes).toString();

void _expectGolden(final TiffBook book, final String name) {
  final expected = tiledTiffGoldens[name]!;
  expect(book.pageCount, expected.length, reason: '$name page count');
  for (var page = 0; page < expected.length; page++) {
    expect(_hash(book.pages[page].image.content), expected[page], reason: '$name page ${page + 1}');
  }
}

/// Reads pixel (x, y) of a page BMP as its red channel (gray value for
/// gray pages); BMP rows are bottom-up.
int _gray(final TiffPage page, final int x, final int y) {
  final bmp = page.image.content;
  final header = ByteData.sublistView(bmp).getUint32(10, Endian.little);
  final stride = (page.width * 3 + 3) & ~3;
  return bmp[header + (page.height - 1 - y) * stride + x * 3 + 2];
}

Matcher _throwsTiff([final String? messagePart]) => throwsA(
  isA<TiffException>().having(
    (final e) => e.message,
    'message',
    messagePart == null ? anything : contains(messagePart),
  ),
);

Matcher _throwsUnsupported([final String? messagePart]) => throwsA(
  isA<TiffUnsupportedCodecException>().having(
    (final e) => e.message,
    'message',
    messagePart == null ? anything : contains(messagePart),
  ),
);

void main() {
  late Map<String, Map<String, Object?>> manifest;
  setUpAll(() {
    final decoded =
        json.decode(File('$_tiledDir/manifest.json').readAsStringSync()) as Map<String, Object?>;
    manifest = {
      for (final entry in (decoded['files']! as List).cast<Map<String, Object?>>())
        entry['name']! as String: entry,
    };
  });

  group('TT01 public entry points open tiled pages', () {
    test('Unseal.parse and Unseal.read open classic and BigTIFF tiled files', () async {
      final classic = Unseal.parse(_fixture('cramps-tile.tif')) as TiffBook;
      expect(classic.isBigTiff, isFalse);
      expect((classic.pages.single.width, classic.pages.single.height), (800, 607));
      expect(classic.format, BookFormat.tiff);
      expect(classic.readingOrder.single.isHtml, isTrue);
      expect(sniffImageType(classic.cover.content), ImageType.bmp);
      final big = await Unseal.read(_fixture('gray8-zip2-t16-big.tif')) as TiffBook;
      expect(big.isBigTiff, isTrue);
      expect((big.pages.single.width, big.pages.single.height), (100, 75));
      _expectGolden(classic, 'cramps-tile.tif');
      _expectGolden(big, 'gray8-zip2-t16-big.tif');
    });

    test('the TIFF entry point and metadata reader accept tiled files', () {
      final book = tiff.parseTiffBook(_fixture('quad-tile.tif'));
      expect(book, isA<tiff.TiffBook>());
      expect(book.pageCount, 1);
      expect(book.files.images.single.type, 'bmp');
      expect(book.files.html.single.content, contains('width="512" height="384"'));
      final metadata = tiff.readTiffMetadata(_fixture('rgb8-zip2-t32-big-be.tif'));
      expect(metadata.format, BookFormat.tiff);
      expect(detectFormat(_fixture('bilevel-g4-t32x16.tif')), DetectedFormat.tiff);
    });

    test('strip pages keep their public contract next to tiled ones', () {
      final mixed = Unseal.parse(_fixture('mixed-strip-tile-3page.tif')) as TiffBook;
      expect(mixed.pageCount, 3);
      // Page 1 is the 96x64 gray gradient of the strip corpus and keeps
      // its pre-existing golden.
      expect(
        _hash(mixed.pages[0].image.content),
        'cd042d93d8f190658420e7c3f94f734ed1e9de31a375560aa0d65893de49e7b1',
      );
      expect(mixed.readingOrder, hasLength(3));
      expect(mixed.files.images.map((final file) => file.path), [
        'images/page-1.bmp',
        'images/page-2.bmp',
        'images/page-3.bmp',
      ]);
      final strips = Unseal.parse(_stripFixture('rgb-lzw-predictor.tif')) as TiffBook;
      expect(
        _hash(strips.pages.single.image.content),
        '2fd30770f6c2eca0e5bd5449c737803eb00ce89484411d87b853a414a2313357',
      );
    });
  });

  group('TT02 corpus decodes to the libtiff-verified rasters', () {
    test('every comparable fixture of the tiled manifest matches its golden', () {
      var compared = 0;
      for (final entry in manifest.values) {
        final name = entry['name']! as String;
        final bytes = _fixture(name);
        expect(_hash(bytes), entry['sha256'], reason: '$name drifted from its manifest');
        if (!(entry['expectation']! as String).startsWith('compare')) continue;
        _expectGolden(Unseal.parse(bytes) as TiffBook, name);
        compared++;
      }
      expect(compared, tiledTiffGoldens.length);
      expect(compared, greaterThanOrEqualTo(45));
    });

    test('independent SGI files address tiles through the strip tags', () {
      final cramps = Unseal.parse(_fixture('cramps-tile.tif')) as TiffBook;
      final strips = Unseal.parse(_fixture('cramps.tif')) as TiffBook;
      // The strip twin is PackBits with the same pixels: identical rasters.
      expect(_hash(cramps.pages.single.image.content), _hash(strips.pages.single.image.content));
      // min-is-white gray: the stored sample 0 displays as white.
      expect(_gray(cramps.pages.single, 0, 0), greaterThan(200));
    });
  });

  group('TT03 tile geometry', () {
    test('edge tiles crop to the declared dimensions with the right pixels', () {
      final book = Unseal.parse(_fixture('gray8-none-t16-le.tif')) as TiffBook;
      final page = book.pages.single;
      expect((page.width, page.height), (100, 75));
      // The source gradient is `(x*3 + y*5) & 0xFF`; probe the padding
      // corner and both edges.
      for (final (x, y) in const [(0, 0), (99, 74), (96, 64), (99, 0), (0, 74), (50, 37)]) {
        expect(_gray(page, x, y), (x * 3 + y * 5) & 0xFF, reason: '($x, $y)');
      }
    });

    test('images smaller than one tile, exactly one tile, and 1x1', () {
      final tiny = Unseal.parse(_fixture('gray8-tiny-7x5-t16.tif')) as TiffBook;
      expect((tiny.pages.single.width, tiny.pages.single.height), (7, 5));
      expect(_gray(tiny.pages.single, 6, 4), (6 * 3 + 4 * 5 + 11) & 0xFF);
      final one = Unseal.parse(_fixture('gray8-1x1-t16-big.tif')) as TiffBook;
      expect((one.pages.single.width, one.pages.single.height), (1, 1));
      expect(one.isBigTiff, isTrue);
      expect(_gray(one.pages.single, 0, 0), 200);
      final exact = Unseal.parse(_fixture('rgb8-exact-32x32-t32.tif')) as TiffBook;
      expect((exact.pages.single.width, exact.pages.single.height), (32, 32));
      final tall = Unseal.parse(_fixture('gray8-t16x64.tif')) as TiffBook;
      expect(_gray(tall.pages.single, 99, 74), (99 * 3 + 74 * 5) & 0xFF);
    });

    test('both byte orders and BigTIFF decode the same pixels', () {
      final le = Unseal.parse(_fixture('gray8-none-t16-le.tif')) as TiffBook;
      final be = Unseal.parse(_fixture('gray8-packbits-t16-be.tif')) as TiffBook;
      final big = Unseal.parse(_fixture('gray8-zip2-t16-big.tif')) as TiffBook;
      expect(_hash(be.pages.single.image.content), _hash(le.pages.single.image.content));
      expect(_hash(big.pages.single.image.content), _hash(le.pages.single.image.content));
      final gray16Le = Unseal.parse(_fixture('gray16-lzw2-t16-le.tif')) as TiffBook;
      final gray16Be = Unseal.parse(_fixture('gray16-none-t16-be.tif')) as TiffBook;
      final gray16Big = Unseal.parse(_fixture('gray16-zip2-t16-big-be.tif')) as TiffBook;
      expect(
        _hash(gray16Be.pages.single.image.content),
        _hash(gray16Le.pages.single.image.content),
      );
      expect(
        _hash(gray16Big.pages.single.image.content),
        _hash(gray16Le.pages.single.image.content),
      );
    });

    test('64-bit BigTIFF tile addresses (LONG8) decode in both byte orders', () {
      for (final endian in [Endian.little, Endian.big]) {
        final bytes = buildTiledGrayTiff(
          width: 37,
          height: 21,
          tileWidth: 16,
          tileLength: 16,
          bigTiff: true,
          endian: endian,
          long8Addresses: true,
        );
        final book = Unseal.parse(bytes) as TiffBook;
        expect(book.isBigTiff, isTrue);
        expect(_gray(book.pages.single, 36, 20), grayPattern(36, 20));
        expect(_gray(book.pages.single, 0, 0), grayPattern(0, 0));
      }
    });

    test('tile addresses under StripOffsets/StripByteCounts decode like tile tags', () {
      final tileTags =
          Unseal.parse(buildTiledGrayTiff(width: 40, height: 30, tileWidth: 16, tileLength: 16))
              as TiffBook;
      final stripTags =
          Unseal.parse(
                buildTiledGrayTiff(
                  width: 40,
                  height: 30,
                  tileWidth: 16,
                  tileLength: 16,
                  useStripTags: true,
                ),
              )
              as TiffBook;
      expect(
        _hash(stripTags.pages.single.image.content),
        _hash(tileTags.pages.single.image.content),
      );
    });

    test('tile widths that are not multiples of 16 are read as libtiff reads them', () {
      final book =
          Unseal.parse(buildTiledGrayTiff(width: 50, height: 45, tileWidth: 20, tileLength: 20))
              as TiffBook;
      for (final (x, y) in const [(0, 0), (49, 44), (20, 20), (39, 19), (40, 40)]) {
        expect(_gray(book.pages.single, x, y), grayPattern(x, y), reason: '($x, $y)');
      }
    });

    test('multi-IFD documents keep order, geometry, and per-page layout', () {
      final mixed = Unseal.parse(_fixture('mixed-strip-tile-3page.tif')) as TiffBook;
      expect(mixed.pages.map((final page) => (page.width, page.height)).toList(), [
        (96, 64),
        (100, 75),
        (128, 96),
      ]);
      _expectGolden(mixed, 'mixed-strip-tile-3page.tif');
      expect(mixed.pages[1].dpi, 72);
      final big = Unseal.parse(_fixture('mixed-big-be-2page.tif')) as TiffBook;
      expect(big.isBigTiff, isTrue);
      expect(big.pages.map((final page) => (page.width, page.height)).toList(), [
        (96, 64),
        (100, 75),
      ]);
      _expectGolden(big, 'mixed-big-be-2page.tif');
      final sgi = Unseal.parse(_fixture('quad-tile.tif')) as TiffBook;
      expect(_hash(big.pages[0].image.content), isNot(_hash(sgi.pages.single.image.content)));
    });
  });

  group('TT04 codec and layout matrix', () {
    const matrix = <String, List<String>>{
      'gray8': [
        'gray8-none-t16-le.tif',
        'gray8-packbits-t16-be.tif',
        'gray8-lzw-t32.tif',
        'gray8-lzw2-t32-be.tif',
        'gray8-zip-t16.tif',
        'gray8-zip2-t16-big.tif',
      ],
      'rgb8': [
        'rgb8-none-t16.tif',
        'rgb8-packbits-t32-be.tif',
        'rgb8-lzw2-t16.tif',
        'rgb8-zip2-t32-big-be.tif',
      ],
      'gray16': ['gray16-none-t16-be.tif', 'gray16-lzw2-t16-le.tif', 'gray16-zip2-t16-big-be.tif'],
      'bilevel': [
        'bilevel-none-t32.tif',
        'bilevel-packbits-t16.tif',
        'bilevel-lzw-t64-be.tif',
        'bilevel-g4-t32x16.tif',
        'bilevel-g4-t16-edge-be.tif',
        'bilevel-g3-t32x16-be.tif',
        'bilevel-g3-2d-fill-t32x16.tif',
        'bilevel-mh-t32x16.tif',
        'bilevel-mh-t16-edge.tif',
      ],
      'extra depths': ['gray4-none-t16.tif', 'gray2-lzw-t16-be.tif', 'rgb16-zip2-t16.tif'],
      'real sources': [
        'cramps-lzw2-t64.tif',
        'quad-zip2-t32-big.tif',
        'ladoga-zip2-t16.tif',
        'ladoga-lzw2-t32-be.tif',
        'fax2d-g4-t64.tif',
        'fax2d-mh-t128x64-be.tif',
        'fax2d-g3-2d-t64.tif',
      ],
    };

    matrix.forEach((final layout, final names) {
      test('$layout layouts decode to their libtiff-verified rasters', () {
        for (final name in names) {
          _expectGolden(Unseal.parse(_fixture(name)) as TiffBook, name);
        }
      });
    });

    test('every codec of one layout yields the same pixels', () {
      String raster(final String name) =>
          _hash((Unseal.parse(_fixture(name)) as TiffBook).pages.single.image.content);
      final gray = raster('gray8-none-t16-le.tif');
      for (final name in matrix['gray8']!) {
        expect(raster(name), gray, reason: name);
      }
      final bilevel = raster('bilevel-none-t32.tif');
      for (final name in [
        'bilevel-g4-t32x16.tif',
        'bilevel-g3-t32x16-be.tif',
        'bilevel-g3-2d-fill-t32x16.tif',
        'bilevel-mh-t32x16.tif',
      ]) {
        expect(raster(name), bilevel, reason: name);
      }
      // The same text page in the strip corpus (Group 4 strips, page 1).
      expect(bilevel, 'cc92122824b4596f61f2e4a3bca0dfb345fe445665aec0c07c1a573285be34e3');
    });

    test('CCITT tiles decode with the tile width, not the page width', () {
      final tiled = Unseal.parse(_fixture('bilevel-g4-t16-edge-be.tif')) as TiffBook;
      final packbits = Unseal.parse(_fixture('bilevel-packbits-t16.tif')) as TiffBook;
      expect(_hash(tiled.pages.single.image.content), _hash(packbits.pages.single.image.content));
      // Ink is black on a min-is-white page: the box border at (12, 56).
      expect(_gray(tiled.pages.single, 12, 56), 0);
      expect(_gray(tiled.pages.single, 0, 0), 255);
    });

    test('modified Huffman rows align to bytes without dropping buffered data', () {
      final strips = Unseal.parse(_fixture('bilevel-mh-strips.tif')) as TiffBook;
      final tiles = Unseal.parse(_fixture('bilevel-mh-t32x16.tif')) as TiffBook;
      final reference = Unseal.parse(_fixture('bilevel-none-t32.tif')) as TiffBook;
      expect(_hash(strips.pages.single.image.content), _hash(reference.pages.single.image.content));
      expect(_hash(tiles.pages.single.image.content), _hash(reference.pages.single.image.content));
    });

    test('gray16 keeps the high byte with 16-bit predictor carries intact', () {
      final page = (Unseal.parse(_fixture('gray16-zip2-t16-big-be.tif')) as TiffBook).pages.single;
      for (final (x, y) in const [(0, 0), (20, 0), (95, 63), (47, 31), (21, 5)]) {
        expect(_gray(page, x, y), ((x * 13 + y * 97) & 0xFFFF) >> 8, reason: '($x, $y)');
      }
      final ladoga = Unseal.parse(_fixture('ladoga.tif')) as TiffBook;
      final ladogaTiles = Unseal.parse(_fixture('ladoga-lzw2-t32-be.tif')) as TiffBook;
      expect(
        _hash(ladogaTiles.pages.single.image.content),
        _hash(ladoga.pages.single.image.content),
      );
    });

    test('orientations 2-4 flip the raster to top-left; 5-8 fail typed', () {
      final upright = (Unseal.parse(_fixture('gray8-lzw-t32.tif')) as TiffBook).pages.single;
      final mirrored = (Unseal.parse(_fixture('gray8-o2-t16.tif')) as TiffBook).pages.single;
      final rotated = (Unseal.parse(_fixture('gray8-o3-t16.tif')) as TiffBook).pages.single;
      final flipped = (Unseal.parse(_fixture('gray8-o4-t16-be.tif')) as TiffBook).pages.single;
      for (final (x, y) in const [(0, 0), (99, 74), (3, 70), (64, 10)]) {
        final stored = _gray(upright, x, y);
        expect(_gray(mirrored, 99 - x, y), stored, reason: 'orientation 2 ($x, $y)');
        expect(_gray(rotated, 99 - x, 74 - y), stored, reason: 'orientation 3 ($x, $y)');
        expect(_gray(flipped, x, 74 - y), stored, reason: 'orientation 4 ($x, $y)');
      }
      final rgbUpright = (Unseal.parse(_fixture('rgb8-lzw2-t16.tif')) as TiffBook).pages.single;
      final rgbRotated = (Unseal.parse(_fixture('rgb8-o3-t32.tif')) as TiffBook).pages.single;
      expect(_gray(rgbRotated, 0, 0), _gray(rgbUpright, 99, 74));
      final g4Upright = (Unseal.parse(_fixture('bilevel-g4-t32x16.tif')) as TiffBook).pages.single;
      final g4Mirrored =
          (Unseal.parse(_fixture('bilevel-g4-o2-t32x16.tif')) as TiffBook).pages.single;
      expect(_gray(g4Mirrored, 127 - 12, 56), _gray(g4Upright, 12, 56));
      for (final orientation in const [5, 6, 7, 8]) {
        expect(
          () => Unseal.parse(_fixture('gray8-o$orientation-t16.tif')),
          _throwsUnsupported('Orientation $orientation'),
          reason: 'orientation $orientation',
        );
      }
    });

    test('FillOrder 2 and tiled JPEG fail typed for every codec', () {
      expect(
        () => Unseal.parse(_fixture('bilevel-none-fill2-t32.tif')),
        _throwsUnsupported('FillOrder 2'),
      );
      expect(() => Unseal.parse(_fixture('fax2d.tif')), _throwsUnsupported('FillOrder 2'));
      expect(() => Unseal.parse(_fixture('zackthecat.tif')), _throwsUnsupported('old-style JPEG'));
      expect(() => Unseal.parse(_stripFixture('quad-tile.jpg.tiff')), _throwsUnsupported('tiled'));
    });

    test('normatively invalid layouts fail typed as malformed, not as codecs', () {
      // RGB with sub-byte samples and multi-sample sub-byte pages.
      expect(
        () => Unseal.parse(
          buildTiledGrayTiff(
            width: 8,
            height: 8,
            tileWidth: 16,
            tileLength: 16,
            bits: 4,
            extra: [SyntheticTiffTag.short(262, 2)],
          ),
        ),
        _throwsTiff('sub-byte'),
      );
      // Predictor 2 on a 4-bit page and SampleFormat 3 (float).
      expect(
        () => Unseal.parse(
          buildTiledGrayTiff(
            width: 8,
            height: 8,
            tileWidth: 16,
            tileLength: 16,
            bits: 4,
            extra: [SyntheticTiffTag.short(317, 2)],
          ),
        ),
        _throwsUnsupported('sub-byte sample depth'),
      );
      expect(
        () => Unseal.parse(
          buildTiledGrayTiff(
            width: 8,
            height: 8,
            tileWidth: 16,
            tileLength: 16,
            extra: [SyntheticTiffTag.short(339, 3)],
          ),
        ),
        _throwsUnsupported('SampleFormat 3'),
      );
      // SampleFormat 4 (void) reads as unsigned, as libtiff does.
      final void4 =
          Unseal.parse(
                buildTiledGrayTiff(
                  width: 8,
                  height: 8,
                  tileWidth: 16,
                  tileLength: 16,
                  extra: [SyntheticTiffTag.short(339, 4)],
                ),
              )
              as TiffBook;
      expect(_gray(void4.pages.single, 7, 7), grayPattern(7, 7));
    });
  });

  group('TT05 hostile tile layouts fail typed before any raster or tile allocation', () {
    Uint8List base({
      final List<int>? offsets,
      final List<int>? counts,
      final Set<int> omit = const {},
      final bool useStripTags = false,
      final List<SyntheticTiffTag> extra = const [],
      final int tileWidth = 16,
      final int tileLength = 16,
      final int width = 40,
      final int height = 30,
    }) => buildTiledGrayTiff(
      width: width,
      height: height,
      tileWidth: tileWidth,
      tileLength: tileLength,
      tileOffsets: offsets,
      tileByteCounts: counts,
      omit: omit,
      useStripTags: useStripTags,
      extra: extra,
    );

    test('missing offset or count arrays', () {
      expect(() => Unseal.parse(base(omit: {324})), _throwsTiff('TileOffsets'));
      expect(() => Unseal.parse(base(omit: {325})), _throwsTiff('TileByteCounts'));
      expect(() => Unseal.parse(base(omit: {323})), _throwsTiff('TileLength'));
      expect(() => Unseal.parse(base(omit: {322})), _throwsTiff('TileWidth'));
    });

    test('array lengths that disagree with the tile grid', () {
      final good = Unseal.parse(base()) as TiffBook;
      expect(good.pageCount, 1);
      final offsets = <int>[for (var i = 0; i < 5; i++) 1000 + i * 256];
      expect(() => Unseal.parse(base(offsets: offsets)), _throwsTiff('offsets'));
      expect(() => Unseal.parse(base(counts: [256])), _throwsTiff('byte counts'));
    });

    test('zero, truncated, and out-of-file ranges', () {
      final counts = List<int>.filled(6, 256)..[2] = 0;
      expect(() => Unseal.parse(base(counts: counts)), _throwsTiff('invalid offset or byte count'));
      final truncated = List<int>.filled(6, 256)..[5] = 1 << 20;
      expect(() => Unseal.parse(base(counts: truncated)), _throwsTiff('beyond the file bounds'));
      final beyond = base();
      final farOffsets = <int>[for (var i = 0; i < 6; i++) beyond.length + i];
      expect(() => Unseal.parse(base(offsets: farOffsets)), _throwsTiff('beyond the file bounds'));
    });

    test('tiles overlapping each other, the header, or the directory', () {
      final document = base();
      final dataOffset = document.length - 6 * 256;
      final overlapping = <int>[for (var i = 0; i < 6; i++) dataOffset + i * 200];
      expect(() => Unseal.parse(base(offsets: overlapping)), _throwsTiff('overlap'));
      final header = <int>[for (var i = 0; i < 6; i++) i == 0 ? 2 : dataOffset + i * 256];
      expect(() => Unseal.parse(base(offsets: header)), _throwsTiff('file header'));
      final directory = <int>[for (var i = 0; i < 6; i++) i == 0 ? 10 : dataOffset + i * 256];
      expect(() => Unseal.parse(base(offsets: directory)), _throwsTiff('directory table'));
      // Sharing bytes across pages is allowed; sharing within a page is not.
      final shared = buildSharedTileDocument(
        pages: 2,
        width: 4,
        height: 4,
        tileWidth: 16,
        tileLength: 16,
      );
      expect((Unseal.parse(shared) as TiffBook).pageCount, 2);
    });

    test('excessive or overflowing geometry', () {
      expect(
        () => Unseal.parse(base(extra: [SyntheticTiffTag.long(322, 0)])),
        _throwsTiff('Invalid TIFF tile dimensions'),
      );
      expect(
        () => Unseal.parse(base(extra: [SyntheticTiffTag.long(322, 0xFFFFFFFF)])),
        _throwsTiff('tile dimensions'),
      );
      expect(
        () => Unseal.parse(
          base(extra: [SyntheticTiffTag.long(322, 20000), SyntheticTiffTag.long(323, 20000)]),
        ),
        _throwsTiff('256-megapixel'),
      );
      expect(
        () => Unseal.parse(base(extra: [SyntheticTiffTag.long(256, 0xFFFFFFFF)])),
        _throwsTiff('page dimensions'),
      );
      // 256,000,000 one-pixel-wide columns of tiles exceed the segment cap.
      expect(
        () => Unseal.parse(
          base(
            extra: [
              SyntheticTiffTag.long(256, 256000000),
              SyntheticTiffTag.long(257, 1),
              SyntheticTiffTag.long(322, 1),
            ],
          ),
        ),
        _throwsTiff('strip count limit'),
      );
    });

    test('a tile footprint the budget cannot hold is refused before decoding', () {
      // 1x1 page whose single Deflate tile would need 128 MiB of scratch;
      // the 23-byte stream is never inflated.
      final stream = Uint8List.fromList(const ZLibEncoder().encodeBytes(Uint8List(16)));
      final bomb = buildTiledGrayTiff(
        width: 1,
        height: 1,
        tileWidth: 16384,
        tileLength: 8192,
        compression: 8,
        data: stream,
      );
      expect(bomb.length, lessThan(512));
      expect(() => Unseal.parse(bomb), _throwsTiff('scratch buffers exceed'));
    });

    test('short segments fail typed and over-long streams stop at the footprint', () {
      // A Deflate tile holding fewer bytes than its footprint.
      final short = Uint8List.fromList(const ZLibEncoder().encodeBytes(Uint8List(100)));
      expect(
        () => Unseal.parse(
          buildTiledGrayTiff(
            width: 16,
            height: 16,
            tileWidth: 16,
            tileLength: 16,
            compression: 8,
            data: short,
          ),
        ),
        _throwsTiff('decompressed to 100 bytes'),
      );
      // A Deflate tile whose stream would expand to 8 MiB: inflation stops
      // at the 256-byte footprint and the visible pixels are correct.
      final pattern = Uint8List(8 << 20);
      for (var index = 0; index < 256; index++) {
        pattern[index] = index;
      }
      final bombStream = Uint8List.fromList(const ZLibEncoder().encodeBytes(pattern));
      final book =
          Unseal.parse(
                buildTiledGrayTiff(
                  width: 16,
                  height: 16,
                  tileWidth: 16,
                  tileLength: 16,
                  compression: 8,
                  data: bombStream,
                ),
              )
              as TiffBook;
      expect(_gray(book.pages.single, 15, 15), 255);
      expect(_gray(book.pages.single, 1, 0), 1);
      // An uncompressed tile shorter than its footprint.
      expect(
        () => Unseal.parse(
          buildTiledGrayTiff(
            width: 16,
            height: 16,
            tileWidth: 16,
            tileLength: 16,
            data: Uint8List(200),
          ),
        ),
        _throwsTiff('holds 200 bytes'),
      );
    });
  });

  group('TT06 cumulative budget', () {
    test('pixels, resident bytes, scratch, and work are independent guards', () {
      final budget = TiffDecodeBudget();
      budget.reserve(pixels: tiffMaxDecodedPixelsPerBook, rasterBytes: 1);
      expect(() => budget.reserve(pixels: 1, rasterBytes: 0), _throwsTiff('256-megapixel'));
      budget.reserve(pixels: 0, rasterBytes: tiffMaxDecodedRasterBytesPerBook - 1 - 1024);
      expect(() => budget.reserveScratch(2048), _throwsTiff('scratch buffers'));
      budget.reserveScratch(1024);
      expect(() => budget.reserve(pixels: 0, rasterBytes: 1), _throwsTiff('128 MiB'));
      budget.releaseScratch(1024);
      budget.reserve(pixels: 0, rasterBytes: 1);
      expect(() => budget.releaseScratch(1), _throwsTiff('budget release'));
      budget.reserveWork(tiffMaxDecodedWorkBytesPerBook);
      expect(() => budget.reserveWork(1), _throwsTiff('decode-work'));
      expect(budget.workBytes, tiffMaxDecodedWorkBytesPerBook);
      expect(budget.scratchBytes, 0);
      expect(() => budget.reserve(pixels: -1, rasterBytes: 0), _throwsTiff('Invalid'));
    });

    test('temporary tiles are charged as work even when the page keeps almost nothing', () {
      // Each 1x1 page decodes one 8192x8192 Deflate tile: 64 MiB of work
      // for a 58-byte BMP. Eight pages fit the 512 MiB work cap; the ninth
      // fails before its tile is inflated.
      final eight = buildSharedTileDocument(
        pages: 8,
        width: 1,
        height: 1,
        tileWidth: 8192,
        tileLength: 8192,
      );
      final book = Unseal.parse(eight) as TiffBook;
      expect(book.pageCount, 8);
      expect(book.pages.every((final page) => page.image.content.length < 100), isTrue);
      final nine = buildSharedTileDocument(
        pages: 9,
        width: 1,
        height: 1,
        tileWidth: 8192,
        tileLength: 8192,
      );
      expect(() => Unseal.parse(nine), _throwsTiff('decode-work limit'));
    });

    test('materialized pages accumulate against the resident cap', () {
      // 2048x2048 gray pages share one uncompressed tile: BMPs of 12.6 MB
      // each. Nine pages plus the live RGB conversion fit 128 MiB; the
      // tenth page is refused before its raster exists.
      Uint8List document(final int pages) {
        final tile = Uint8List(2048 * 2048);
        return buildSyntheticTiff(
          data: tile,
          pages: (final dataOffset) => [
            for (var page = 0; page < pages; page++)
              [
                SyntheticTiffTag.long(256, 2048),
                SyntheticTiffTag.long(257, 2048),
                SyntheticTiffTag.short(258, 8),
                SyntheticTiffTag.short(259, 1),
                SyntheticTiffTag.short(262, 1),
                SyntheticTiffTag.short(277, 1),
                SyntheticTiffTag.long(322, 2048),
                SyntheticTiffTag.long(323, 2048),
                SyntheticTiffTag.long(324, dataOffset),
                SyntheticTiffTag.long(325, tile.length),
              ],
          ],
        );
      }

      final nine = Unseal.parse(document(9)) as TiffBook;
      expect(nine.pageCount, 9);
      expect(() => Unseal.parse(document(10)), _throwsTiff('128 MiB decoded-image byte limit'));
    });

    test('a JPEG passthrough page counts toward the same resident cap', () {
      final budget = TiffDecodeBudget();
      budget.reserve(pixels: 0, rasterBytes: tiffMaxDecodedRasterBytesPerBook);
      expect(() => budget.reserveScratch(1), _throwsTiff('scratch'));
    });
  });

  group('TT07 the browser lane decodes the same bytes', () {
    test('embedded fixtures are byte-identical to the tracked files', () {
      expect(embeddedTiledTiffFixtures, isNotEmpty);
      embeddedTiledTiffFixtures.forEach((final name, final bytes) {
        expect(_hash(bytes), manifest[name]!['sha256'], reason: name);
        expect(bytes, _fixture(name), reason: name);
      });
    });

    test('embedded fixtures decode to the shared goldens on the VM', () {
      embeddedTiledTiffFixtures.forEach((final name, final bytes) {
        _expectGolden(Unseal.parse(bytes) as TiffBook, name);
      });
    });

    test('the strip corpus and its typed failures are unchanged', () {
      const goldens = <String, String>{
        'gray-none-2page-le.tif':
            'cd042d93d8f190658420e7c3f94f734ed1e9de31a375560aa0d65893de49e7b1',
        'testfax4.tiff': 'f867f4429df1a7ac5854acbb1420dbfe46c55002e5c21c109a1f9e802308c996',
        'quad-lzw-compat.tiff': '87a17cb926cfdaecb43f778d72e883c4963d2d407aaf39fbeb47faa884ba26f8',
        'tiff_with_subifd_chain.tif':
            'bf30e211d7622417762bf017c55cf2d2dd424a9adc30fb91f66179507bd4dfcb',
        'rgb-3c-8b.tiff': '2a646d1e14a4155a9b1cd91604dc9f6d9506fa2776147b9c488a0ce905b53abe',
      };
      goldens.forEach((final name, final golden) {
        expect(
          _hash((Unseal.parse(_stripFixture(name)) as TiffBook).pages.first.image.content),
          golden,
          reason: name,
        );
      });
      expect(
        () => Unseal.parse(_stripFixture('palette-1c-8b.tiff')),
        _throwsUnsupported('palette'),
      );
      expect(() => Unseal.parse(_stripFixture('test_ifd_loop_to_self.tif')), _throwsTiff('cycle'));
    });
  });

  group('TT08 corpus integrity', () {
    test('every manifest entry is tracked with its hash and expectation', () {
      final files = Directory(_tiledDir)
          .listSync()
          .whereType<File>()
          .map((final file) => file.uri.pathSegments.last)
          .where((final name) => name.endsWith('.tif') || name.endsWith('.tiff'))
          .toSet();
      expect(files, manifest.keys.toSet());
      for (final entry in manifest.values) {
        expect(entry['producer'], isNotEmpty);
        expect(entry['layout'], isNotEmpty);
        expect(
          ['compare', 'compare-native'].contains(entry['expectation']) ||
              (entry['expectation']! as String).startsWith('reject:'),
          isTrue,
        );
      }
    });
  });
}
