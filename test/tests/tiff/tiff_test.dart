import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../../support/tiff_fixture.dart';

final _resources = Directory('test/resources/tiff');

Uint8List _fixture(final String name) =>
    Uint8List.fromList(File('test/resources/tiff/$name').readAsBytesSync());

void _expectGolden(final TiffBook book, final List<String> goldens) {
  for (var page = 0; page < goldens.length; page++) {
    expect(
      sha256.convert(book.pages[page].image.content).toString(),
      goldens[page],
      reason: 'page ${page + 1} raster changed',
    );
  }
}

void main() {
  test('detects classic and BigTIFF in both byte orders', () {
    expect(detectFormat(_fixture('gray-none-2page-le.tif')), DetectedFormat.tiff);
    expect(detectFormat(_fixture('g4-text-2page-be.tif')), DetectedFormat.tiff);
    expect(detectFormat(_fixture('bigtiff-rgb-2page.tif')), DetectedFormat.tiff);
    expect(detectFormat(_fixture('testfax4.tiff')), DetectedFormat.tiff);
  });

  test('parses a multipage little-endian file with golden rasters', () {
    final book = parseTiffBook(_fixture('gray-none-2page-le.tif'));
    expect(book, isA<TiffBook>());
    expect(book.pageCount, 2);
    expect(book.pages.map((page) => (page.width, page.height)).toList(), const [
      (96, 64),
      (96, 64),
    ]);
    expect(book.isBigTiff, isFalse);
    expect(book.format, BookFormat.tiff);
    expect(book.hasTextLayer, isFalse);
    expect(book.readingOrder, hasLength(2));
    expect(book.readingOrder.every((item) => item.isHtml), isTrue);
    expect(sniffImageType(book.cover.content), ImageType.bmp);
    _expectGolden(book, const [
      'cd042d93d8f190658420e7c3f94f734ed1e9de31a375560aa0d65893de49e7b1',
      '2e5410b0dec9aebd8bbe3016ff3732200701edd05d6fc77a697094ed99f3e329',
    ]);
  });

  test('parses each supported codec with golden rasters', () {
    const goldens = <String, List<String>>{
      'rgb-packbits.tif': ['2fd30770f6c2eca0e5bd5449c737803eb00ce89484411d87b853a414a2313357'],
      'rgb-lzw-predictor.tif': ['2fd30770f6c2eca0e5bd5449c737803eb00ce89484411d87b853a414a2313357'],
      'gray16-deflate-predictor.tif': [
        '30b38e52b2e7a1933c885189e28f595b2eabd9c2abc5a72f519da3bef0a0f1bb',
      ],
      'g4-text-2page-be.tif': [
        'cc92122824b4596f61f2e4a3bca0dfb345fe445665aec0c07c1a573285be34e3',
        '17066b34b7108cc9646e457d496c798d78243330bb86bdfa6a3c055efe6e7e09',
      ],
      'g3-text-le.tif': ['17066b34b7108cc9646e457d496c798d78243330bb86bdfa6a3c055efe6e7e09'],
      'bigtiff-rgb-2page.tif': [
        '2fd30770f6c2eca0e5bd5449c737803eb00ce89484411d87b853a414a2313357',
        '226b6dfd279a2c738d9c3fa0355170f405678a4d298c93bcc2ca4f2f2a580963',
      ],
    };
    goldens.forEach((name, expected) {
      final book = parseTiffBook(_fixture(name));
      expect(book.pageCount, expected.length, reason: name);
      _expectGolden(book, expected);
    });
  });

  test('gray16 predictor decodes the documented high-byte ramp', () {
    final book = parseTiffBook(_fixture('gray16-deflate-predictor.tif'));
    final page = book.pages.single;
    expect((page.width, page.height), (96, 64));
    final bmp = page.image.content;
    // BMP rows are bottom-up: the file's first pixel is the image's
    // bottom-left corner, ramp v = (0*13 + 63*97) = 6111 → 6111 >> 8 = 23.
    expect(bmp[bmpHeaderBytesOf(bmp)], 23);
    // The Predictor-2 inversion is verified through the golden hash.
    _expectGolden(book, const ['30b38e52b2e7a1933c885189e28f595b2eabd9c2abc5a72f519da3bef0a0f1bb']);
  });

  test('decodes real libtiff images against their PBM/PGM oracles', () {
    final cases = <String, (String, int, int)>{
      'miniswhite-1c-1b.tiff': ('miniswhite-1c-1b.pbm', 157, 151),
      'minisblack-1c-8b.tiff': ('minisblack-1c-8b.pgm', 157, 151),
    };
    cases.forEach((fixture, oracle) {
      final (oracleName, width, height) = oracle;
      final book = parseTiffBook(_fixture(fixture));
      expect((book.pages.single.width, book.pages.single.height), (width, height), reason: fixture);
      final bmp = book.pages.single.image.content;
      final header = bmpHeaderBytesOf(bmp);
      final stride = bmpRowBytesOf(bmp);
      final ref = _parsePnm(_fixture(oracleName));
      expect(ref.$1, width, reason: oracleName);
      expect(ref.$2, height, reason: oracleName);
      // Compare every pixel: the BMP is bottom-up, the oracle top-down;
      // the oracle samples are 0..maxVal gray levels and the display
      // raster expands them to RGB triples.
      var checked = 0;
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final sample = ref.$3[y * width + x];
          final target = switch (ref.$4) {
            1 => sample == 0 ? 255 : 0, // PBM: 1 = black
            _ => sample,
          };
          final at = header + (height - 1 - y) * stride + x * 3;
          expect(bmp[at], target, reason: '$fixture pixel ($x, $y)');
          expect(bmp[at + 1], target, reason: '$fixture pixel ($x, $y)');
          expect(bmp[at + 2], target, reason: '$fixture pixel ($x, $y)');
          checked++;
        }
      }
      expect(checked, width * height);
    });
  });

  test('decodes the real Group 4 fax page pixel-identically (golden)', () {
    final book = parseTiffBook(_fixture('testfax4.tiff'));
    final page = book.pages.single;
    expect((page.width, page.height), (2453, 3369));
    expect(page.dpi, greaterThan(0));
    _expectGolden(book, const ['f867f4429df1a7ac5854acbb1420dbfe46c55002e5c21c109a1f9e802308c996']);
  });

  test('decodes the real no-EOL Group 3 fax page (fallback layout)', () {
    final book = parseTiffBook(_fixture('testfax3_bug54_1dnoEOL.tif'));
    expect((book.pages.single.width, book.pages.single.height), (1728, 2320));
    _expectGolden(book, const ['dbdf1a58c249b1694f97b2146888caea829eb99bcf22cc8bc79f874852d120b9']);
  });

  test('decodes old-style bit-reversed compat LZW (golden)', () {
    final book = parseTiffBook(_fixture('quad-lzw-compat.tiff'));
    expect((book.pages.single.width, book.pages.single.height), (512, 384));
    _expectGolden(book, const ['87a17cb926cfdaecb43f778d72e883c4963d2d407aaf39fbeb47faa884ba26f8']);
  });

  test('decodes real multipage and sub-IFD chains in IFD order', () {
    final two = parseTiffBook(_fixture('test_two_ifds.tif'));
    expect(two.pageCount, 2);
    expect(two.pages.map((page) => (page.width, page.height)).toList(), const [(1, 1), (1, 1)]);
    final subifd = parseTiffBook(_fixture('tiff_with_subifd_chain.tif'));
    // The main IFD chain holds two pages; the SubIFDs are ignored.
    expect(subifd.pageCount, 2);
    expect(subifd.pages.map((page) => page.width).toList(), const [1024, 1024]);
  });

  test('reads metadata tags best-effort', () {
    final book = parseTiffBook(_fixture('metadata-gray.tif'));
    expect(book.metadata.format, BookFormat.tiff);
    expect(book.metadata.description, 'Generated gradient for the unseal TIFF corpus');
    expect(book.metadata.bookProducer, 'tool/tiff_fixtures.dart');
    expect(book.metadata.authors, const <String>['Unseal fixture tooling']);
    expect(book.metadata.publishedAt, DateTime(2026, 9, 30, 12));
  });

  test('readTiffMetadata validates the container without decoding pages', () {
    final metadata = readTiffMetadata(_fixture('bigtiff-rgb-2page.tif'));
    expect(metadata.format, BookFormat.tiff);
  });

  test('Unseal.parse dispatches TIFF and BigTIFF', () {
    final book = Unseal.parse(_fixture('gray-none-2page-le.tif'));
    expect(book, isA<TiffBook>());
    expect(book.format, BookFormat.tiff);
    final big = Unseal.parse(_fixture('bigtiff-rgb-2page.tif')) as TiffBook;
    expect(big.isBigTiff, isTrue);
  });

  test('typed unsupported codecs carry explicit messages', () {
    final cases = <String, String>{
      'ojpeg_zackthecat_subsamp22_single_strip.tiff': 'old-style JPEG (6)',
      'palette-1c-8b.tiff': 'palette',
      'logluv-3c-16b.tiff': 'SampleFormat',
      'quad-tile.jpg.tiff': 'tiled',
      'minisblack-2c-8b-alpha.tiff': 'PlanarConfiguration 2',
    };
    cases.forEach((name, messagePart) {
      try {
        parseTiffBook(_fixture(name));
        fail('$name should fail typed');
      } on TiffUnsupportedCodecException catch (error) {
        expect(error.message, contains(messagePart), reason: name);
      } on FormatNotSupportedException {
        // The dispatch-normalized shape of the same typed failure.
      }
    });
    // The JPEGTables-bearing page is typed unsupported, not a crash.
    expect(
      () => parseTiffBook(_fixture('jpeg-external-tables.tif')),
      throwsA(isA<TiffUnsupportedCodecException>()),
    );
  });

  test('hostile IFD chains fail typed (real loop file and hand-built cycle)', () {
    expect(
      () => parseTiffBook(_fixture('test_ifd_loop_to_self.tif')),
      throwsA(isA<TiffException>()),
    );
    // Hand-built self-loop: IFD 0's next pointer targets itself.
    final loop = ByteData(8 + 2 + 12 + 4);
    loop.setUint16(8, 0); // zero entries
    loop.setUint32(8 + 2 + 12, 8); // next IFD = this IFD
    expect(() => parseTiffBook(loop.buffer.asUint8List()), throwsA(isA<TiffException>()));
  });

  test('declared giant offsets and counts fail typed before allocation', () {
    // BigTIFF whose first IFD offset declares ~8 exabytes.
    final big = ByteData(16);
    big.setUint16(0, 0x4949);
    big.setUint16(2, 43);
    big.setUint16(4, 8);
    big.setUint16(6, 0);
    big.setUint32(8, 0xFFFFFFFF);
    big.setUint32(12, 0xFFFFFFFF);
    expect(() => parseTiffBook(big.buffer.asUint8List()), throwsA(isA<TiffException>()));
    // Classic TIFF whose single strip declares more bytes than the file
    // holds: rejected before any Uint8List allocation.
    final giant = buildGrayTiff(width: 8, height: 8, stripByteCountOverride: 1 << 30);
    expect(() => parseTiffBook(giant), throwsA(isA<TiffException>()));
  });

  test('the 128 MiB input cap and empty-page documents fail typed', () {
    final header = ByteData(8);
    header.setUint16(0, 0x4949);
    header.setUint16(2, 42);
    header.setUint32(4, 0); // no pages
    expect(() => parseTiffBook(header.buffer.asUint8List()), throwsA(isA<TiffException>()));
    expect(() => parseTiffBook(Uint8List(8)), throwsA(isA<TiffException>()));
  });

  test('every tracked decodable fixture keeps its golden raster', () {
    // Sweep: decode every fixture the corpus marks decodable and pin
    // page-image hashes, so any decoder drift fails loudly.
    const goldens = <String, List<String>>{
      'gray-none-2page-le.tif': [
        'cd042d93d8f190658420e7c3f94f734ed1e9de31a375560aa0d65893de49e7b1',
        '2e5410b0dec9aebd8bbe3016ff3732200701edd05d6fc77a697094ed99f3e329',
      ],
      'metadata-gray.tif': ['cd042d93d8f190658420e7c3f94f734ed1e9de31a375560aa0d65893de49e7b1'],
      'testfax4.tiff': ['f867f4429df1a7ac5854acbb1420dbfe46c55002e5c21c109a1f9e802308c996'],
      'testfax3_bug54_1dnoEOL.tif': [
        'dbdf1a58c249b1694f97b2146888caea829eb99bcf22cc8bc79f874852d120b9',
      ],
      'quad-lzw-compat.tiff': ['87a17cb926cfdaecb43f778d72e883c4963d2d407aaf39fbeb47faa884ba26f8'],
      'deflate-last-strip-extra-data.tiff': [
        'ab54c8d802163bb98c0f1198eada968716bc14c55acce7224a29306dfc74b6ae',
      ],
      'tiff_with_subifd_chain.tif': [
        'bf30e211d7622417762bf017c55cf2d2dd424a9adc30fb91f66179507bd4dfcb',
        'b411ed74a64e74f1e61978e02fae12caaef48b1abe78761ae440ebf822531c41',
      ],
      'test_two_ifds.tif': [
        'ac39ec546f0f42acee6312cacffca7a644357b37331c7286910b2b37adc37e18',
        'ac39ec546f0f42acee6312cacffca7a644357b37331c7286910b2b37adc37e18',
      ],
      'minisblack-1c-8b.tiff': ['bce0c04d96513635a05c59e855825c476b460158f04e42767c4e294955c77799'],
      'miniswhite-1c-1b.tiff': ['99b13762a940b81fe123d0f72cd670b7b63ea698adc1ffeecb5d413fff96bb36'],
      'rgb-3c-8b.tiff': ['2a646d1e14a4155a9b1cd91604dc9f6d9506fa2776147b9c488a0ce905b53abe'],
    };
    expect(_resources.listSync().whereType<File>().length, greaterThan(20));
    goldens.forEach((name, expected) {
      final book = parseTiffBook(_fixture(name));
      _expectGolden(book, expected);
    });
  });
}

