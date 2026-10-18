@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../support/djvu_fixture.dart';

// The compiled-worker lane: hocr.bind runs against the book the worker
// kept resident from the last parse, over the real message channel — never
// an inline fallback. Two binds in a row prove each request answers on its
// own identity.

void main() {
  setUp(() {
    UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
  });

  tearDown(UnsealWorker.dispose);

  test('worker binds hOCR onto the resident page snapshot', () async {
    final txtz = base64Decode(cyrillicTxtzBase64);
    final bytes = djvuJpegPage(tinyJpeg, txtz: txtz);
    final book = await Unseal.read(bytes) as DjvuBook;
    final canonical = book.pages.single.text;
    final firstWord = canonical
        .split('\n')
        .first
        .split(' ')
        .firstWhere((final word) => word.trim().isNotEmpty)
        .trim();
    final escaped = firstWord
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final hocr =
        '<html><head><meta name="ocr-system" content="BrowserOCR 2"/></head><body>'
        '<div class="ocr_page" title="bbox 0 0 8 8; scan_res 72">'
        '<span class="ocr_line" title="bbox 0 0 8 4; baseline 0 -1">'
        '<span class="ocrx_word" title="bbox 0 0 4 4; x_wconf 95">$escaped</span>'
        '</span></div></body></html>';
    final identity = PublicationRevision(publicationId: 'browser:hocr');

    final bound = await UnsealWorker.bindHocrInWorker(
      hocrBytes: Uint8List.fromList(utf8.encode(hocr)),
      pageIndex: 0,
      identity: identity,
    );
    expect(bound, isNotNull, reason: 'the real worker must serve hocr.bind');
    expect(bound!.targetIdentity, identity);
    expect(bound.wordsResolved + bound.wordsAmbiguous, greaterThan(0));
    final wordZone = bound.pages.single.zones.firstWhere(
      (final zone) => zone.kind == SpatialZoneKind.word,
    );
    expect(wordZone.confidence, 0.95);
    expect(bound.pages.single.provenance.softwareName, 'BrowserOCR 2');
    // hOCR never rotates: the spatial page stays at zero even though the
    // scan resolution parsed.
    expect(bound.pages.single.rotation, 0);
    expect(bound.pageIndexes, <int>[0]);
  });

  test('alternative ancestors and concurrent identities survive the real worker', () async {
    final bytes = djvuJpegPage(tinyJpeg, txtz: base64Decode(cyrillicTxtzBase64));
    final book = await Unseal.read(bytes) as DjvuBook;
    final selected = book.pages.single.text
        .split(RegExp(r'\s+'))
        .firstWhere((final word) => word.isNotEmpty)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final sidecar = Uint8List.fromList(
      utf8.encode(
        '<div class="ocr_page" title="bbox 0 0 8 8">'
        '<div class="alternatives"><ins>'
        '<span class="ocr_line" title="bbox 0 0 8 4">$selected</span>'
        '</ins><del><span class="ocr_line" title="bbox 0 4 8 8">discarded</span></del>'
        '</div></div>',
      ),
    );
    final identities = [
      PublicationRevision(publicationId: 'browser:hocr-concurrent-a'),
      PublicationRevision(publicationId: 'browser:hocr-concurrent-b'),
    ];
    final results = await Future.wait([
      for (final identity in identities)
        UnsealWorker.bindHocrInWorker(hocrBytes: sidecar, pageIndex: 0, identity: identity),
    ]);
    for (var i = 0; i < results.length; i++) {
      final result = results[i];
      expect(result, isNotNull, reason: 'hocr.bind must execute on the real worker');
      expect(result!.targetIdentity, identities[i]);
      expect(result.wordsResolved, 0);
      expect(result.wordsAmbiguous, 1);
      expect(result.wordsMissing, 0);
    }
  });

  test('a second bind answers independently with its own identity', () async {
    final txtz = base64Decode(cyrillicTxtzBase64);
    final bytes = djvuJpegPage(tinyJpeg, txtz: txtz);
    await Unseal.read(bytes) as DjvuBook;

    const hocr =
        '<html><head><meta name="ocr-system" content="Second 1"/></head><body>'
        '<div class="ocr_page" title="bbox 0 0 8 8">'
        '<span class="ocr_line" title="bbox 0 0 8 4">nothing matches this</span>'
        '</div></body></html>';
    final identity = PublicationRevision(publicationId: 'browser:hocr-2');
    final second = await UnsealWorker.bindHocrInWorker(
      hocrBytes: Uint8List.fromList(utf8.encode(hocr)),
      pageIndex: 0,
      identity: identity,
    );
    expect(second, isNotNull);
    expect(second!.targetIdentity, identity);
    expect(second.pages.single.provenance.softwareName, 'Second 1');
    // The line's plain text never occurs: missing stays observable
    // through the wire.
    expect(second.wordsMissing, 1);
  });

  test('the worker rejects hOCR corruption typed', () async {
    final txtz = base64Decode(cyrillicTxtzBase64);
    final bytes = djvuJpegPage(tinyJpeg, txtz: txtz);
    await Unseal.read(bytes) as DjvuBook;

    await expectLater(
      UnsealWorker.bindHocrInWorker(
        hocrBytes: Uint8List.fromList(utf8.encode('<div class="ocr_page" title="bbox')),
        pageIndex: 0,
        identity: PublicationRevision(publicationId: 'browser:hocr-bad'),
      ),
      throwsA(isA<HocrException>()),
    );
    await expectLater(
      UnsealWorker.bindHocrInWorker(
        hocrBytes: Uint8List.fromList(
          utf8.encode(
            '<html><body><div class="ocr_page" title="bbox 0 0 8 8">'
            '<span class="ocr_line" title="bbox 0 0 4 4; order 1">a</span></div></body></html>',
          ),
        ),
        pageIndex: 0,
        identity: PublicationRevision(publicationId: 'browser:hocr-order'),
      ),
      throwsA(isA<HocrUnsupportedFeatureException>()),
    );
  });
}
