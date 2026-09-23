@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:unseal/src/features/chm/chm_lzx.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/unseal.dart';

import '../tests/chm/chm_fixture_builder.dart';

void main() {
  test('CHM parses on the web and survives the structured-clone wire', () async {
    final book = await Unseal.read(chmFixture()) as DocumentBook;
    expect(book.format, BookFormat.chm);
    expect(book.files.html.length, 2);
    final (json, blobs) = encodeBookWire(book);
    final decoded = decodeBookWire(decodeJson(encodeJson(json)), blobs) as DocumentBook;
    expect(decoded.metadata.title, 'Small CHM');
    expect(decoded.navigation.navPoints.single.subNavPoints.single.label, 'Next');
    expect(decoded.readingOrder.map((final item) => item.name), ['index.html', 'chapter.html']);
  });

  test('LZX uncompressed blocks decode in Chrome', () {
    expect(ChmLzxDecoder(15).decodeFrame(lzxRawFrame('Browser LZX'), 11), 'Browser LZX'.codeUnits);
  });
}
