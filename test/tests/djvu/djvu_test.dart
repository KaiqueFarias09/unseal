import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../../support/djvu_fixture.dart';

void main() {
  final jpeg = File('test/resources/fuzz/generated/images/tiny.jpg').readAsBytesSync();
  final fixture = File('test/resources/books/djvu/jpeg-only.djvu').readAsBytesSync();

  test('opens a displayable JPEG page and its OCR text', () {
    expect(detectFormat(fixture), DetectedFormat.djvu);
    final book = Unseal.parse(fixture) as DjvuBook;
    expect(book.format, BookFormat.djvu);
    expect(book.pageCount, 1);
    expect(book.pages.single.image.content, jpeg);
    expect(book.pages.single.width, 8);
    expect(book.pages.single.dpi, 300);
    expect(book.pages.single.text, 'A scanned page');
    expect(book.metadata.cover?.width, 8);
    expect(book.files.html.single.plainText, 'A scanned page');
    expect(book.readingOrder.single.isHtml, isTrue);
    expect(book.files.html.single.content, contains('../images/page-1.jpg'));
    expect(book.search('scanned').matches, hasLength(1));
    expect(book.hasTextLayer, isTrue);
    expect(Unseal.readMetadataSync(fixture).format, BookFormat.djvu);
  });

  test('opens bundled pages in DIRM order', () {
    final first = djvuJpegPage(jpeg, text: 'First');
    final second = djvuJpegPage(jpeg, text: 'Second');
    final book = Unseal.parse(djvuBundle(<Uint8List>[first, second])) as DjvuBook;
    expect(book.pageCount, 2);
    expect(book.pages.map((final page) => page.text), <String>['First', 'Second']);
  });

  test('decodes a licensed standalone JB2 layer to a displayable bilevel page', () {
    final cable = File('test/resources/djvu/cable-1973.djvu').readAsBytesSync();
    final sjbz = _firstChunkData(cable, 'Sjbz');
    final page = djvuJb2Page(sjbz, width: 2550, height: 3301);
    final book = Unseal.parse(page) as DjvuBook;
    final image = book.pages.single.image;

    expect(image.type, 'bmp');
    expect(image.content.take(2), <int>[0x42, 0x4D]);
    expect(sniffImageType(image.content), ImageType.bmp);
    expect(imageSize(image.content), const ImageSize(2550, 3301));
    expect(book.metadata.cover?.type, ImageType.bmp);
    expect(book.files.html.single.content, contains('../images/page-1.bmp'));
    expect(book.bytes, page);
    expect(image.content.skip(62).any((final byte) => byte != 0xFF), isTrue);
  });

  test('decodes page-local JB2 in a bundled DjVu document', () {
    final cable = File('test/resources/djvu/cable-1973.djvu').readAsBytesSync();
    final page = djvuJb2Page(_firstChunkData(cable, 'Sjbz'), width: 2550, height: 3301);
    final book = Unseal.parse(djvuBundle(<Uint8List>[page])) as DjvuBook;

    expect(book.pageCount, 1);
    expect(book.pages.single.image.type, 'bmp');
    expect(imageSize(book.pages.single.image.content), const ImageSize(2550, 3301));
  });

  test('reports a truncated JB2 arithmetic stream as a typed parse failure', () {
    final cable = File('test/resources/djvu/cable-1973.djvu').readAsBytesSync();
    final page = djvuJb2Page(
      Uint8List.fromList(_firstChunkData(cable, 'Sjbz').take(1).toList()),
      width: 2550,
      height: 3301,
    );
    expect(() => Unseal.parse(page), throwsA(isA<DjvuException>()));
  });

  test('rejects an adversarial JB2 page declaration before output allocation', () {
    final cable = File('test/resources/djvu/cable-1973.djvu').readAsBytesSync();
    final page = djvuJb2Page(_firstChunkData(cable, 'Sjbz'), width: 20000, height: 6000);
    expect(() => Unseal.parse(page), throwsA(isA<DjvuException>()));
  });

  test('sizes a lower-resolution JPEG to the declared DjVu page', () {
    final book = parseDjvuBook(djvuJpegPage(jpeg, width: 16, height: 12));
    expect(book.pages.single.image.content, jpeg);
    expect(book.pages.single.width, 16);
    expect(book.pages.single.height, 12);
    expect(book.files.html.single.content, contains('width="16" height="12"'));
  });

  test('metadata accepts recognized codecs but full open rejects unsupported layers', () async {
    final bytes = djvuUnsupportedPage();
    expect(Unseal.readMetadataSync(bytes).format, BookFormat.djvu);
    expect(() => Unseal.parse(bytes), throwsA(isA<DjvuUnsupportedCodecException>()));
    final inspection = await Unseal.inspect(bytes);
    expect(inspection.error, isA<DjvuUnsupportedCodecException>());
    expect(inspection.detectedFormat, DetectedFormat.djvu);
  });

  test('decodes a real progressive color IW44 photo against its upstream pixels', () {
    final bytes = File('test/resources/djvu/chicken-iw44.djvu').readAsBytesSync();
    final book = Unseal.parse(bytes) as DjvuBook;
    final image = book.pages.single.image;

    expect(book.bytes, bytes);
    expect(image.type, 'bmp');
    expect(sniffImageType(image.content), ImageType.bmp);
    expect(imageSize(image.content), const ImageSize(181, 240));
    expect(
      sha256.convert(_bmpRgbBytes(image.content)).toString(),
      '5b7623de3a100f2d4e340d03e269e37547184fe2cae581609b471ed1ee92b6d9',
    );
    _expectReferenceGrid(image.content, const <List<List<int>>>[
      <List<int>>[
        [255, 252, 249],
        [212, 181, 159],
        [227, 209, 207],
        [213, 180, 170],
        [194, 161, 153],
      ],
      <List<int>>[
        [252, 247, 245],
        [180, 87, 28],
        [246, 151, 106],
        [146, 57, 16],
        [193, 165, 151],
      ],
      <List<int>>[
        [249, 250, 236],
        [235, 210, 199],
        [163, 69, 16],
        [184, 109, 59],
        [227, 199, 185],
      ],
      <List<int>>[
        [255, 252, 251],
        [253, 223, 143],
        [207, 217, 129],
        [244, 157, 123],
        [173, 167, 186],
      ],
      <List<int>>[
        [245, 244, 246],
        [255, 224, 191],
        [255, 245, 241],
        [176, 121, 49],
        [160, 129, 126],
      ],
    ]);
  });

  test('composes progressive BG44 and FG44 through a real JB2 mask', () {
    final bytes = File('test/resources/djvu/happy-birthday-iw44.djvu').readAsBytesSync();
    final book = Unseal.parse(bytes) as DjvuBook;
    final image = book.pages.single.image;

    expect(image.type, 'bmp');
    expect(imageSize(image.content), const ImageSize(475, 400));
    expect(
      sha256.convert(_bmpRgbBytes(image.content)).toString(),
      '150361d6f59cac4bbdca0c34d7f3d1e1989b652e8ead3e8b3643bf80552d78ad',
    );
    _expectReferenceGrid(image.content, const <List<List<int>>>[
      <List<int>>[
        [252, 241, 229],
        [255, 239, 229],
        [253, 242, 234],
        [251, 240, 230],
        [251, 240, 232],
      ],
      <List<int>>[
        [252, 241, 230],
        [247, 209, 212],
        [251, 241, 227],
        [254, 242, 233],
        [254, 241, 231],
      ],
      <List<int>>[
        [252, 242, 228],
        [255, 239, 239],
        [255, 245, 236],
        [70, 44, 18],
        [249, 242, 227],
      ],
      <List<int>>[
        [253, 241, 228],
        [245, 240, 194],
        [180, 171, 156],
        [180, 169, 157],
        [250, 239, 227],
      ],
      <List<int>>[
        [250, 242, 229],
        [252, 241, 229],
        [254, 242, 229],
        [252, 241, 229],
        [253, 242, 230],
      ],
    ], maxChannelError: 3);
  });

  test('decodes a real grayscale IW44 page to a deterministic raster', () {
    final bytes = File('test/resources/djvu/boy-iw44.djvu').readAsBytesSync();
    final book = Unseal.parse(bytes) as DjvuBook;
    final image = book.pages.single.image;
    final rgb = _bmpRgbBytes(image.content);

    expect(image.type, 'bmp');
    expect(imageSize(image.content), const ImageSize(192, 256));
    expect(
      sha256.convert(rgb).toString(),
      'a237ff54ff7bd43cd3096b0333ede3ce681c53f5635f8a642be12e5946f77717',
    );
    for (var index = 0; index < rgb.length; index += 3) {
      expect(rgb[index], rgb[index + 1]);
      expect(rgb[index], rgb[index + 2]);
    }
    expect(rgb.any((final channel) => channel < 32), isTrue);
    expect(rgb.any((final channel) => channel > 240), isTrue);
  });

  test('composes a real grayscale IW44 page with its JB2 mask', () {
    final bytes = File('test/resources/djvu/cable-1973.djvu').readAsBytesSync();
    final book = Unseal.parse(bytes) as DjvuBook;

    expect(Unseal.readMetadataSync(bytes).format, BookFormat.djvu);
    expect(book.pages, isNotEmpty);
    for (final page in book.pages) {
      final image = page.image;
      expect(image.type, 'bmp');
      expect(imageSize(image.content), ImageSize(page.width, page.height));
      expect(image.content.skip(54).any((final byte) => byte < 240), isTrue);
      expect(
        _sampleBmpRgb(image.content, page.width, page.height, 0, 0)[0],
        _sampleBmpRgb(image.content, page.width, page.height, 0, 0)[1],
      );
      expect(
        _sampleBmpRgb(image.content, page.width, page.height, 0, 0)[1],
        _sampleBmpRgb(image.content, page.width, page.height, 0, 0)[2],
      );
    }
  });

  test('rejects an IW44 page whose working planes exceed the raster budget', () {
    final bytes = File('test/resources/djvu/big-scanned-page.djvu').readAsBytesSync();
    expect(Unseal.readMetadataSync(bytes).format, BookFormat.djvu);
    expect(() => Unseal.parse(bytes), throwsA(isA<DjvuException>()));
  });

  test('rejects truncated lengths and invalid JPEG as typed failures', () {
    final truncated = Uint8List.fromList(fixture.sublist(0, fixture.length - 1));
    expect(() => Unseal.parse(truncated), throwsA(isA<DjvuException>()));
    final broken = djvuJpegPage(Uint8List.fromList(<int>[0, 1, 2]));
    expect(() => Unseal.parse(broken), throwsA(isA<DjvuException>()));
  });

  test('rejects invalid JB2 data instead of interpreting it as a JPEG', () {
    final bytes = djvuJpegPage(jpeg);
    // Replace BGjp with Sjbz while preserving the chunk's byte count.
    final marker = <int>[66, 71, 106, 112];
    final offset = _indexOf(bytes, marker);
    expect(offset, greaterThan(0));
    bytes.setRange(offset, offset + 4, <int>[83, 106, 98, 122]);
    expect(() => Unseal.parse(bytes), throwsA(isA<DjvuException>()));
  });
}

