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

  test('rejects non-JPEG image layers even beside a JPEG', () {
    final bytes = djvuJpegPage(jpeg);
    // Replace BGjp with Sjbz while preserving the chunk's byte count.
    final marker = <int>[66, 71, 106, 112];
    final offset = _indexOf(bytes, marker);
    expect(offset, greaterThan(0));
    bytes.setRange(offset, offset + 4, <int>[83, 106, 98, 122]);
    expect(() => Unseal.parse(bytes), throwsA(isA<DjvuUnsupportedCodecException>()));
  });
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
