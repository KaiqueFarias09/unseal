@TestOn('browser')
library;

import 'dart:typed_data';

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

  test('CHM selects legacy codepages from the #SYSTEM locale in Chrome', () async {
    for (final codePage in const [1251, 1252, 1256]) {
      final book = await Unseal.read(chmLegacyCodePageFixture(codePage: codePage)) as DocumentBook;
      final expectedText = switch (codePage) {
        1251 => 'Привет мир',
        1252 => 'Très bien café',
        1256 => 'سلام عليكم',
        _ => throw StateError('Unexpected fixture codepage.'),
      };
      expect(book.files.html.single.content, contains(expectedText));
    }
  });

  test('LZX Intel E8 addresses are restored in Chrome', () {
    final transformed = Uint8List(64);
    transformed[8] = 0xe8;
    ByteData.sublistView(transformed).setInt32(9, 108, Endian.little);
    final decoded = ChmLzxDecoder(
      15,
    ).decodeFrame(lzxRawFrameBytes(transformed, intelFileSize: 4096), transformed.length);
    expect(ByteData.sublistView(decoded).getInt32(9, Endian.little), 100);
  });
}