void _expectReferenceGrid(
  final Uint8List bmp,
  final List<List<List<int>>> expected, {
  final int maxChannelError = 1,
}) {
  final size = imageSize(bmp)!;
  final xs = <int>[0, size.width ~/ 4, size.width ~/ 2, size.width * 3 ~/ 4, size.width - 1];
  final ys = <int>[0, size.height ~/ 4, size.height ~/ 2, size.height * 3 ~/ 4, size.height - 1];
  expect(expected, hasLength(ys.length));
  for (var row = 0; row < ys.length; row++) {
    expect(expected[row], hasLength(xs.length));
    for (var column = 0; column < xs.length; column++) {
      final actual = _sampleBmpRgb(bmp, size.width, size.height, xs[column], ys[row]);
      for (var channel = 0; channel < 3; channel++) {
        expect(
          (actual[channel] - expected[row][column][channel]).abs(),
          lessThanOrEqualTo(maxChannelError),
          reason: 'RGB grid sample (${xs[column]}, ${ys[row]}) channel $channel',
        );
      }
    }
  }
}

Uint8List _bmpRgbBytes(final Uint8List bmp) {
  final size = imageSize(bmp)!;
  final view = ByteData.sublistView(bmp);
  final pixelOffset = view.getUint32(10, Endian.little);
  final signedHeight = view.getInt32(22, Endian.little);
  final rowStride = (size.width * 3 + 3) & ~3;
  final rgb = Uint8List(size.width * size.height * 3);
  for (var y = 0; y < size.height; y++) {
    final storedRow = signedHeight > 0 ? size.height - 1 - y : y;
    for (var x = 0; x < size.width; x++) {
      final bmpOffset = pixelOffset + storedRow * rowStride + x * 3;
      final rgbOffset = (y * size.width + x) * 3;
      rgb[rgbOffset] = bmp[bmpOffset + 2];
      rgb[rgbOffset + 1] = bmp[bmpOffset + 1];
      rgb[rgbOffset + 2] = bmp[bmpOffset];
    }
  }
  return rgb;
}

