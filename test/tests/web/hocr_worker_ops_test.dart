// hOCR worker ops: the pure op handler must bind the sidecar identical to
// the inline feature code, and decode back through the wire codec with the
// identity tuple and the ambiguity places intact.
//
// runWorkerOp is pure and VM-safe, so the protocol is tested here without
// a browser; the Chrome lane proves the same op through the real compiled
// worker.
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
    publicationId: 'test:hocr-worker',
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
      .firstWhere((final word) => word.trim().isNotEmpty)
      .trim();
  String escape(final String text) =>
      text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  final escapedWord = escape(firstWord);
  final hocr = Uint8List.fromList(
    utf8.encode(
      '<html><head><meta name="ocr-system" content="OpOCR 1"/>'
      '<meta name="ocr-capabilities" content="ocr_page ocr_line ocrx_word ocrp_wconf"/></head><body>'
      '<div class="ocr_page" title="bbox 0 0 100 50; scan_res 72 72">'
      '<span class="ocr_line" title="bbox 0 0 100 20; baseline 0.01 -1">'
      '<span class="ocrx_word" title="bbox 0 0 40 20; x_wconf 87">$escapedWord</span>'
      '<span class="ocrx_word" title="bbox 45 0 80 20">q</span>'
      '</span></div></body></html>',
    ),
  );

  test('hocr.bind serves the binding the inline code produces', () async {
    final reply = await runWorkerOp(
      op: workerOpHocrBind,
      bytes: hocr,
      payload: <String, Object?>{
        wireKeyPageIndex: 1,
        wireKeyIdentity: encodePublicationRevisionWire(identity),
      },
      residentBook: resident,
    );
    expect(reply.kind, wireReplyHocrBind);
    final bound = decodeHocrBoundTextWire(reply.json[wireKeyBound] as Map<String, Object?>);

    final inline = bindHocrToSnapshot(
      document: parseHocrDocument(hocr),
      target: structure.snapshot(identity: identity),
    );
    expect(bound.wordsResolved, inline.wordsResolved);
    expect(bound.wordsAmbiguous, inline.wordsAmbiguous);
    expect(bound.wordsMissing, inline.wordsMissing);
    expect(bound.pages.single.provenance.softwareName, 'OpOCR 1');
    expect(bound.pages.single.rotation, 0, reason: 'hOCR never projects a rotation');
    expect(bound.pages.single.provenance.hasConfidence, isTrue);
    // The identity tuple survives the wire for verified reuse.
    expect(bound.targetIdentity.sameRevision(identity), isTrue);
    expect(bound.targetOccurrence, inline.targetOccurrence);
    expect(bound.targetProfile.sameProfile(inline.targetProfile), isTrue);
    expect(bound.targetTextRevision, inline.targetTextRevision);
    expect(bound.pageIndexes, inline.pageIndexes);
    final wireZone = bound.pages.single.zones.firstWhere(
      (final zone) => zone.kind == SpatialZoneKind.word,
    );
    final inlineZone = inline.pages.single.zones.firstWhere(
      (final zone) => zone.kind == SpatialZoneKind.word,
    );
    expect(wireZone.rect, inlineZone.rect);
    expect(wireZone.textStart, inlineZone.textStart);
    expect(wireZone.confidence, 0.87);
  });

  test('hocr.bind reports ambiguity places over the wire', () async {
    // A prefix the resident text really repeats.
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
    final ambiguous = Uint8List.fromList(
      utf8.encode(utf8.decode(hocr).replaceAll(escapedWord, escape(repeated))),
    );
    final reply = await runWorkerOp(
      op: workerOpHocrBind,
      bytes: ambiguous,
      payload: <String, Object?>{
        wireKeyPageIndex: 1,
        wireKeyIdentity: encodePublicationRevisionWire(identity),
      },
      residentBook: resident,
    );
    final bound = decodeHocrBoundTextWire(reply.json[wireKeyBound] as Map<String, Object?>);
    final inline = bindHocrToSnapshot(
      document: parseHocrDocument(ambiguous),
      target: structure.snapshot(identity: identity),
    );
    expect(bound.wordsAmbiguous, greaterThanOrEqualTo(1));
    expect(bound.wordsAmbiguous, inline.wordsAmbiguous);
    expect(
      bound.ambiguousUnits.single.place.pageIndex,
      inline.ambiguousUnits.single.place.pageIndex,
    );
    expect(
      bound.ambiguousUnits.single.place.lineIndex,
      inline.ambiguousUnits.single.place.lineIndex,
    );
    expect(
      bound.ambiguousUnits.single.place.wordIndex,
      inline.ambiguousUnits.single.place.wordIndex,
    );
    expect(bound.ambiguousUnits.single.candidates, inline.ambiguousUnits.single.candidates);
    expect(bound.ambiguousUnits.single.chosen, inline.ambiguousUnits.single.chosen);
  });

  test('hocr.bind refuses corruption with its own type through the error wire', () async {
    // The op throws; the worker shell wraps the failure into an error reply
    // whose type name must decode back to the same class.
    await expectLater(
      runWorkerOp(
        op: workerOpHocrBind,
        bytes: Uint8List.fromList(utf8.encode('<div class="ocr_page" title="bbox')),
        payload: <String, Object?>{
          wireKeyPageIndex: 1,
          wireKeyIdentity: encodePublicationRevisionWire(identity),
        },
        residentBook: resident,
      ),
      throwsA(isA<HocrException>()),
    );
    await expectLater(
      runWorkerOp(
        op: workerOpHocrBind,
        bytes: Uint8List.fromList(
          utf8.encode(
            '<html><body><div class="ocr_page" title="bbox 0 0 10 10"><span class="ocr_line" title="bbox 0 0 5 5; order 1">a</span></div></body></html>',
          ),
        ),
        payload: <String, Object?>{
          wireKeyPageIndex: 1,
          wireKeyIdentity: encodePublicationRevisionWire(identity),
        },
        residentBook: resident,
      ),
      throwsA(isA<HocrUnsupportedFeatureException>()),
    );
    final decoded = decodeErrorWire('HocrException', 'hOCR input is malformed.');
    expect(decoded, isA<HocrException>());
    final unsupported = decodeErrorWire('HocrUnsupportedFeatureException', 'order');
    expect(unsupported, isA<HocrUnsupportedFeatureException>());
  });

  test('hocr.bind demands a resident DjVu book', () async {
    expect(
      () => runWorkerOp(
        op: workerOpHocrBind,
        bytes: hocr,
        payload: <String, Object?>{
          wireKeyPageIndex: 1,
          wireKeyIdentity: encodePublicationRevisionWire(identity),
        },
      ),
      throwsA(isA<UnsealException>()),
    );
  });
}