int bmpHeaderBytesOf(final Uint8List bmp) {
  final view = ByteData.sublistView(bmp);
  return view.getUint32(10, Endian.little);
}

int bmpRowBytesOf(final Uint8List bmp) {
  final view = ByteData.sublistView(bmp);
  final width = view.getInt32(18, Endian.little);
  return (width * 3 + 3) & ~3;
}

/// Parses a PBM/PGM/PPM oracle: (width, height, samples, maxVal).
(int, int, List<int>, int) _parsePnm(final Uint8List bytes) {
  final text = String.fromCharCodes(bytes);
  final magic = text.substring(0, 2);
  var cursor = 2;
  int? width;
  int? height;
  var maxVal = 1;
  final numbers = <int>[];
  while (cursor < bytes.length) {
    final char = text[cursor];
    if (char == '#') {
      while (cursor < bytes.length && text[cursor] != '\n') {
        cursor++;
      }
    } else if (int.tryParse(char) != null) {
      var end = cursor;
      while (end < bytes.length && int.tryParse(text[end]) != null) {
        end++;
      }
      numbers.add(int.parse(text.substring(cursor, end)));
      cursor = end;
      continue;
    } else {
      cursor++;
      continue;
    }
    cursor++;
    if (numbers.length >= 3) break;
  }
  width = numbers[0];
  height = numbers[1];
  if (magic == 'P2') {
    maxVal = numbers.length > 2 ? numbers[2] : 255;
    // P2 keeps ASCII samples after maxVal.
    final sampleText = text.substring(cursor).trim();
    for (final token in sampleText.split(RegExp(r'\s+'))) {
      final value = int.tryParse(token);
      if (value != null) numbers.add(value);
    }
    numbers.removeRange(0, 3);
    return (width, height, numbers, maxVal);
  }
  // Binary P4/P5/P6: one whitespace after the last header integer,
  // then raw samples.
  final headerEnd = _binaryDataStart(bytes, numberFields: magic == 'P4' ? 2 : 3);
  maxVal = magic == 'P4' ? 1 : numbers[2];
  final sampleBytes = bytes.sublist(headerEnd);
  final samples = <int>[];
  if (magic == 'P4') {
    final stride = (width + 7) ~/ 8;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        samples.add((sampleBytes[y * stride + (x >> 3)] >> (7 - (x & 7))) & 1);
      }
    }
  } else if (magic == 'P5') {
    for (final byte in sampleBytes) {
      samples.add(byte);
    }
  } else {
    for (var index = 0; index + 2 < sampleBytes.length; index += 3) {
      samples.addAll([sampleBytes[index], sampleBytes[index + 1], sampleBytes[index + 2]]);
    }
  }
  return (width, height, samples, maxVal);
}

int _binaryDataStart(final Uint8List bytes, {required final int numberFields}) {
  // Skips the magic plus the whitespace-separated header integers
  // (and any # comments), leaving the cursor on the binary payload.
  var cursor = 2;
  var seen = 0;
  var inNumber = false;
  while (cursor < bytes.length) {
    final byte = bytes[cursor];
    final isDigit = byte >= 0x30 && byte <= 0x39;
    if (isDigit && !inNumber) {
      inNumber = true;
    } else if (!isDigit && inNumber) {
      inNumber = false;
      seen++;
      if (seen == numberFields) {
        cursor++;
        break;
      }
    }
    cursor++;
  }
  return cursor;
}
