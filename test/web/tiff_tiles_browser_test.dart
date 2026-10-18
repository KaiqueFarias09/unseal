@TestOn('browser')
library;

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/src/platform/web/worker_client.dart';
import 'package:unseal/unseal.dart';

import '../support/tiff_tiled_embedded.dart';
import '../support/tiff_tiled_goldens.dart';

String _hash(final List<int> bytes) => sha256.convert(bytes).toString();

void _expectGolden(final TiffBook book, final String name) {
  final expected = tiledTiffGoldens[name]!;
  expect(book.pageCount, expected.length, reason: '$name page count');
  for (var page = 0; page < expected.length; page++) {
    expect(_hash(book.pages[page].image.content), expected[page], reason: '$name page ${page + 1}');
  }
}

void main() {
  setUp(() {
    // The Chrome lane builds this worker before running test/web/.
    UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
  });

  tearDown(UnsealWorker.dispose);

  test('tiled pages decode to the VM goldens in the browser (dart2js)', () {
    expect(embeddedTiledTiffFixtures, isNotEmpty);
    embeddedTiledTiffFixtures.forEach((final name, final bytes) {
      _expectGolden(Unseal.parse(bytes) as TiffBook, name);
    });
  });

  test('the real worker decodes tiled pages to the same pixels over the wire', () async {
    for (final entry in embeddedTiledTiffFixtures.entries) {
      final book = await WorkerClient.instance.parseInWorker(entry.value);
      expect(book, isNotNull, reason: '${entry.key} must be decoded by the real Web Worker');
      _expectGolden(book! as TiffBook, entry.key);
    }
    final big =
        await Unseal.read(embeddedTiledTiffFixtures['gray16-zip2-t16-big-be.tif']!) as TiffBook;
    expect(big.isBigTiff, isTrue);
    _expectGolden(big, 'gray16-zip2-t16-big-be.tif');
  });

  test('a mixed strip/tiled book keeps every page and its metadata across the wire', () {
    final book = Unseal.parse(embeddedTiledTiffFixtures['mixed-strip-tile-3page.tif']!) as TiffBook;
    final (json, blobs) = encodeBookWire(book);
    final decoded = decodeBookWire(json, blobs) as TiffBook;
    expect(decoded.pageCount, 3);
    expect(decoded.pages.map((final page) => (page.width, page.height, page.dpi)).toList(), [
      for (final page in book.pages) (page.width, page.height, page.dpi),
    ]);
    for (var index = 0; index < 3; index++) {
      expect(decoded.pages[index].image.content, book.pages[index].image.content);
    }
    expect(decoded.readingOrder.map((final item) => item.name).toList(), [
      'text/page-1.html',
      'text/page-2.html',
      'text/page-3.html',
    ]);
    expect(decoded.bytes, book.bytes);
    _expectGolden(decoded, 'mixed-strip-tile-3page.tif');
  });

  test('typed tiled failures cross the error wire', () {
    expect(decodeErrorWire('TiffException', 'segments overlap'), isA<TiffException>());
    expect(
      decodeErrorWire('TiffUnsupportedCodecException', 'Orientation 6'),
      isA<TiffUnsupportedCodecException>(),
    );
  });
}
