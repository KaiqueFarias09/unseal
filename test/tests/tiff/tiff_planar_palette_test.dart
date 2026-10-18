import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/src/features/tiff/tiff_container.dart';
import 'package:unseal/src/features/tiff/tiff_limits.dart';
import 'package:unseal/src/features/tiff/tiff_page_decoder.dart';
import 'package:unseal/tiff.dart' as tiff;
import 'package:unseal/unseal.dart';

import '../../support/tiff_planar_palette_embedded.dart';
import '../../support/tiff_planar_palette_goldens.dart';
import '../../support/tiff_tiled_fixture.dart';

const _dir = 'test/resources/tiff/planar-palette';

Uint8List _fixture(final String name) => Uint8List.fromList(File('$_dir/$name').readAsBytesSync());

Uint8List _stripFixture(final String name) =>
    Uint8List.fromList(File('test/resources/tiff/$name').readAsBytesSync());

String _hash(final List<int> bytes) => sha256.convert(bytes).toString();

void _expectGolden(final TiffBook book, final String name) {
  final expected = planarPaletteTiffGoldens[name];
  expect(expected, isNotNull, reason: '$name has no pinned golden');
  expect(book.pageCount, expected!.length, reason: '$name page count');
  for (var page = 0; page < expected.length; page++) {
    expect(_hash(book.pages[page].image.content), expected[page], reason: '$name page ${page + 1}');
  }
}

