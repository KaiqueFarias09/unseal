import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:test/test.dart';
import 'package:unseal/src/features/djvu/jb2_decoder.dart';
import 'package:unseal/unseal.dart';

import '../../support/djvu_fixture.dart';

Uint8List derived(final String name) => File('test/resources/djvu/derived/$name').readAsBytesSync();

/// Reads one RGB pixel from a 24-bit or 1-bit BMP the decoders produce.
List<int> bmpPixel(final Uint8List bmp, final int x, final int y) {
  final view = ByteData.sublistView(bmp);
  final offset = view.getUint32(10, Endian.little);
  final width = view.getInt32(18, Endian.little);
  final height = view.getInt32(22, Endian.little);
  final bpp = view.getUint16(28, Endian.little);
  final topDownRow = height - 1 - y;
  if (bpp == 24) {
    final stride = (width * 3 + 3) & ~3;
    final source = offset + topDownRow * stride + x * 3;
    return <int>[bmp[source + 2], bmp[source + 1], bmp[source]];
  }
  final stride = ((width + 31) ~/ 32) * 4;
  final bit = (bmp[offset + topDownRow * stride + x ~/ 8] >> (7 - (x & 7))) & 1;
  return bit == 0 ? <int>[0, 0, 0] : <int>[255, 255, 255];
}

/// Decodes a 24-bit or 1-bit BMP into a top-down RGB byte raster for
/// whole-image comparisons.
Uint8List bmpRaster(final Uint8List bmp) {
  final view = ByteData.sublistView(bmp);
  final offset = view.getUint32(10, Endian.little);
  final width = view.getInt32(18, Endian.little);
  final height = view.getInt32(22, Endian.little);
  final bpp = view.getUint16(28, Endian.little);
  final rgb = Uint8List(width * height * 3);
  if (bpp == 1) {
    final stride = ((width + 31) ~/ 32) * 4;
    for (var y = 0; y < height; y++) {
      final source = offset + (height - 1 - y) * stride;
      for (var x = 0; x < width; x++) {
        final bit = (bmp[source + x ~/ 8] >> (7 - (x & 7))) & 1;
        final level = bit == 0 ? 0 : 255;
        rgb[(y * width + x) * 3] = level;
        rgb[(y * width + x) * 3 + 1] = level;
        rgb[(y * width + x) * 3 + 2] = level;
      }
    }
    return rgb;
  }
  final stride = (width * 3 + 3) & ~3;
  for (var y = 0; y < height; y++) {
    final source = offset + (height - 1 - y) * stride;
    for (var x = 0; x < width; x++) {
      rgb[(y * width + x) * 3] = bmp[source + x * 3 + 2];
      rgb[(y * width + x) * 3 + 1] = bmp[source + x * 3 + 1];
      rgb[(y * width + x) * 3 + 2] = bmp[source + x * 3];
    }
  }
  return rgb;
}

/// Replaces the payload of every chunk named [id] with [replacement],
/// rebuilding the IFF padding. Only single-level page FORMs are supported.
Uint8List withChunkReplaced(final Uint8List page, final String id, final List<int> replacement) {
  final view = ByteData.sublistView(page);
  final out = BytesBuilder();
  out.add(page.sublist(0, 16)); // AT&T + FORM header + DJVU sub-id.
  var offset = 16;
  while (offset < page.length) {
    final chunkId = String.fromCharCodes(page, offset, offset + 4);
    final length = view.getUint32(offset + 4);
    if (chunkId == id) {
      out.add(asciiBytes(id));
      out.add(_int32(replacement.length));
      out.add(replacement);
      if (replacement.length.isOdd) out.addByte(0);
    } else {
      out.add(page.sublist(offset, offset + 8 + length));
      if (length.isOdd) out.addByte(page[offset + 8 + length]);
    }
    offset += 8 + length + (length & 1);
  }
  return out.toBytes();
}

List<int> asciiBytes(final String value) => value.codeUnits;