List<int> _sampleBmpRgb(
  final Uint8List bmp,
  final int width,
  final int height,
  final int x,
  final int y,
) {
  final view = ByteData.sublistView(bmp);
  final pixelOffset = view.getUint32(10, Endian.little);
  final signedHeight = view.getInt32(22, Endian.little);
  final storedRow = signedHeight > 0 ? height - 1 - y : y;
  final rowStride = (width * 3 + 3) & ~3;
  final offset = pixelOffset + storedRow * rowStride + x * 3;
  return <int>[bmp[offset + 2], bmp[offset + 1], bmp[offset]];
}

Uint8List _firstChunkData(final Uint8List bytes, final String id) {
  final offset = _indexOf(bytes, id.codeUnits);
  if (offset < 0 || offset + 8 > bytes.length) throw StateError('Missing $id fixture chunk.');
  final length = ByteData.sublistView(bytes).getUint32(offset + 4);
  if (length > bytes.length - offset - 8) throw StateError('Truncated $id fixture chunk.');
  return Uint8List.sublistView(bytes, offset + 8, offset + 8 + length);
}

int _indexOf(final Uint8List bytes, final List<int> needle) {
  for (var index = 0; index + needle.length <= bytes.length; index++) {
    var matched = true;
    for (var part = 0; part < needle.length; part++) {
      if (bytes[index + part] != needle[part]) matched = false;
    }
    if (matched) return index;
  }
  return -1;
}
