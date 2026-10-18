@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../support/djvu_fixture.dart';

// The compiled-worker lane for FGbz colors (doc/djvu-fgbz.md): the book is
// parsed by the real worker, never an inline fallback, and the composed
// page image carries the palette colors across the wire. Two sequential
// reads must answer from their own parse — the color state lives inside
// each page decode and nothing is shared between opens.
//
// The bytes are the tracked derived fixture (see PROVENANCE.md, generated
// by tool/djvu_fgbz_fixtures.py with the pinned DjVuLibre producer tools):
// a 64x32 mask page whose four repeated-glyph blits carry red, lime, blue,
// and yellow.

void main() {
  setUp(() {
    UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
  });

  tearDown(UnsealWorker.dispose);

  int pixelOf(final Uint8List bytes, final int x, final int y) {
    final view = ByteData.sublistView(bytes);
    final offset = view.getUint32(10, Endian.little);
    final width = view.getInt32(18, Endian.little);
    final height = view.getInt32(22, Endian.little);
    final bpp = view.getUint16(28, Endian.little);
    if (bpp != 24) throw StateError('expected a 24-bit BMP');
    final stride = (width * 3 + 3) & ~3;
    final row = offset + (height - 1 - y) * stride + x * 3;
    final blue = bytes[row];
    final green = bytes[row + 1];
    final red = bytes[row + 2];
    return (red << 16) | (green << 8) | blue;
  }

  test('worker parse keeps FGbz colors on the composed page image', () async {
    final bytes = base64Decode(
      'QVQmVEZPUk0AAABoREpWVUlORk8AAAAKAEAAIBgALAEWAVNqYnoAAAASgfrfW2zU7OYlcnjqOg2'
      'rXBq/RkdiegAAABuAAAQAAP8A/wD/AAAA//8AAAT///bjcxyAky0AQkc0NAAAAAwAYYECAAYAAwCDxS8=',
    );
    final book = await Unseal.read(bytes) as DjvuBook;
    expect(book.pageCount, 1);
    expect(await UnsealWorker.searchInWorker('worker proof'), isNotNull);
    final image = book.pages.single.image.content;
    // The composed raster must equal the VM decode byte for byte; the
    // browser can neither drift per pixel nor drop the color pass.
    expect(
      sha256.convert(image).toString(),
      '0344e2f6a6ca2f6f44d80d5d6eaabcb05266e9148837617b115914b688e1ab92',
    );
    expect(pixelOf(image, 8, 8), 0xFF0000);
    expect(pixelOf(image, 24, 8), 0x00FF00);
    expect(pixelOf(image, 40, 8), 0x0000FF);
    expect(pixelOf(image, 56, 8), 0xFFFF00);
    expect(pixelOf(image, 30, 26), 0xFFFFFF);
  });

  test('two worker opens answer from their own parse', () async {
    final bytes = base64Decode(
      'QVQmVEZPUk0AAABoREpWVUlORk8AAAAKAEAAIBgALAEWAVNqYnoAAAASgfrfW2zU7OYlcnjqOg2'
      'rXBq/RkdiegAAABuAAAQAAP8A/wD/AAAA//8AAAT///bjcxyAky0AQkc0NAAAAAwAYYECAAYAAwCDxS8=',
    );
    final first = await Unseal.read(bytes) as DjvuBook;
    final recolored = Uint8List.fromList(bytes);
    for (var i = 0; i < recolored.length - 16; i++) {
      if (String.fromCharCodes(recolored, i, i + 4) == 'FGbz') {
        recolored[i + 8 + 3 + 1] = 255; // G of palette entry zero.
        recolored[i + 8 + 3 + 2] = 0; // R of palette entry zero.
        break;
      }
    }
    final second = await Unseal.read(recolored) as DjvuBook;
    expect(await UnsealWorker.searchInWorker('worker proof'), isNotNull);
    expect(identical(first, second), isFalse);
    expect(pixelOf(first.pages.single.image.content, 8, 8), 0xFF0000);
    expect(pixelOf(second.pages.single.image.content, 8, 8), 0x00FF00);
  });
  test('FGbz plus TXTz keeps canonical text, zones, anchors and navigation in worker', () async {
    final color = base64Decode(
      'QVQmVEZPUk0AAABoREpWVUlORk8AAAAKAEAAIBgALAEWAVNqYnoAAAASgfrfW2zU7OYlcnjqOg2'
      'rXBq/RkdiegAAABuAAAQAAP8A/wD/AAAA//8AAAT///bjcxyAky0AQkc0NAAAAAwAYYECAAYAAwCDxS8=',
    );
    final txtz = base64Decode(cyrillicTxtzBase64);
    final chunk = ByteData(8)
      ..setUint32(0, 0x5458547a)
      ..setUint32(4, txtz.length);
    final page = Uint8List.fromList([
      ...color,
      ...chunk.buffer.asUint8List(),
      ...txtz,
      if (txtz.length.isOdd) 0,
    ]);
    ByteData.sublistView(page).setUint32(8, page.length - 12);
    final navm = base64Decode(
      '//+P/xQ42jii6kKH6iLihTc0+PRL18+BhZqP/YgENYdYhVVxXKXTFpI/wFbWidG37hAt9z/qkyPW5xOeaeDgWyfV330EMY5hrsP4PtPUWV104pS2JgjoX9gUH7U/',
    );
    final bytes = djvuBundleWithOutline([page], navm);
    final direct = Unseal.parse(bytes) as DjvuBook;
    final book = await Unseal.read(bytes) as DjvuBook;
    expect(book.pages.single.image.content, direct.pages.single.image.content);
    expect(book.pages.single.text, direct.pages.single.text);
    expect(
      book.navigation.navPoints.map((final point) => point.label),
      direct.navigation.navPoints.map((final point) => point.label),
    );
    final remote = await UnsealWorker.spatialDjvuPageInWorker(0);
    expect(remote, isNotNull); // An inline fallback cannot satisfy this.
    final local = direct.pageStructureAt(0)!;
    expect(remote!.canonicalText, local.canonicalText);
    expect(remote.spatialPage!.zones.length, local.spatialPage!.zones.length);
    final identity = PublicationRevision(
      publicationId: 'fgbz:text',
      sourceRevision: 'sha256:${sha256.convert(bytes)}',
      sourceEvidence: SourceEvidence.sha256,
    );
    final snapshot = local.snapshot(identity: identity);
    expect(snapshot.profile.sameProfile(djvuHiddenTextProfile), isTrue);
    final anchor = DurableAnnotations.capture(snapshot: snapshot, start: 0, end: 3);
    final resolved = DurableAnnotations.resolve(
      anchor: anchor,
      targets: [remote.snapshot(identity: identity)],
    );
    expect(resolved, isA<AnchorResolved>());
    expect((resolved as AnchorResolved).verified, isTrue);
    expect(await UnsealWorker.searchInWorker(local.canonicalText.substring(0, 3)), isNotNull);
  });
  test('worker preserves signed IW44 background samples in FGbz composite', () async {
    final bytes = base64Decode(
      'QVQmVEZPUk0AAACBREpWVUlORk8AAAAKAEAAIBgALAEWAVNqYnoAAAAPgfrfW2zU7OeOD8P7Q99mAEJHNDQAAAAlAEoBAgBAACCK/NR6j1DoVTXxGLl//6Na5zxFG0JQtjDnkyufTwBCRzQ0AAAAAgEARkdiegAAABOAAAL/AAAApf8AAAL///rf9cUv',
    );
    final book = await Unseal.read(bytes) as DjvuBook;
    expect(await UnsealWorker.searchInWorker('worker proof'), isNotNull);
    expect(
      sha256.convert(book.pages.single.image.content).toString(),
      '7078fb7a86a374f4162693bf7adb8ffd89cc0de56e111192be3e625961fed09b',
    );
  });
}
