// Spatial worker ops: the pure op handler must serve the resident DjVu
// book's page structure and ALTO bindings identical to the inline
// feature code, with stable failure types across the wire.
//
// runWorkerOp is pure and VM-safe, so the protocol is tested here
// without a browser; the Chrome lane proves the same ops through the
// real compiled worker.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/alto.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/src/platform/web/wire/spatial_wire.dart';
import 'package:unseal/src/platform/web/worker_ops.dart';
import 'package:unseal/unseal.dart';

void main() {
  final goody = Uint8List.fromList(
    File('test/resources/djvu/goody-twoshoes.djvu').readAsBytesSync(),
  );
  final altoXml = Uint8List.fromList(
    utf8.encode(File('test/resources/alto/goody-page2-tesseract.xml').readAsStringSync()),
  );
  final identity = PublicationRevision(
    publicationId: 'test:spatial-worker',
    sourceRevision: 'sha256:${sha256.convert(goody).toString()}',
    sourceEvidence: SourceEvidence.sha256,
  );

  final parseReply = runWorkerOp(op: workerOpParse, bytes: goody);
  final resident = decodeBookWire(parseReply.json, parseReply.blobs);
  final inlineBook = parseDjvuBook(goody);

  test('spatial.djvuPage returns the structure the inline book holds', () {
    final reply = runWorkerOp(
      op: workerOpSpatialDjvuPage,
      payload: <String, Object?>{wireKeyPageIndex: 0},
      residentBook: resident,
    );
    expect(reply.kind, wireReplySpatialDjvuPage);
    final structure = decodeDjvuPageStructureWire(
      reply.json[wireKeyStructure] as Map<String, Object?>?,
      reply.blobs,
    );
    expect(structure, isNotNull);
    final inline = inlineBook.pageStructureAt(0)!;
    expect(structure!.canonicalText, inline.canonicalText);
    expect(structure.nativeRoot!.recordCount(), inline.nativeRoot!.recordCount());
    final wireWord = structure.spatialPage!.zones.lastWhere(
      (z) => z.kind == SpatialZoneKind.word,
    );
    final inlineWord = inline.spatialPage!.zones.lastWhere(
      (z) => z.kind == SpatialZoneKind.word,
    );
    expect(wireWord.textStart, inlineWord.textStart);
    expect(wireWord.textEnd, inlineWord.textEnd);
    expect(wireWord.rect, inlineWord.rect);
  });

  test('spatial.djvuPage reports pages without hidden text as null', () {
    final lastPage = inlineBook.pages.length - 1;
    var pageIndexWithoutChunk = -1;
    for (var i = 0; i < inlineBook.pages.length; i++) {
      if (inlineBook.pages[i].textChunk == null) {
        pageIndexWithoutChunk = i;
        break;
      }
    }
    if (pageIndexWithoutChunk < 0) {
      pageIndexWithoutChunk = lastPage;
    }
    final reply = runWorkerOp(
      op: workerOpSpatialDjvuPage,
      payload: <String, Object?>{wireKeyPageIndex: pageIndexWithoutChunk},
      residentBook: resident,
    );
    final structure = decodeDjvuPageStructureWire(
      reply.json[wireKeyStructure] as Map<String, Object?>?,
      reply.blobs,
    );
    expect(structure, inlineBook.pages[pageIndexWithoutChunk].textChunk == null ? isNull : isNotNull);
  });

  test('spatial.altoBind matches the inline binding', () {
    final reply = runWorkerOp(
      op: workerOpSpatialAltoBind,
      bytes: altoXml,
      payload: <String, Object?>{
        wireKeyPageIndex: 1,
        wireKeyIdentity: encodePublicationRevisionWire(identity),
      },
      residentBook: resident,
    );
    expect(reply.kind, wireReplySpatialAltoBind);
    final bound = decodeAltoBoundTextWire(reply.json[wireKeyBound] as Map<String, Object?>);

    final inline = bindAltoToSnapshot(
      document: parseAltoDocument(altoXml),
      target: inlineBook.pageStructureAt(1)!.snapshot(identity: identity),
    );
    expect(bound.wordsResolved, inline.wordsResolved);
    expect(bound.wordsAmbiguous, inline.wordsAmbiguous);
    expect(bound.wordsMissing, inline.wordsMissing);
    expect(bound.wordsResolved + bound.wordsAmbiguous + bound.wordsMissing, greaterThan(0));
    expect(bound.targetIdentity, identity);
    expect(bound.targetOccurrence.sectionIndex, 1);
    expect(bound.pages.single.provenance.softwareName, 'Tesseract');
  });

  test('spatial ops fail typed without a resident DjVu book', () {
    expect(
      () => runWorkerOp(
        op: workerOpSpatialDjvuPage,
        payload: <String, Object?>{wireKeyPageIndex: 0},
      ),
      throwsA(isA<UnsealException>()),
    );
    expect(
      () => runWorkerOp(
        op: workerOpSpatialAltoBind,
        bytes: altoXml,
        payload: <String, Object?>{
          wireKeyPageIndex: 0,
          wireKeyIdentity: encodePublicationRevisionWire(identity),
        },
      ),
      throwsA(isA<UnsealException>()),
    );

    final epubBytes = Uint8List.fromList(
      File('test/resources/epub/Alices Adventures in Wonderland.epub').readAsBytesSync(),
    );
    final epubReply = runWorkerOp(op: workerOpParse, bytes: epubBytes);
    final epubResident = decodeBookWire(epubReply.json, epubReply.blobs);
    expect(
      () => runWorkerOp(
        op: workerOpSpatialDjvuPage,
        payload: <String, Object?>{wireKeyPageIndex: 0},
        residentBook: epubResident,
      ),
      throwsA(isA<UnsealException>()),
    );
  });

  test('spatial.altoBind fails typed for malformed ALTO and missing chunks', () {
    expect(
      () => runWorkerOp(
        op: workerOpSpatialAltoBind,
        bytes: Uint8List.fromList(utf8.encode('not alto')),
        payload: <String, Object?>{
          wireKeyPageIndex: 1,
          wireKeyIdentity: encodePublicationRevisionWire(identity),
        },
        residentBook: resident,
      ),
      throwsA(isA<AltoException>()),
    );
    // A page without a hidden-text chunk cannot serve a binding.
    final withoutChunk = inlineBook.pages
        .toList()
        .indexWhere((page) => page.textChunk == null);
    if (withoutChunk >= 0) {
      expect(
        () => runWorkerOp(
          op: workerOpSpatialAltoBind,
          bytes: altoXml,
          payload: <String, Object?>{
            wireKeyPageIndex: withoutChunk,
            wireKeyIdentity: encodePublicationRevisionWire(identity),
          },
          residentBook: resident,
        ),
        throwsA(isA<UnsealException>()),
      );
    }
  });
}
