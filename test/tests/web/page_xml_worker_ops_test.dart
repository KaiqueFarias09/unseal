// PAGE worker ops: the pure op handler must bind the sidecar identical
// to the inline feature code, and decode back through the wire codec
// with the identity tuple intact.
//
// runWorkerOp is pure and VM-safe, so the protocol is tested here
// without a browser; the Chrome lane proves the same op through the
// real compiled worker.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/src/platform/web/wire/spatial_wire.dart';
import 'package:unseal/src/platform/web/worker_ops.dart';
import 'package:unseal/unseal.dart';

Future<void> main() async {
  final goody = Uint8List.fromList(
    File('test/resources/djvu/goody-twoshoes.djvu').readAsBytesSync(),
  );
  final identity = PublicationRevision(
    publicationId: 'test:page-worker',
    sourceRevision: 'sha256:${sha256.convert(goody).toString()}',
    sourceEvidence: SourceEvidence.sha256,
  );

  final parseReply = await runWorkerOp(op: workerOpParse, bytes: goody);
  final resident = decodeBookWire(parseReply.json, parseReply.blobs);
  final inlineBook = parseDjvuBook(goody);
  final structure = inlineBook.pageStructureAt(1)!;
  final firstWord = structure.canonicalText
      .split('\n')
      .first
      .split(' ')
      .firstWhere((word) => word.trim().isNotEmpty)
      .trim();
  String escape(final String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final escapedWord = escape(firstWord);
  final pageXml = Uint8List.fromList(
    utf8.encode(
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15">'
      '<Metadata><Creator>OpOCR</Creator><Created>2026-01-01T00:00:00</Created>'
      '<LastChange>2026-01-01T00:00:00</LastChange></Metadata>'
      '<Page imageFilename="p.tif" imageWidth="100" imageHeight="50" orientation="180">'
      '<ReadingOrder><OrderedGroup id="g">'
      '<RegionRefIndexed index="0" regionRef="r1"/>'
      '</OrderedGroup></ReadingOrder>'
      '<TextRegion id="r1" primaryLanguage="German">'
      '<Coords points="0,0 100,0 100,20 0,20"/>'
      '<TextLine id="l1"><Coords points="0,0 100,0 100,10 0,10"/>'
      '<Word id="w1"><Coords points="0,0 40,10"/>'
      '<TextEquiv conf="0.87"><Unicode>$escapedWord</Unicode></TextEquiv></Word>'
      '<Word id="w2"><Coords points="45,0 80,10"/>'
      '<TextEquiv><Unicode>q</Unicode></TextEquiv></Word>'
      '</TextLine></TextRegion>'
      '</Page></PcGts>',
    ),
  );

  test('pageXml.bind serves the binding the inline code produces', () async {
    final reply = await runWorkerOp(
      op: workerOpPageXmlBind,
      bytes: pageXml,
      payload: <String, Object?>{
        wireKeyPageIndex: 1,
        wireKeyIdentity: encodePublicationRevisionWire(identity),
      },
      residentBook: resident,
    );
    expect(reply.kind, wireReplyPageXmlBind);
    final bound = decodePageXmlBoundTextWire(reply.json[wireKeyBound] as Map<String, Object?>);

    final inline = bindPageToSnapshot(
      document: parsePageXmlDocument(pageXml),
      target: structure.snapshot(identity: identity),
    );
    expect(bound.wordsResolved, inline.wordsResolved);
    expect(bound.wordsAmbiguous, inline.wordsAmbiguous);
    expect(bound.wordsMissing, inline.wordsMissing);
    expect(bound.pages.single.provenance.softwareName, 'OpOCR');
    // The rotation projects from the page's declared orientation.
    expect(bound.pages.single.rotation, 180);
    // The identity tuple survives the wire for verified reuse.
    expect(bound.targetIdentity.sameRevision(identity), isTrue);
    expect(bound.targetOccurrence, inline.targetOccurrence);
    expect(bound.targetProfile.sameProfile(inline.targetProfile), isTrue);
    expect(bound.targetTextRevision, inline.targetTextRevision);
    final wireZone = bound.pages.single.zones
        .firstWhere((zone) => zone.kind == SpatialZoneKind.word);
    final inlineZone = inline.pages.single.zones
        .firstWhere((zone) => zone.kind == SpatialZoneKind.word);
    expect(wireZone.rect, inlineZone.rect);
    expect(wireZone.textStart, inlineZone.textStart);
    expect(wireZone.confidence, 0.87);
  });

  test('pageXml.bind reports ambiguity places over the wire', () async {
    // A string the resident text really repeats: the first two
    // characters of any long word occur again later in the page.
    var repeated = '';
    var repeatedCount = 0;
    for (final token in structure.canonicalText.split(RegExp(r'\s+'))) {
      if (token.length < 4) continue;
      final candidate = token.substring(0, 2);
      var at = 0;
      var hits = 0;
      while (true) {
        at = structure.canonicalText.indexOf(candidate, at);
        if (at < 0) break;
        hits++;
        at++;
      }
      if (hits >= 2) {
        repeated = candidate;
        repeatedCount = hits;
        break;
      }
    }
    expect(repeatedCount, greaterThanOrEqualTo(2), reason: 'the page repeats some prefix');
    final ambiguousXml = Uint8List.fromList(
      utf8.encode(
        utf8
            .decode(pageXml)
            .replaceFirst('<Unicode>$escapedWord</Unicode>', '<Unicode>${escape(repeated)}</Unicode>')
            .replaceFirst('<Unicode>q</Unicode>', '<Unicode>${escape(repeated)}</Unicode>'),
      ),
    );
    final reply = await runWorkerOp(
      op: workerOpPageXmlBind,
      bytes: ambiguousXml,
      payload: <String, Object?>{
        wireKeyPageIndex: 1,
        wireKeyIdentity: encodePublicationRevisionWire(identity),
      },
      residentBook: resident,
    );
    final bound = decodePageXmlBoundTextWire(reply.json[wireKeyBound] as Map<String, Object?>);
    expect(bound.wordsAmbiguous, 2, reason: 'both sidecar words repeat in the target');
    final second = bound.ambiguousWords.last;
    expect(second.place.regionIndex, 0);
    expect(second.place.lineIndex, 0);
    expect(second.place.wordIndex, 1);
    expect(second.candidates.length, greaterThanOrEqualTo(2));
    expect(second.content, repeated);
  });

  test('pageXml.bind fails typed for parse corruption', () async {
    final corrupt = Uint8List.fromList(utf8.encode('not page xml'));
    expect(
      () => runWorkerOp(
        op: workerOpPageXmlBind,
        bytes: corrupt,
        payload: <String, Object?>{
          wireKeyPageIndex: 1,
          wireKeyIdentity: encodePublicationRevisionWire(identity),
        },
        residentBook: resident,
      ),
      throwsA(isA<PageXmlException>()),
    );
  });

  test('pageXml.bind fails typed without a DjVu resident book', () async {
    final epubBytes = Uint8List.fromList(
      File('test/resources/epub/Alices Adventures in Wonderland.epub').readAsBytesSync(),
    );
    final epubReply = await runWorkerOp(op: workerOpParse, bytes: epubBytes);
    final epubResident = decodeBookWire(epubReply.json, epubReply.blobs);
    expect(
      () => runWorkerOp(
        op: workerOpPageXmlBind,
        bytes: pageXml,
        payload: <String, Object?>{
          wireKeyPageIndex: 1,
          wireKeyIdentity: encodePublicationRevisionWire(identity),
        },
        residentBook: epubResident,
      ),
      throwsA(isA<UnsealException>()),
    );
  });
}