List<int> _int32(final int value) => <int>[
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

/// Locates the payload bounds of the first chunk named [id] in a page file.
(int, int) chunkRange(final Uint8List page, final String id) {
  final view = ByteData.sublistView(page);
  var offset = 16; // AT&T magic + FORM header + DJVU sub-id.
  final end = page.length;
  while (offset + 8 <= end) {
    final chunkId = String.fromCharCodes(page, offset, offset + 4);
    final length = view.getUint32(offset + 4);
    if (chunkId == id) return (offset + 8, offset + 8 + length);
    final chunkEnd = offset + 8 + length;
    offset = chunkEnd == end ? end : chunkEnd + (length & 1);
  }
  throw StateError('no $id chunk');
}

const red = <int>[255, 0, 0];
const lime = <int>[0, 255, 0];
const blue = <int>[0, 0, 255];
const yellow = <int>[255, 255, 0];

void main() {
  group('FGbz reaches the page image through the public API', () {
    test('a bundled FGbz document renders palette-colored ink', () {
      final book = Unseal.parse(derived('fgbz-bundled.djvu')) as DjvuBook;
      expect(book.pageCount, 3);
      final page = book.pages[0].image.content;
      expect(bmpPixel(page, 8, 8), red);
      expect(bmpPixel(page, 24, 8), lime);
      expect(bmpPixel(page, 40, 8), blue);
      expect(bmpPixel(page, 56, 8), yellow);
      expect(bmpPixel(page, 30, 26), <int>[255, 255, 255]);
    });

    test('a colored mask composes over the IW44 background', () {
      final book = Unseal.parse(derived('fgbz-overlap-bg.djvu')) as DjvuBook;
      final page = book.pages.single.image.content;
      // Ink takes its blit color; paper shows the c44 gradient background.
      expect(bmpPixel(page, 8, 8), blue);
      expect(bmpPixel(page, 44, 8), <int>[255, 165, 0]);
      final background = bmpPixel(page, 2, 2);
      expect(background, isNot(const <int>[255, 255, 255]));
      expect(background[0], greaterThan(100));
    });

    test('a local indirect document renders the same colors as the bundle', () async {
      final bundled = Unseal.parse(derived('fgbz-bundled.djvu')) as DjvuBook;
      final index = File('test/resources/djvu/derived/fgbz-indirect/index.djvu').path;
      final indirect = await Unseal.readFile(index) as DjvuBook;
      expect(indirect.pageCount, bundled.pageCount);
      for (var i = 0; i < bundled.pageCount; i++) {
        expect(
          bmpRaster(indirect.pages[i].image.content),
          bmpRaster(bundled.pages[i].image.content),
        );
      }
      expect(bmpPixel(indirect.pages[0].image.content, 8, 8), red);
    });

    test('absence of FGbz and a palette-only chunk both keep black ink', () {
      final absent = Unseal.parse(derived('fgbz-colors-absent.djvu')) as DjvuBook;
      final paletteOnly = Unseal.parse(derived('fgbz-palette-only.djvu')) as DjvuBook;
      // djvumake adds a white BG44 to the palette-only page, so the two take
      // different container paths; the rendered rasters must still agree.
      expect(
        bmpRaster(paletteOnly.pages.single.image.content),
        bmpRaster(absent.pages.single.image.content),
      );
      expect(bmpPixel(absent.pages.single.image.content, 8, 8), <int>[0, 0, 0]);
    });

    test('an FGbz on a page without Sjbz stays ignored', () {
      final jpeg = File('test/resources/fuzz/generated/images/tiny.jpg').readAsBytesSync();
      final fgbz = djvuCorpusChunk(derived('fgbz-repeat-colors.djvu'), 'FGbz');
      final bytes = djvuPageWithChunks(jpeg, chunks: <(String, Uint8List)>[('FGbz', fgbz)]);
      final book = Unseal.parse(bytes) as DjvuBook;
      expect(book.pages.single.image.content, jpeg);
    });
  });

  group('per-blit association', () {
    test('the same symbol renders in four colors across its blits', () {
      final bytes = derived('fgbz-repeat-colors.djvu');
      final book = Unseal.parse(bytes) as DjvuBook;
      final page = book.pages.single.image.content;
      // One shape, four placements, one palette color each: blit order runs
      // left to right and the generator assigned colors by that order.
      expect(bmpPixel(page, 8, 8), red);
      expect(bmpPixel(page, 24, 8), lime);
      expect(bmpPixel(page, 40, 8), blue);
      expect(bmpPixel(page, 56, 8), yellow);
    });

    test('rotating the color indices recolors blits in place', () {
      final plain = Unseal.parse(derived('fgbz-repeat-colors.djvu')) as DjvuBook;
      final shifted = Unseal.parse(derived('fgbz-index-shift.djvu')) as DjvuBook;
      final first = plain.pages.single.image.content;
      final second = shifted.pages.single.image.content;
      expect(bmpRaster(first), isNot(bmpRaster(second)));
      // The rotation moved every blit's color one blit forward: red lands on
      // the last placement, yellow on the first.
      expect(bmpPixel(second, 8, 8), yellow);
      expect(bmpPixel(second, 56, 8), blue);
      expect(bmpPixel(second, 24, 8), red);
    });

    test('the real corpus colors shared-dictionary blits on every page', () {
      final navm =
          Unseal.parse(File('test/resources/djvu/navm-fgbz.djvu').readAsBytesSync()) as DjvuBook;
      // Page 1's palette is black and yellow; the corpus blits use both.
      final raster = navm.pages[0].image.content;
      var yellowPixels = 0;
      var blackPixels = 0;
      for (var y = 0; y < 3300; y += 7) {
        for (var x = 0; x < 2550; x += 7) {
          final pixel = bmpPixel(raster, x, y);
          if (pixel.join(',') == '255,255,0') {
            yellowPixels++;
          } else if (pixel.join(',') == '0,0,0') {
            blackPixels++;
          }
        }
      }
      expect(yellowPixels, greaterThan(0));
      expect(blackPixels, greaterThan(0));
      // The spec document colors pages under five shared dictionaries; two
      // sampled pages keep their palette colors (blue and green on page 5,
      // gray on page 22).
      final spec =
          Unseal.parse(File('test/resources/djvu/spec-bundled.djvu').readAsBytesSync()) as DjvuBook;
      expect(spec.pageCount, 71);
    });

    test('painting order follows the native color-group sequence', () {
      // fgbz-inverted-order re-colors spec page 21 so that an overlapping
      // blit pair (i, j), i < j, carries lime on i and red on j with red's
      // group leading. The overlap pixel must render lime — the group of
      // the later blit paints after red's leading group — which fails under
      // a naive last-blit-wins pass. tool/djvu_fgbz_compare.dart verified
      // the full raster byte-for-byte against ddjvu; this pin holds the
      // composite to that verified output.
      final book = Unseal.parse(derived('fgbz-inverted-order.djvu')) as DjvuBook;
      final origin = File(
        'test/resources/djvu/derived/fgbz-inverted-order.origin.json',
      ).readAsStringSync();
      expect(origin, contains('"overlapPair"'));
      expect(
        sha256.convert(book.pages.single.image.content).toString(),
        '1947f19b5f014d330a23422be0e7b1b2009ebc12f6a301fbf2d445975ed67321',
      );
    });
  });

  group('typed refusals', () {
    Uint8List repeatBytes() => derived('fgbz-repeat-colors.djvu');

    Uint8List patchedFgbz(final Uint8List page, final List<int> Function(Uint8List) patch) {
      final (start, end) = chunkRange(page, 'FGbz');
      final payload = patch(Uint8List.sublistView(page, start, end));
      return withChunkReplaced(page, 'FGbz', payload);
    }

    test('an unsupported FGbz version fails typed', () {
      final corrupted = patchedFgbz(repeatBytes(), (final fgbz) {
        final copy = Uint8List.fromList(fgbz);
        copy[0] = 0x01;
        return copy;
      });
      expect(() => Unseal.parse(corrupted), throwsA(isA<DjvuException>()));
    });

    test('a truncated palette fails typed', () {
      final corrupted = patchedFgbz(repeatBytes(), (final fgbz) {
        final copy = Uint8List.fromList(fgbz);
        // Twelve palette entries declared; the chunk still carries four.
        copy[1] = 0x00;
        copy[2] = 0x0C;
        return copy;
      });
      expect(() => Unseal.parse(corrupted), throwsA(isA<DjvuException>()));
    });

    test('an out-of-range color index fails typed', () {
      final corrupted = patchedFgbz(repeatBytes(), (final fgbz) {
        final copy = Uint8List.fromList(fgbz);
        // The compressed indices name entries 0..3; shrinking the palette to
        // two turns the later ones into out-of-range indices.
        copy[1] = 0x00;
        copy[2] = 0x02;
        return copy;
      });
      expect(() => Unseal.parse(corrupted), throwsA(isA<DjvuException>()));
    });

    test('a color count beyond the record budget fails before decoding', () {
      final corrupted = patchedFgbz(repeatBytes(), (final fgbz) {
        final copy = Uint8List.fromList(fgbz);
        final paletteSize = (copy[1] << 8) | copy[2];
        final dataSizeOffset = 3 + paletteSize * 3;
        // INT24 count of 16,777,215 indices — far beyond the 65536 cap.
        copy[dataSizeOffset] = 0xFF;
        copy[dataSizeOffset + 1] = 0xFF;
        copy[dataSizeOffset + 2] = 0xFF;
        return copy;
      });
      expect(() => Unseal.parse(corrupted), throwsA(isA<DjvuException>()));
    });

    test('a color count that mismatches the blit count fails typed', () {
      final corrupted = patchedFgbz(repeatBytes(), (final fgbz) {
        final copy = Uint8List.fromList(fgbz);
        final paletteSize = (copy[1] << 8) | copy[2];
        final dataSizeOffset = 3 + paletteSize * 3;
        // The page places four blits; declaring six leaves the stream short.
        copy[dataSizeOffset + 2] = 6;
        return copy;
      });
      expect(() => Unseal.parse(corrupted), throwsA(isA<DjvuException>()));
    });

    test('a duplicate FGbz chunk fails typed', () {
      final page = repeatBytes();
      final (start, end) = chunkRange(page, 'FGbz');
      final fgbzBytes = page.sublist(start, end + (end - start) % 2);
      final duplicated = _withChunkDuplicated(
        page,
        'FGbz',
        Uint8List.sublistView(page, start, end),
        fgbzBytes.length.isOdd,
      );
      expect(() => Unseal.parse(duplicated), throwsA(isA<DjvuException>()));
    });

    test('FGbz beside an FG44 foreground fails as a duplicate encoding', () {
      final happyBirthday = File('test/resources/djvu/happy-birthday-iw44.djvu').readAsBytesSync();
      final (start, end) = chunkRange(happyBirthday, 'Sjbz');
      final payload = Uint8List.sublistView(happyBirthday, start, end);
      final fgbz = djvuCorpusChunk(repeatBytes(), 'FGbz');
      final rebuilt = _withChunkInserted(happyBirthday, 'Sjbz', 'FGbz', payload, fgbz);
      expect(() => Unseal.parse(rebuilt), throwsA(isA<DjvuUnsupportedCodecException>()));
    });
  });

  group('adversarial workloads', () {
    test('many FGbz pages hit the cumulative raster budget before allocating', () {
      // The budget card is a dict-free 2040x2040 colored page: every copy
      // reserves its color map plus the 24-bit composite (~21 MB of raster
      // bytes), so 52 copies cross the 1 GiB book limit before anything
      // materializes. No copy carries INCL or Djbz, so the synthetic DIRM
      // needs no name table.
      final page = derived('fgbz-budget-page.djvu');
      final bytes = _bundledColoredPages(List.filled(52, page));
      expect(
        () => Unseal.parse(bytes),
        throwsA(
          isA<DjvuException>().having(
            (final e) => e.message,
            'message',
            contains('1 GiB decoded-image byte limit'),
          ),
        ),
      );
    });
  });

  group('negatives change exactly one thing', () {
    test('moving one blit keeps its dimensions and changes the image', () {
      final base = decodeDjvuJb2Page(
        djvuCorpusChunk(derived('fgbz-shifted-base.djvu'), 'Sjbz'),
        expectedWidth: 64,
        expectedHeight: 32,
        collectBlits: true,
      );
      final moved = decodeDjvuJb2Page(
        djvuCorpusChunk(derived('fgbz-shifted-b.djvu'), 'Sjbz'),
        expectedWidth: 64,
        expectedHeight: 32,
        collectBlits: true,
      );
      final baseBlits = base.blits!;
      final movedBlits = moved.blits!;
      expect(movedBlits.length, baseBlits.length);
      var differences = 0;
      for (var i = 0; i < baseBlits.length; i++) {
        expect(movedBlits[i].symbol.width, baseBlits[i].symbol.width);
        expect(movedBlits[i].symbol.height, baseBlits[i].symbol.height);
        if (movedBlits[i].left != baseBlits[i].left ||
            movedBlits[i].bottom != baseBlits[i].bottom) {
          differences++;
        }
      }
      expect(differences, 1);
      final baseBook = Unseal.parse(derived('fgbz-shifted-base.djvu')) as DjvuBook;
      final movedBook = Unseal.parse(derived('fgbz-shifted-b.djvu')) as DjvuBook;
      expect(
        bmpRaster(baseBook.pages.single.image.content),
        isNot(bmpRaster(movedBook.pages.single.image.content)),
      );
      // The moved blit's old spot is now paper.
      expect(bmpPixel(movedBook.pages.single.image.content, 40, 8), const <int>[255, 255, 255]);
    });
  });
}

/// Rebuilds the page with a second copy of the [id] chunk right after it.
Uint8List _withChunkDuplicated(
  final Uint8List page,
  final String id,
  final Uint8List payload,
  final bool pad,
) {
  final view = ByteData.sublistView(page);
  final out = BytesBuilder();
  out.add(page.sublist(0, 16)); // AT&T + FORM header + DJVU sub-id.
  var offset = 16;
  var done = false;
  while (offset < page.length) {
    final chunkId = String.fromCharCodes(page, offset, offset + 4);
    final length = view.getUint32(offset + 4);
    out.add(page.sublist(offset, offset + 8 + length));
    if (length.isOdd) out.addByte(page[offset + 8 + length]);
    if (chunkId == id && !done) {
      done = true;
      out.add(asciiBytes(id));
      out.add(_int32(payload.length));
      out.add(payload);
      if (pad) out.addByte(0);
    }
    offset += 8 + length + (length & 1);
  }
  return _withFormLength(out.toBytes());
}

/// Rewrites the root FORM length of a rebuilt page file.
Uint8List _withFormLength(final Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  view.setUint32(8, bytes.length - 12);
  return bytes;
}

/// Rebuilds the page with [newId] holding [newPayload], inserted after [afterId].
Uint8List _withChunkInserted(
  final Uint8List page,
  final String afterId,
  final String newId,
  final Uint8List payload,
  final Uint8List newPayload,
) {
  final view = ByteData.sublistView(page);
  final out = BytesBuilder();
  out.add(page.sublist(0, 16)); // AT&T + FORM header + DJVU sub-id.
  var offset = 16;
  var done = false;
  while (offset < page.length) {
    final chunkId = String.fromCharCodes(page, offset, offset + 4);
    final length = view.getUint32(offset + 4);
    out.add(page.sublist(offset, offset + 8 + length));
    if (length.isOdd) out.addByte(page[offset + 8 + length]);
    if (chunkId == afterId && !done) {
      done = true;
      out.add(asciiBytes(newId));
      out.add(_int32(newPayload.length));
      out.add(newPayload);
      if (newPayload.length.isOdd) out.addByte(0);
    }
    offset += 8 + length + (length & 1);
  }
  return _withFormLength(out.toBytes());
}

/// Bundles [pages] into one FORM:DJVM with a bundled DIRM and real offsets.
Uint8List _bundledColoredPages(final List<Uint8List> pages) {
  final dirmDataLength = 3 + pages.length * 4;
  final directoryLength = 8 + dirmDataLength + (dirmDataLength.isOdd ? 1 : 0);
  var offset = 4 + 8 + 4 + directoryLength;
  final offsets = <int>[];
  for (var i = 0; i < pages.length; i++) {
    offsets.add(offset);
    offset += pages[i].length - 4;
    if ((pages[i].length - 4).isOdd && i != pages.length - 1) offset++;
  }
  final dirmData = <int>[
    0x81,
    ..._int16(pages.length),
    for (final value in offsets) ..._int32(value),
    if (dirmDataLength.isOdd) 0,
  ];
  final directory = <int>[
    ...asciiBytes('DIRM'),
    ..._int32(dirmData.length),
    ...dirmData,
    if (dirmData.length.isOdd) 0,
  ];
  final body = <int>[...asciiBytes('DJVM'), ...directory];
  for (var i = 0; i < pages.length; i++) {
    final component = pages[i].sublist(4);
    body.addAll(component);
    if (component.length.isOdd && i != pages.length - 1) body.add(0);
  }
  return Uint8List.fromList(<int>[
    ...asciiBytes('AT&T'),
    ...asciiBytes('FORM'),
    ..._int32(body.length),
    ...body,
  ]);
}

List<int> _int16(final int value) => <int>[(value >> 8) & 0xFF, value & 0xFF];