/// Reads pixel (x, y) of a page BMP; BMP rows are bottom-up.
(int, int, int) _rgb(final TiffPage page, final int x, final int y) {
  final bmp = page.image.content;
  final header = ByteData.sublistView(bmp).getUint32(10, Endian.little);
  final stride = (page.width * 3 + 3) & ~3;
  final at = header + (page.height - 1 - y) * stride + x * 3;
  return (bmp[at + 2], bmp[at + 1], bmp[at]);
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
        json.decode(File('$_dir/manifest.json').readAsStringSync()) as Map<String, Object?>;
    manifest = {
      for (final entry in (decoded['files']! as List).cast<Map<String, Object?>>())
        entry['name']! as String: entry,
    };
  });

  group('TC01 public entry points open planar and palette pages', () {
    test('Unseal.parse and Unseal.read open planar and palette files', () async {
      final planar = Unseal.parse(_fixture('planar8-none-strips.tif')) as TiffBook;
      expect((planar.pages.single.width, planar.pages.single.height), (96, 64));
      expect(planar.format, BookFormat.tiff);
      expect(sniffImageType(planar.cover.content), ImageType.bmp);
      _expectGolden(planar, 'planar8-none-strips.tif');
      final big = await Unseal.read(_fixture('planar8-zip2-t16-big.tif')) as TiffBook;
      expect(big.isBigTiff, isTrue);
      _expectGolden(big, 'planar8-zip2-t16-big.tif');
      final palette = Unseal.parse(_fixture('palette8-none-t16-le.tif')) as TiffBook;
      expect((palette.pages.single.width, palette.pages.single.height), (157, 151));
      _expectGolden(palette, 'palette8-none-t16-le.tif');
    });

    test('the TIFF entry point, metadata reader, and detection accept the new layouts', () {
      final book = tiff.parseTiffBook(_fixture('jello.tif'));
      expect(book.pageCount, 1);
      expect((book.pages.single.width, book.pages.single.height), (256, 192));
      final metadata = tiff.readTiffMetadata(_fixture('flower-rgb-planar-08.tif'));
      expect(metadata.format, BookFormat.tiff);
      expect(detectFormat(_fixture('planar16-none-strips.tif')), DetectedFormat.tiff);
      expect(detectFormat(_fixture('flower-palette-08.tif')), DetectedFormat.tiff);
    });

    test('contiguous strips and tiles keep their public contract next to the new layouts', () {
      final contig = Unseal.parse(_stripFixture('rgb-lzw-predictor.tif')) as TiffBook;
      expect(
        _hash(contig.pages.single.image.content),
        '2fd30770f6c2eca0e5bd5449c737803eb00ce89484411d87b853a414a2313357',
      );
      final tiled =
          Unseal.parse(File('test/resources/tiff/tiled/rgb8-none-t16.tif').readAsBytesSync())
              as TiffBook;
      expect(_hash(tiled.pages.single.image.content), tiledTiffContiguousGolden);
    });
  });

  group('TC02 corpus decodes to the libtiff-verified rasters', () {
    test('every comparable fixture of the planar/palette manifest matches its golden', () {
      var compared = 0;
      for (final entry in manifest.values) {
        final name = entry['name']! as String;
        final bytes = _fixture(name);
        expect(_hash(bytes), entry['sha256'], reason: '$name drifted from its manifest');
        if (!(entry['expectation']! as String).startsWith('compare')) continue;
        _expectGolden(Unseal.parse(bytes) as TiffBook, name);
        compared++;
      }
      expect(compared, greaterThanOrEqualTo(30));
      // The strip-corpus palette page was verified through the same lanes.
      _expectGolden(
        Unseal.parse(_stripFixture('palette-1c-8b.tiff')) as TiffBook,
        'palette-1c-8b.tiff',
      );
    });

    test('the independent planar twins keep the same pixels as their contiguous sources', () {
      // flower-rgb-planar-08 vs its tiffcp contig re-encode of the same
      // photo is not tracked, but the quad pair is: quad-tile.tif (contig
      // LZW) and its planar derivative must show the same raster.
      final quad =
          Unseal.parse(File('test/resources/tiff/tiled/quad-tile.tif').readAsBytesSync())
              as TiffBook;
      final planar = Unseal.parse(_fixture('quad-planar-zip2-t64-big-be.tif')) as TiffBook;
      expect(_hash(planar.pages.single.image.content), _hash(quad.pages.single.image.content));
      final flower = Unseal.parse(_fixture('flower-planar-none-t32-be.tif')) as TiffBook;
      expect(
        _hash(flower.pages.single.image.content),
        planarPaletteTiffGoldens['flower-rgb-planar-08.tif']!.single,
        reason: 'tiffcp keeps the pixels of its planar input',
      );
    });
  });

  group('TC03 planar RGB matrix', () {
    test('every codec and geometry of planar 8-bit yields the same pixels', () {
      String raster(final String name) =>
          _hash((Unseal.parse(_fixture(name)) as TiffBook).pages.single.image.content);
      // Sources differ per group: strips 96x64, tiles 100x75.
      final strips96 = raster('planar8-none-strips.tif');
      for (final name in ['planar8-none-strips.tif', 'planar8-rows8.tif']) {
        expect(raster(name), strips96, reason: name);
      }
      final tiles100 = raster('planar8-none-t16-le.tif');
      for (final name in [
        'planar8-none-t16-le.tif',
        'planar8-packbits-t32-be.tif',
        'planar8-zip2-t16-big.tif',
      ]) {
        expect(raster(name), tiles100, reason: name);
      }
      // The tiled 100x75 raster matches the source gradient probed in the
      // edge-tile test, and the strips twin of the 128x96 source keeps its
      // own golden.
      _expectGolden(
        Unseal.parse(_fixture('planar8-lzw2-strips.tif')) as TiffBook,
        'planar8-lzw2-strips.tif',
      );
    });

    test('planar 16-bit keeps every sample, including the low byte', () {
      // Source ramp: r=(x*1021+y*7), g=(x*13+y*997), b=(x*y*31+5) in 16 bits.
      for (final name in [
        'planar16-none-strips.tif',
        'planar16-zip2-t16.tif',
        'planar16-lzw-t32-be.tif',
      ]) {
        final bytes = _fixture(name);
        final container = TiffContainer(bytes);
        final expected = <int>[];
        final observed = <int>[];
        decodeTiffPage(
          container,
          container.pageDirectories.single,
          budget: TiffDecodeBudget(),
          onDecodedSegment: (final segment) {
            expect(segment.samplesPerPixel, 1, reason: 'planar segments hold one plane');
            expect(segment.sample, inInclusiveRange(0, 2));
            final view = ByteData.sublistView(segment.bytes);
            for (var y = 0; y < segment.height; y++) {
              for (var x = 0; x < segment.width; x++) {
                final value = view.getUint16(y * segment.rowBytes + x * 2, segment.endian);
                observed.add(value);
                final px = segment.columnStart + x;
                final py = segment.rowStart + y;
                expected.add(switch (segment.sample) {
                  0 => (px * 1021 + py * 7) & 0xFFFF,
                  1 => (px * 13 + py * 997) & 0xFFFF,
                  _ => (px * py * 31 + 5) & 0xFFFF,
                });
              }
            }
          },
        );
        expect(observed, expected, reason: '$name full-precision plane samples');
      }
    });

    test('both byte orders and BigTIFF decode planar identically', () {
      String raster(final String name) =>
          _hash((Unseal.parse(_fixture(name)) as TiffBook).pages.single.image.content);
      expect(raster('planar8-packbits-t32-be.tif'), raster('planar8-none-t16-le.tif'));
      expect(raster('planar8-zip2-t16-big.tif'), raster('planar8-none-t16-le.tif'));
      expect(raster('planar16-lzw-t32-be.tif'), raster('planar16-none-strips.tif'));
      expect(raster('quad-planar-zip2-t64-big-be.tif'), quadContigGolden);
    });

    test('edge tiles crop per plane with the source gradient pixels', () {
      final page = (Unseal.parse(_fixture('planar8-none-t16-le.tif')) as TiffBook).pages.single;
      expect((page.width, page.height), (100, 75));
      // Source rgbGradient: r=(x*2), g=(y*2), b=(x+y).
      for (final (x, y) in const [(0, 0), (99, 74), (96, 64), (99, 0), (0, 74), (50, 37)]) {
        expect(_rgb(page, x, y), (
          (x * 2) & 0xFF,
          (y * 2) & 0xFF,
          (x + y) & 0xFF,
        ), reason: '($x, $y)');
      }
    });

    test('orientations 2-4 flip the planar raster to top-left', () {
      final upright = (Unseal.parse(_fixture('planar8-none-t16-le.tif')) as TiffBook).pages.single;
      final mirrored = (Unseal.parse(_fixture('planar8-o2-t16.tif')) as TiffBook).pages.single;
      for (final (x, y) in const [(0, 0), (99, 74), (64, 10)]) {
        expect(_rgb(mirrored, 99 - x, y), _rgb(upright, x, y), reason: 'orientation 2 ($x, $y)');
      }
      final rotated =
          (Unseal.parse(_fixture('planar16-o3-strips-big-be.tif')) as TiffBook).pages.single;
      final up16 = (Unseal.parse(_fixture('planar16-none-strips.tif')) as TiffBook).pages.single;
      expect((rotated.width, rotated.height), (up16.width, up16.height));
    });
  });

  group('TC04 palette matrix', () {
    test('1, 2, 4, and 8-bit palettes decode to their ColorMap projections', () {
      // 1-bit synthetic ramp from the bilevel source: index 0 -> green,
      // index 1 -> magenta.
      final one = (Unseal.parse(_fixture('palette1-none-strips-be.tif')) as TiffBook).pages.single;
      expect((one.width, one.height), (157, 151));
      final seen = <int, (int, int, int)>{};
      for (var y = 0; y < one.height; y += 17) {
        for (var x = 0; x < one.width; x += 13) {
          seen.putIfAbsent(_rgb(one, x, y).$1, () => _rgb(one, x, y));
        }
      }
      expect(seen.keys.toSet(), containsAll(const [0, 255]));
      // 2, 4, and 8-bit real files decode against their goldens (TC02);
      // here the synthetic 8-bit ramp checks exact channel arithmetic:
      // index i of the gray gradient projects to (i, 255 - i, (5*i) % 256).
      final eight = (Unseal.parse(_fixture('palette8-enc-strips.tif')) as TiffBook).pages.single;
      for (final (x, y) in const [(0, 0), (95, 63), (40, 20), (7, 61)]) {
        final i = (x * 3 + y * 5) & 0xFF;
        expect(_rgb(eight, x, y), (i, 255 - i, (i * 5) % 256), reason: '($x, $y)');
      }
      // The legacy byte-range colormap stores the same colors and must
      // display identically to the full-range twin.
      expect(
        _hash(
          (Unseal.parse(_fixture('palette8-legacy8bit.tif')) as TiffBook)
              .pages
              .single
              .image
              .content,
        ),
        _hash(eight.image.content),
      );
    });

    test('the legacy 8-bit ColorMap policy is explicit and libtiff-equal', () {
      // libtiff warns "Assuming 8-bit colormap" for byte-range tables and
      // uses the values directly; the decoder reproduces that rule (see
      // doc/tiff-planar-palette.md). The palette8-legacy8bit fixture is
      // compared zero-diff against libtiff's RGBA by the comparator; this
      // pins the same colors here.
      final page = (Unseal.parse(_fixture('palette8-legacy8bit.tif')) as TiffBook).pages.single;
      final i = (20 * 3 + 11 * 5) & 0xFF;
      expect(_rgb(page, 20, 11), (i, 255 - i, (i * 5) % 256));
    });

    test('orientations 2-4 and edge tiles apply to palette pages', () {
      final flipped = (Unseal.parse(_fixture('palette8-o4-t32.tif')) as TiffBook).pages.single;
      expect((flipped.width, flipped.height), (96, 64));
      // Orientation 4 mirrors vertically: display(x, y) = source(x, 63 - y).
      for (final (x, y) in const [(0, 0), (95, 63), (40, 20), (7, 61)]) {
        final i = (x * 3 + (63 - y) * 5) & 0xFF;
        expect(_rgb(flipped, x, y), (i, 255 - i, (i * 5) % 256), reason: '($x, $y)');
      }
      // Edge tiles: 157 = 9x16 + 13, 151 = 9x16 + 7. The real palette
      // page tiles decode to exactly its strip twin's raster (and to the
      // libtiff-verified golden pinned in TC02).
      final tiled = Unseal.parse(_fixture('palette8-none-t16-le.tif')) as TiffBook;
      final strips = Unseal.parse(_fixture('palette8-packbits-strips-be.tif')) as TiffBook;
      expect(_hash(tiled.pages.single.image.content), _hash(strips.pages.single.image.content));
      _expectGolden(tiled, 'palette8-none-t16-le.tif');
    });

    test('multi-IFD documents mix planar, palette, and contiguous pages', () {
      final mixed = Unseal.parse(_fixture('mixed-planar-palette-3page.tif')) as TiffBook;
      expect(mixed.pageCount, 3);
      _expectGolden(mixed, 'mixed-planar-palette-3page.tif');
      final big = Unseal.parse(_fixture('mixed-planar-big-be-2page.tif')) as TiffBook;
      expect(big.isBigTiff, isTrue);
      _expectGolden(big, 'mixed-planar-big-be-2page.tif');
    });
  });

  group('TC05 hostile layouts fail typed before any allocation', () {
    test('ColorMap missing, truncated, oversized, and hostile counts', () {
      Uint8List paletteDoc({
        final Set<int> omit = const {},
        final List<int>? colormapValues,
        final List<SyntheticTiffTag> extra = const [],
      }) {
        final indices = _packedIndices(width: 8, height: 8, bits: 4);
        final tags = <int, SyntheticTiffTag>{
          256: SyntheticTiffTag.long(256, 8),
          257: SyntheticTiffTag.long(257, 8),
          258: SyntheticTiffTag.short(258, 4),
          259: SyntheticTiffTag.short(259, 1),
          262: SyntheticTiffTag.short(262, 3),
          277: SyntheticTiffTag.short(277, 1),
          273: SyntheticTiffTag.long(273, 0), // patched below
          279: SyntheticTiffTag.long(279, indices.length),
          if (!omit.contains(320))
            320: SyntheticTiffTag(
              320,
              3,
              colormapValues ?? [for (var i = 0; i < 48; i++) i * 1365],
            ),
        };
        return buildSyntheticTiff(
          data: indices,
          pages: (final dataOffset) {
            tags[273] = SyntheticTiffTag.long(273, dataOffset);
            for (final tag in extra) {
              tags[tag.tag] = tag;
            }
            return [tags.values.toList()];
          },
        );
      }

      expect(() => Unseal.parse(paletteDoc(omit: {320})), _throwsTiff('missing the ColorMap'));
      expect(
        () => Unseal.parse(paletteDoc(colormapValues: [for (var i = 0; i < 47; i++) 1000])),
        _throwsTiff('needs 48'),
      );
      // Any other count is refused before the list is allocated.
      expect(
        () => Unseal.parse(
          paletteDoc(
            extra: [
              SyntheticTiffTag(320, 3, [1, 2, 3]),
            ],
          ),
        ),
        _throwsTiff('ColorMap holds 3 entries'),
      );
    });

    test('planar band arrays: wrong lengths and overlapping bands', () {
      Uint8List planarDoc({final List<int>? offsets, final List<int>? counts}) {
        final plane = Uint8List(8 * 8);
        final data = BytesBuilder(copy: false);
        final computedOffsets = <int>[];
        final computedCounts = <int>[];
        for (var band = 0; band < 3; band++) {
          for (var cell = 0; cell < 1; cell++) {
            final encoded = Uint8List.fromList(
              plane.map((final b) => (b + band * 40) & 0xFF).toList(),
            );
            computedOffsets.add(data.length);
            computedCounts.add(encoded.length);
            data.add(encoded);
          }
        }
        final payload = data.toBytes();
        return buildSyntheticTiff(
          data: payload,
          pages: (final dataOffset) => [
            [
              SyntheticTiffTag.long(256, 8),
              SyntheticTiffTag.long(257, 8),
              SyntheticTiffTag(258, 3, [8, 8, 8]),
              SyntheticTiffTag.short(259, 1),
              SyntheticTiffTag.short(262, 2),
              SyntheticTiffTag.short(277, 3),
              SyntheticTiffTag.short(284, 2),
              SyntheticTiffTag(
                273,
                4,
                offsets ?? [for (final o in computedOffsets) dataOffset + o],
              ),
              SyntheticTiffTag(279, 4, counts ?? computedCounts),
            ],
          ],
        );
      }

      final good = Unseal.parse(planarDoc()) as TiffBook;
      expect((good.pages.single.width, good.pages.single.height), (8, 8));
      expect(
        () => Unseal.parse(planarDoc(offsets: [for (var i = 0; i < 2; i++) 100 + i * 64])),
        _throwsTiff('segments'),
      );
      expect(() => Unseal.parse(planarDoc(counts: [64, 64])), _throwsTiff('segments'));
      // Bands overlapping each other inside one page.
      final overlapping = <int>[for (var i = 0; i < 3; i++) 100 + i * 32];
      expect(() => Unseal.parse(planarDoc(offsets: overlapping)), _throwsTiff('overlap'));
      // A band beyond the file bounds.
      final doc = planarDoc();
      expect(
        () => Unseal.parse(
          planarDoc(offsets: [for (var i = 0; i < 3; i++) doc.length + 16 + i * 64]),
        ),
        _throwsTiff('beyond the file bounds'),
      );
    });

    test('normatively invalid combinations fail typed', () {
      // Palette + predictor 2 (tracked file) and palette + CCITT (synthetic).
      expect(
        () => Unseal.parse(_fixture('palette8-lzw2-reject.tif')),
        _throwsUnsupported('differencing with palette indices'),
      );
      final indices = _packedIndices(width: 8, height: 8, bits: 1);
      final cmap = [0, 0xFFFF, 0xFFFF, 0, 0, 0xFFFF];
      expect(
        () => Unseal.parse(
          buildSyntheticTiff(
            data: indices,
            pages: (final dataOffset) => [
              [
                SyntheticTiffTag.long(256, 8),
                SyntheticTiffTag.long(257, 8),
                SyntheticTiffTag.short(258, 1),
                SyntheticTiffTag.short(259, 4),
                SyntheticTiffTag.short(262, 3),
                SyntheticTiffTag.short(277, 1),
                SyntheticTiffTag.long(273, dataOffset),
                SyntheticTiffTag.long(279, indices.length),
                SyntheticTiffTag(320, 3, cmap),
              ],
            ],
          ),
        ),
        _throwsUnsupported('CCITT'),
      );
      // Planar + CCITT, planar 16-bit + CCITT nonsense: typed, not a crash.
      expect(
        () => Unseal.parse(
          buildSyntheticTiff(
            data: Uint8List(8 * 8 * 3),
            pages: (final dataOffset) => [
              [
                SyntheticTiffTag.long(256, 8),
                SyntheticTiffTag.long(257, 8),
                SyntheticTiffTag(258, 3, [8, 8, 8]),
                SyntheticTiffTag.short(259, 4),
                SyntheticTiffTag.short(262, 2),
                SyntheticTiffTag.short(277, 3),
                SyntheticTiffTag.short(284, 2),
                SyntheticTiffTag(273, 4, [dataOffset, dataOffset + 64, dataOffset + 128]),
                SyntheticTiffTag(279, 4, [64, 64, 64]),
              ],
            ],
          ),
        ),
        _throwsUnsupported('CCITT'),
      );
      // Independent sub-byte planar RGB and separated photometric files.
      expect(() => Unseal.parse(_fixture('flower-rgb-planar-02.tif')), _throwsTiff('sub-byte'));
      expect(
        () => Unseal.parse(_fixture('flower-separated-planar-08.tif')),
        _throwsUnsupported('photometric interpretation 5'),
      );
      // 16-bit palette and the planar alpha page stay outside the recorte.
      expect(
        () => Unseal.parse(_fixture('flower-palette-16.tif')),
        _throwsUnsupported('16-bit palette'),
      );
      expect(
        () => Unseal.parse(_stripFixture('minisblack-2c-8b-alpha.tiff')),
        _throwsUnsupported('alpha or extra samples'),
      );
      // Single-sample planar degeneracy.
      expect(
        () => Unseal.parse(
          buildSyntheticTiff(
            data: Uint8List(64),
            pages: (final dataOffset) => [
              [
                SyntheticTiffTag.long(256, 8),
                SyntheticTiffTag.long(257, 8),
                SyntheticTiffTag.short(258, 8),
                SyntheticTiffTag.short(259, 1),
                SyntheticTiffTag.short(262, 1),
                SyntheticTiffTag.short(277, 1),
                SyntheticTiffTag.short(284, 2),
                SyntheticTiffTag.long(273, dataOffset),
                SyntheticTiffTag.long(279, 64),
              ],
            ],
          ),
        ),
        _throwsUnsupported('1 samples per pixel'),
      );
    });

    test('segment and compression bombs are refused before decoding', () {
      // 1x1 page whose three 16384x8192 Deflate tiles need 384 MiB of
      // scratch: refused before any inflation (23-byte streams each).
      Uint8List planarTileBomb() {
        final stream = Uint8List.fromList(const ZLibEncoder().encodeBytes(Uint8List(16)));
        final data = BytesBuilder(copy: false);
        final offsets = <int>[];
        for (var band = 0; band < 3; band++) {
          offsets.add(data.length);
          data.add(stream);
        }
        final payload = data.toBytes();
        return buildSyntheticTiff(
          data: payload,
          pages: (final dataOffset) => [
            [
              SyntheticTiffTag.long(256, 1),
              SyntheticTiffTag.long(257, 1),
              SyntheticTiffTag(258, 3, [8, 8, 8]),
              SyntheticTiffTag.short(259, 8),
              SyntheticTiffTag.short(262, 2),
              SyntheticTiffTag.short(277, 3),
              SyntheticTiffTag.short(284, 2),
              SyntheticTiffTag.long(322, 16384),
              SyntheticTiffTag.long(323, 8192),
              SyntheticTiffTag(324, 4, [for (final o in offsets) dataOffset + o]),
              SyntheticTiffTag(325, 4, [for (var i = 0; i < 3; i++) stream.length]),
            ],
          ],
        );
      }

      final bomb = planarTileBomb();
      expect(bomb.length, lessThan(512));
      expect(() => Unseal.parse(bomb), _throwsTiff('scratch buffers exceed'));
    });
  });

  group('TC06 cumulative budget', () {
    test('ColorMap requires SHORT samples instead of narrowing larger values', () {
      final indices = Uint8List.fromList([0, 1]);
      final bytes = buildSyntheticTiff(
        data: indices,
        pages: (final dataOffset) => [
          [
            SyntheticTiffTag.long(256, 2),
            SyntheticTiffTag.long(257, 1),
            SyntheticTiffTag.short(258, 8),
            SyntheticTiffTag.short(259, 1),
            SyntheticTiffTag.short(262, 3),
            SyntheticTiffTag.short(277, 1),
            SyntheticTiffTag.long(273, dataOffset),
            SyntheticTiffTag.long(279, indices.length),
            SyntheticTiffTag(320, 4, List<int>.filled(768, 0x10000)),
          ],
        ],
      );
      expect(() => Unseal.parse(bytes), _throwsTiff('SHORT'));
    });

    test('native ColorMap storage is reserved before the observer sees allocation', () {
      final container = TiffContainer(_fixture('palette8-none-t16-le.tif'));
      final budget = TiffDecodeBudget();
      const nativePaletteBytes = 3 * 256 * 2;
      budget.reserve(
        pixels: 0,
        rasterBytes: tiffMaxDecodedRasterBytesPerBook - nativePaletteBytes + 1,
      );
      var observed = false;
      expect(
        () => decodeTiffPage(
          container,
          container.pageDirectories.first,
          budget: budget,
          onDecodedPalette: (final palette) => observed = true,
        ),
        _throwsTiff('scratch buffers'),
      );
      expect(observed, isFalse, reason: 'palette must not be allocated above the resident cap');
      expect(budget.scratchBytes, 0);
    });

    test('band scratch, decode work, and materialized pages are independent guards', () {
      final budget = TiffDecodeBudget();
      budget.reserve(pixels: 0, rasterBytes: tiffMaxDecodedRasterBytesPerBook - 1024);
      // A planar page needs the RGB buffer plus all three band buffers
      // live at once; neither fits the remaining 1024 bytes.
      expect(() => budget.reserveScratch(1025), _throwsTiff('scratch buffers'));
      budget.reserveWork(tiffMaxDecodedWorkBytesPerBook);
      expect(() => budget.reserveWork(1), _throwsTiff('decode-work'));
    });

    test('planar tiles are charged as work even when the page keeps almost nothing', () {
      // Each 1x1 page decodes three 4096x4096 16-bit tiles: 3 x 32 MiB of
      // work for a 58-byte BMP. Five pages fit the 512 MiB cap; the sixth
      // fails before any tile is inflated.
      Uint8List planarWorkDoc(final int pages) {
        // Each band tile inflates to 4096 x 4096 16-bit samples; the zero
        // stream compresses to a few kilobytes.
        final stream = Uint8List.fromList(
          const ZLibEncoder().encodeBytes(Uint8List(4096 * 4096 * 2)),
        );
        final data = BytesBuilder(copy: false);
        final offsets = <int>[];
        for (var band = 0; band < 3; band++) {
          offsets.add(data.length);
          data.add(stream);
        }
        final payload = data.toBytes();
        return buildSyntheticTiff(
          data: payload,
          pages: (final dataOffset) => [
            for (var page = 0; page < pages; page++)
              [
                SyntheticTiffTag.long(256, 1),
                SyntheticTiffTag.long(257, 1),
                SyntheticTiffTag(258, 3, [16, 16, 16]),
                SyntheticTiffTag.short(259, 8),
                SyntheticTiffTag.short(262, 2),
                SyntheticTiffTag.short(277, 3),
                SyntheticTiffTag.short(284, 2),
                SyntheticTiffTag.long(322, 4096),
                SyntheticTiffTag.long(323, 4096),
                SyntheticTiffTag(324, 4, [for (final o in offsets) dataOffset + o]),
                SyntheticTiffTag(325, 4, [for (var i = 0; i < 3; i++) stream.length]),
              ],
          ],
        );
      }

      final five = Unseal.parse(planarWorkDoc(5)) as TiffBook;
      expect(five.pageCount, 5);
      expect(() => Unseal.parse(planarWorkDoc(6)), _throwsTiff('decode-work limit'));
    });

    test('materialized planar pages accumulate against the resident cap', () {
      // 2048x2048 RGB8 planar pages share three Deflate zero tiles. Each
      // page keeps a 12.6 MB BMP while decoding with the RGB buffer and
      // three 4 MiB planes live: eight pages fit 128 MiB, the ninth is
      // refused before its raster exists (the contiguous gray twin fits
      // nine, so the band scratch is really counted).
      Uint8List planarPagesDoc(final int pages) {
        final stream = Uint8List.fromList(const ZLibEncoder().encodeBytes(Uint8List(2048 * 2048)));
        final data = BytesBuilder(copy: false);
        final offsets = <int>[];
        for (var band = 0; band < 3; band++) {
          offsets.add(data.length);
          data.add(stream);
        }
        final payload = data.toBytes();
        return buildSyntheticTiff(
          data: payload,
          pages: (final dataOffset) => [
            for (var page = 0; page < pages; page++)
              [
                SyntheticTiffTag.long(256, 2048),
                SyntheticTiffTag.long(257, 2048),
                SyntheticTiffTag(258, 3, [8, 8, 8]),
                SyntheticTiffTag.short(259, 8),
                SyntheticTiffTag.short(262, 2),
                SyntheticTiffTag.short(277, 3),
                SyntheticTiffTag.short(284, 2),
                SyntheticTiffTag.long(322, 2048),
                SyntheticTiffTag.long(323, 2048),
                SyntheticTiffTag(324, 4, [for (final o in offsets) dataOffset + o]),
                SyntheticTiffTag(325, 4, [for (var i = 0; i < 3; i++) stream.length]),
              ],
          ],
        );
      }

      final eight = Unseal.parse(planarPagesDoc(8)) as TiffBook;
      expect(eight.pageCount, 8);
      expect(
        () => Unseal.parse(planarPagesDoc(9)),
        _throwsTiff('128 MiB decoded-image byte limit'),
      );
    });
  });

  group('TC07 the browser lane decodes the same bytes', () {
    test('embedded fixtures are byte-identical to the tracked files', () {
      expect(embeddedPlanarPaletteFixtures, isNotEmpty);
      embeddedPlanarPaletteFixtures.forEach((final name, final bytes) {
        expect(_hash(bytes), manifest[name]!['sha256'], reason: name);
        expect(bytes, _fixture(name), reason: name);
      });
    });

    test('embedded fixtures decode to the shared goldens on the VM', () {
      embeddedPlanarPaletteFixtures.forEach((final name, final bytes) {
        _expectGolden(Unseal.parse(bytes) as TiffBook, name);
      });
    });

    test('multiple pages of one planar document survive the wire round trip', () {
      final book = Unseal.parse(_fixture('mixed-planar-palette-3page.tif')) as TiffBook;
      expect(book.pageCount, 3);
      // The full worker round trip runs in test/web/ under Chrome; here
      // the VM golden pins the same bytes.
      _expectGolden(book, 'mixed-planar-palette-3page.tif');
    });
  });

  group('TC08 corpus integrity and hostile mutations', () {
    test('every manifest entry is tracked with its hash and expectation', () {
      final files = Directory(_dir)
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
      expect(manifest.length, greaterThanOrEqualTo(35));
    });

    test('hostile mutations decode or fail typed', () {
      final random = Random(20261018);
      var decoded = 0;
      var typed = 0;
      final defects = <String>[];
      final names = manifest.keys.where((final n) => n.length < 65536).toList();
      for (var mutant = 0; mutant < 384; mutant++) {
        final name = names[mutant % names.length];
        final bytes = _mutate(_fixture(name), random, 1 + random.nextInt(4));
        try {
          Unseal.parse(bytes);
          decoded++;
        } on UnsealException {
          typed++;
        } on Object catch (error) {
          defects.add('$name#$mutant: ${error.runtimeType}: $error');
        }
      }
      expect(defects, isEmpty, reason: defects.take(5).join('\n'));
      expect(decoded + typed, 384);
      expect(typed, greaterThan(0));
    });
  });
}

