import 'dart:io';
import 'dart:typed_data';

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

  test('metadata accepts recognized codecs but full open rejects invisibility', () async {
    final bytes = djvuUnsupportedPage();
    expect(Unseal.readMetadataSync(bytes).format, BookFormat.djvu);
    expect(() => Unseal.parse(bytes), throwsA(isA<DjvuUnsupportedCodecException>()));
    final inspection = await Unseal.inspect(bytes);
    expect(inspection.error, isA<DjvuUnsupportedCodecException>());
    expect(inspection.detectedFormat, DetectedFormat.djvu);
  });

  test('real-world JB2 and IW44 files are recognized but not opened invisibly', () {
    for (final name in <String>['cable-1973.djvu', 'big-scanned-page.djvu']) {
      final bytes = File('test/resources/djvu/$name').readAsBytesSync();
      expect(Unseal.readMetadataSync(bytes).format, BookFormat.djvu, reason: name);
      expect(
        () => Unseal.parse(bytes),
        throwsA(isA<DjvuUnsupportedCodecException>()),
        reason: name,
      );
    }
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
