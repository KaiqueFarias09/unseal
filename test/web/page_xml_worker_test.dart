@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../support/djvu_fixture.dart';

// The compiled-worker lane: pageXml.bind runs against the book the
// worker kept resident from the last parse, over the real message
// channel — never an inline fallback. Two binds in a row prove each
// request answers on its own identity.

void main() {
  setUp(() {
    UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
  });

  tearDown(UnsealWorker.dispose);

  test('worker binds PAGE XML onto the resident page snapshot', () async {
    final txtz = base64Decode(cyrillicTxtzBase64);
    final bytes = djvuJpegPage(tinyJpeg, txtz: txtz);
    final book = await Unseal.read(bytes) as DjvuBook;
    final canonical = book.pages.single.text;
    final firstWord = canonical
        .split('\n')
        .first
        .split(' ')
        .firstWhere((word) => word.trim().isNotEmpty)
        .trim();
    final escaped = firstWord
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final pageXml =
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15">'
        '<Metadata><Creator>BrowserOCR</Creator><Created>2026-01-01T00:00:00</Created>'
        '<LastChange>2026-01-01T00:00:00</LastChange></Metadata>'
        '<Page imageFilename="p.tif" imageWidth="8" imageHeight="8" orientation="90">'
        '<TextRegion id="r1" primaryLanguage="Russian">'
        '<Coords points="0,0 8,0 8,4 0,4"/>'
        '<TextLine id="l1"><Coords points="0,0 8,0 8,2 0,2"/>'
        '<Word id="w1"><Coords points="0,0 4,2"/>'
        '<TextEquiv conf="0.9"><Unicode>$escaped</Unicode></TextEquiv></Word>'
        '</TextLine></TextRegion>'
        '</Page></PcGts>';
    final identity = PublicationRevision(publicationId: 'browser:page');

    final bound = await UnsealWorker.bindPageXmlInWorker(
      pageBytes: Uint8List.fromList(utf8.encode(pageXml)),
      pageIndex: 0,
      identity: identity,
    );
    expect(bound, isNotNull, reason: 'the real worker must serve pageXml.bind');
    expect(bound!.targetIdentity, identity);
    expect(bound.wordsResolved + bound.wordsAmbiguous, greaterThan(0));
    final wordZone = bound.pages.single.zones.firstWhere(
      (zone) => zone.kind == SpatialZoneKind.word,
    );
    expect(wordZone.confidence, 0.9);
    expect(bound.pages.single.provenance.softwareName, 'BrowserOCR');
    // The page's declared orientation projects as the zone page's
    // rotation.
    expect(bound.pages.single.rotation, 90);
  });

  test('a second bind answers independently with its own identity', () async {
    final txtz = base64Decode(cyrillicTxtzBase64);
    final bytes = djvuJpegPage(tinyJpeg, txtz: txtz);
    await Unseal.read(bytes) as DjvuBook;

    const pageXml =
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15">'
        '<Metadata><Creator>Second</Creator><Created>2026-01-01T00:00:00</Created>'
        '<LastChange>2026-01-01T00:00:00</LastChange></Metadata>'
        '<Page imageFilename="p.tif" imageWidth="8" imageHeight="8">'
        '<TextRegion id="r1"><Coords points="0,0 8,0 8,4 0,4"/>'
        '<TextEquiv><Unicode>nothing matches this</Unicode></TextEquiv>'
        '</TextRegion>'
        '</Page></PcGts>';
    final identity = PublicationRevision(publicationId: 'browser:page-2');
    final second = await UnsealWorker.bindPageXmlInWorker(
      pageBytes: Uint8List.fromList(utf8.encode(pageXml)),
      pageIndex: 0,
      identity: identity,
    );
    expect(second, isNotNull);
    expect(second!.targetIdentity, identity);
    expect(second.pages.single.provenance.softwareName, 'Second');
    // The sidecar's region-level text never occurs: missing stays
    // observable through the wire.
    expect(second.wordsMissing, 1);
  });

  test('the worker rejects PAGE corruption typed', () async {
    final txtz = base64Decode(cyrillicTxtzBase64);
    final bytes = djvuJpegPage(tinyJpeg, txtz: txtz);
    await Unseal.read(bytes) as DjvuBook;

    await expectLater(
      UnsealWorker.bindPageXmlInWorker(
        pageBytes: Uint8List.fromList(utf8.encode('<PcGts oops')),
        pageIndex: 0,
        identity: PublicationRevision(publicationId: 'browser:bad'),
      ),
      throwsA(isA<PageXmlException>()),
    );
  });
}
