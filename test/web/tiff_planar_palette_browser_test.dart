@TestOn('browser')
library;

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/src/platform/web/worker_client.dart';
import 'package:unseal/unseal.dart';

import '../support/tiff_planar_palette_embedded.dart';
import '../support/tiff_planar_palette_goldens.dart';

String _hash(final List<int> bytes) => sha256.convert(bytes).toString();

void _expectGolden(final TiffBook book, final String name) {
  final expected = planarPaletteTiffGoldens[name]!;
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

  test('planar and palette pages decode to the VM goldens in the browser (dart2js)', () {
    expect(embeddedPlanarPaletteFixtures, isNotEmpty);
    embeddedPlanarPaletteFixtures.forEach((final name, final bytes) {
      _expectGolden(Unseal.parse(bytes) as TiffBook, name);
    });
  });

  test('the real worker decodes planar and palette pages to the same pixels', () async {
    for (final entry in embeddedPlanarPaletteFixtures.entries) {
      final book = await WorkerClient.instance.parseInWorker(entry.value);
      expect(book, isNotNull, reason: '${entry.key} must be decoded by the real Web Worker');
      _expectGolden(book! as TiffBook, entry.key);
    }
    final big =
        await Unseal.read(embeddedPlanarPaletteFixtures['planar8-zip2-t16-big.tif']!) as TiffBook;
    expect(big.isBigTiff, isTrue);
    _expectGolden(big, 'planar8-zip2-t16-big.tif');
  });

  test('a mixed planar/palette book keeps every page across the wire', () {
    final book =
        Unseal.parse(embeddedPlanarPaletteFixtures['mixed-planar-palette-3page.tif']!) as TiffBook;
    final (json, blobs) = encodeBookWire(book);
    final decoded = decodeBookWire(json, blobs) as TiffBook;
    expect(decoded.pageCount, 3);
    expect(decoded.pages.map((final page) => (page.width, page.height, page.dpi)).toList(), [
      for (final page in book.pages) (page.width, page.height, page.dpi),
    ]);
    for (var index = 0; index < 3; index++) {
      expect(decoded.pages[index].image.content, book.pages[index].image.content);
    }
    expect(decoded.bytes, book.bytes);
    _expectGolden(decoded, 'mixed-planar-palette-3page.tif');
  });

  test('typed planar/palette failures cross the error wire', () {
    expect(decodeErrorWire('TiffException', 'ColorMap holds 3 entries'), isA<TiffException>());
    expect(
      decodeErrorWire('TiffUnsupportedCodecException', 'alpha or extra samples'),
      isA<TiffUnsupportedCodecException>(),
    );
  });
}
