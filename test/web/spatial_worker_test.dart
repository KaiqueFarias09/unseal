@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../support/djvu_fixture.dart';

// The compiled-worker lane: spatial ops run against the book the worker
// kept resident from the last parse, over the real message channel —
// never an inline fallback.

void main() {
  setUp(() {
    UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
  });

  tearDown(UnsealWorker.dispose);

  test('worker serves the resident DjVu page structure with zones', () async {
    final txtz = base64Decode(cyrillicTxtzBase64);
    final bytes = djvuJpegPage(tinyJpeg, txtz: txtz);
    final book = await Unseal.read(bytes) as DjvuBook;
    expect(book.pages.single.text, startsWith('(ЩУ И МШИ'));

    final structure = await UnsealWorker.spatialDjvuPageInWorker(0);
    expect(structure, isNotNull, reason: 'the real worker must serve spatial.djvuPage');
    expect(structure!.canonicalText, book.pages.single.text);
    expect(structure.hasZones, isTrue);
    final words = structure.spatialPage!.zones
        .where((zone) => zone.kind == SpatialZoneKind.word)
        .toList();
    expect(words, isNotEmpty);
    // Cyrillic zone text maps onto UTF-16 ranges of the same canonical
    // text.
    final word = words.first;
    expect(
      structure.canonicalText.substring(word.textStart, word.textEnd),
      isNotEmpty,
    );
  });

  test('worker binds ALTO onto the resident page snapshot', () async {
    final txtz = base64Decode(cyrillicTxtzBase64);
    final bytes = djvuJpegPage(tinyJpeg, txtz: txtz);
    final book = await Unseal.read(bytes) as DjvuBook;

    // The hidden text's own first words, in the ALTO the host would
    // import: UTF-8 XML whose words must land on the target's UTF-16
    // ranges.
    final firstWord = book.pages.single.text
        .split('\n')
        .first
        .split(' ')
        .firstWhere((w) => w.trim().isNotEmpty)
        .trim();
    final alto = '''<?xml version="1.0" encoding="UTF-8"?>
<alto xmlns="http://www.loc.gov/standards/alto/ns-v3#">
  <Description><MeasurementUnit>pixel</MeasurementUnit>
    <OCRProcessing ID="I"><ocrProcessingStep><processingSoftware>
      <softwareName>BrowserOCR</softwareName><softwareVersion>1</softwareVersion>
    </processingSoftware></ocrProcessingStep></OCRProcessing>
  </Description>
  <Layout><Page WIDTH="8" HEIGHT="8">
    <PrintSpace HPOS="0" VPOS="0" WIDTH="8" HEIGHT="8">
      <TextBlock HPOS="0" VPOS="0" WIDTH="8" HEIGHT="8">
        <TextLine HPOS="0" VPOS="0" WIDTH="8" HEIGHT="2">
          <String HPOS="0" VPOS="0" WIDTH="4" HEIGHT="2" CONTENT="$firstWord" WC="0.9"/>
        </TextLine>
      </TextBlock>
    </PrintSpace>
  </Page></Layout>
</alto>
''';
    final identity = PublicationRevision(publicationId: 'browser:spatial');
    final bound = await UnsealWorker.bindAltoInWorker(
      altoBytes: Uint8List.fromList(utf8.encode(alto)),
      pageIndex: 0,
      identity: identity,
    );
    expect(bound, isNotNull, reason: 'the real worker must serve spatial.altoBind');
    expect(bound!.targetIdentity, identity);
    expect(bound.wordsResolved + bound.wordsAmbiguous, greaterThan(0));
    final wordZone = bound.pages.single.zones.firstWhere(
      (zone) => zone.kind == SpatialZoneKind.word,
    );
    expect(wordZone.confidence, 0.9);
    expect(
      bound.pages.single.provenance.softwareName,
      'BrowserOCR',
    );
  });

  test('worker spatial op fails typed for a non-DjVu resident book', () async {
    // The resident book from this parse has no hidden-text chunk: the
    // structure op answers null rather than throwing.
    final bytes = djvuJpegPage(tinyJpeg);
    await Unseal.read(bytes);
    final structure = await UnsealWorker.spatialDjvuPageInWorker(0);
    expect(structure, isNull);
  });
}
