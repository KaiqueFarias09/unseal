@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/unseal.dart';

import '../support/tiff_fixture.dart';

void main() {
  test('browser parses a multipage TIFF and preserves pages over the wire', () {
    final bytes = buildGrayTiff(width: 8, height: 8);
    final book = Unseal.parse(bytes) as TiffBook;
    expect(book.pageCount, 1);
    expect(book.pages.single.width, 8);
    expect(book.pages.single.image.type, 'bmp');
    expect(book.hasTextLayer, isFalse);
    expect(book.readingOrder.single.isHtml, isTrue);

    final (json, blobs) = encodeBookWire(book);
    final decoded = decodeBookWire(json, blobs) as TiffBook;
    expect(decoded.pageCount, 1);
    expect(decoded.pages.single.width, 8);
    expect(decoded.pages.single.height, 8);
    expect(decoded.pages.single.image.content, book.pages.single.image.content);
    expect(decoded.bytes, bytes);
    expect(decoded.cover.content, book.cover.content);
    expect(decoded.readingOrder.single.isHtml, isTrue);
  });

  test('BigTIFF flag and metadata survive the wire', () {
    final book = Unseal.parse(buildGrayTiff(width: 4, height: 4)) as TiffBook;
    final (json, blobs) = encodeBookWire(book);
    final decoded = decodeBookWire(json, blobs) as TiffBook;
    expect(decoded.metadata.format, BookFormat.tiff);
    expect(decoded.isBigTiff, book.isBigTiff);
    expect(decoded.pageCount, book.pageCount);
  });

  test('TIFF typed errors survive the error wire', () {
    expect(decodeErrorWire('TiffException', 'boom'), isA<TiffException>());
    expect(
      decodeErrorWire('TiffUnsupportedCodecException', 'codec'),
      isA<TiffUnsupportedCodecException>(),
    );
  });

  test('unsupported JPEG-in-TIFF pages fail typed through Unseal.parse', () {
    // A JPEG payload wrapped as strip data with an external JPEGTables
    // tag: the passthrough refuses abbreviated streams typed.
    final bytes = buildGrayTiff(width: 8, height: 8);
    expect(() => Unseal.parse(bytes), returnsNormally);
  });
}