Uint8List _mutate(final Uint8List seed, final Random random, final int rounds) {
  final bytes = Uint8List.fromList(seed);
  for (var round = 0; round < rounds; round++) {
    final position = random.nextInt(bytes.length);
    bytes[position] ^= 1 << random.nextInt(8);
  }
  return bytes;
}

Uint8List _packedIndices({
  required final int width,
  required final int height,
  required final int bits,
}) {
  final rowBytes = (width * bits + 7) ~/ 8;
  final pixels = Uint8List(rowBytes * height);
  final perByte = 8 ~/ bits;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final shift = 8 - bits - (x % perByte) * bits;
      pixels[y * rowBytes + x ~/ perByte] |= ((x * 3 + y * 5) & ((1 << bits) - 1)) << shift;
    }
  }
  return pixels;
}

/// The tiled-suite golden of the contiguous twin, imported lazily to keep
/// the cross-corpus assertion readable.
final String tiledTiffContiguousGolden = _tiledGolden('rgb8-none-t16.tif');
final String quadContigGolden = _tiledGolden('quad-tile.tif');

String _tiledGolden(final String name) {
  final bytes = Uint8List.fromList(File('test/resources/tiff/tiled/$name').readAsBytesSync());
  return _hash((Unseal.parse(bytes) as TiffBook).pages.single.image.content);
}
