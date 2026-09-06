// Worker ops: the stateful op handler must serve search and CFI
// results identical to the inline feature code, and keep failure
// types stable across the wire.
//
// runWorkerOp is pure and VM-safe, so the whole protocol is tested
// here without a browser; the shell in web/e_livre_worker.dart only
// unwraps messages around it.
import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/platform/web/book_wire.dart';
import 'package:e_livre/src/platform/web/worker_ops.dart';
import 'package:test/test.dart';

Uint8List _bytes(final String name) =>
    Uint8List.fromList(File('test/resources/$name').readAsBytesSync());

/// The search payload exactly the way the client sends it.
Map<String, Object?> _searchPayload(
  final String query, {
  final SearchMode mode = SearchMode.contains,
  final bool caseSensitive = false,
  final bool tolerant = true,
  final int nearChars = 60,
  final int contextChars = 48,
  final int maxMatches = 200,
}) => <String, Object?>{
  wireKeyQuery: query,
  wireKeyMode: mode.name,
  wireKeyCaseSensitive: caseSensitive,
  wireKeyTolerant: tolerant,
  wireKeyNearChars: nearChars,
  wireKeyContextChars: contextChars,
  wireKeyMaxMatches: maxMatches,
};

/// Field-by-field equality between a wire result and the inline one.
void _expectSameResults(final SearchResults wire, final SearchResults inline) {
  expect(wire.query, inline.query);
  expect(wire.truncated, inline.truncated);
  expect(wire.matches.length, inline.matches.length);
  for (var i = 0; i < inline.matches.length; i++) {
    expect(wire.matches[i].sectionIndex, inline.matches[i].sectionIndex, reason: 'match $i');
    expect(wire.matches[i].sectionName, inline.matches[i].sectionName, reason: 'match $i');
    expect(wire.matches[i].start, inline.matches[i].start, reason: 'match $i');
    expect(wire.matches[i].end, inline.matches[i].end, reason: 'match $i');
    expect(wire.matches[i].snippet, inline.matches[i].snippet, reason: 'match $i');
  }
}

void main() {
  final bytes = _bytes('epub/sample1.epub');
  final inline = BookReader.parseBook(bytes) as EpubBook;

  // The resident book exactly the way the worker shell keeps it:
  // decoded back from the parse reply it just produced.
  final parseReply = runWorkerOp(op: workerOpParse, bytes: bytes);
  final resident = decodeBookWire(parseReply.json, parseReply.blobs);

  group('search op', () {
    test('runs after a parse op and matches the inline search', () {
      expect(parseReply.kind, wireReplyBook);

      final reply = runWorkerOp(
        op: workerOpSearch,
        payload: _searchPayload('Bliss'),
        residentBook: resident,
      );
      expect(reply.kind, wireReplySearch);
      expect(reply.blobs, isEmpty);

      _expectSameResults(decodeSearchResultsWire(reply.json), inline.search('Bliss'));
    });

    test('forwards the non-default options', () {
      final capped = runWorkerOp(
        op: workerOpSearch,
        payload: _searchPayload('the', maxMatches: 5),
        residentBook: resident,
      );
      expect(decodeSearchResultsWire(capped.json).truncated, isTrue);
      _expectSameResults(decodeSearchResultsWire(capped.json), inline.search('the', maxMatches: 5));

      final caseFolded = runWorkerOp(
        op: workerOpSearch,
        payload: _searchPayload('BLISS', caseSensitive: true),
        residentBook: resident,
      );
      expect(decodeSearchResultsWire(caseFolded.json).matches, isEmpty);
      _expectSameResults(
        decodeSearchResultsWire(caseFolded.json),
        inline.search('BLISS', caseSensitive: true),
      );
    });

    test('rejects the request without a resident book', () {
      expect(
        () => runWorkerOp(op: workerOpSearch, payload: _searchPayload('Bliss')),
        throwsA(isA<ELivreException>()),
      );
    });

    test('surfaces an invalid regex pattern as FormatException', () {
      expect(
        () => runWorkerOp(
          op: workerOpSearch,
          payload: _searchPayload('(', mode: SearchMode.regex),
          residentBook: resident,
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('cfi ops', () {
    test('cfiBuild then cfiResolve round-trips the offset', () {
      const section = 5;
      const offset = 6140;

      final buildReply = runWorkerOp(
        op: workerOpCfiBuild,
        payload: <String, Object?>{wireKeyContentIndex: section, wireKeyOffsetInText: offset},
        residentBook: resident,
      );
      expect(buildReply.kind, wireReplyCfi);
      final cfi = buildReply.json[wireKeyCfi] as String;
      expect(cfi, startsWith('epubcfi('));

      final resolveReply = runWorkerOp(
        op: workerOpCfiResolve,
        payload: <String, Object?>{wireKeyCfi: cfi},
        residentBook: resident,
      );
      expect(resolveReply.kind, wireReplyCfiLocation);
      final location = decodeCfiLocationWire(
        resolveReply.json[wireKeyLocation] as Map<String, Object?>,
      );

      expect(location, isNotNull);
      expect(location!.contentIndex, section);
      expect(location.charOffset, offset);
    });

    test('yields JSON null for a CFI outside the book', () {
      final reply = runWorkerOp(
        op: workerOpCfiResolve,
        payload: const <String, Object?>{wireKeyCfi: 'epubcfi(/6/40!/4/1:0)'},
        residentBook: resident,
      );

      expect(reply.kind, wireReplyCfiLocation);
      expect(reply.json[wireKeyLocation], isNull);
    });

    test('yields JSON null for a malformed CFI', () {
      final reply = runWorkerOp(
        op: workerOpCfiResolve,
        payload: const <String, Object?>{wireKeyCfi: 'not-a-cfi'},
        residentBook: resident,
      );

      expect(reply.json[wireKeyLocation], isNull);
    });
  });

  group('op dispatch', () {
    test('unknown op throws', () {
      expect(() => runWorkerOp(op: 'nope'), throwsA(isA<ELivreException>()));
    });

    test('metadata op keeps its reply kind', () {
      final reply = runWorkerOp(op: workerOpMetadata, bytes: bytes);

      expect(reply.kind, wireReplyMetadata);
      expect(decodeMetadataWire(reply.json, reply.blobs).title, inline.metadata.title);
    });
  });

  group('search results codec', () {
    test('round-trips every match field', () {
      final results = inline.search('happiness');
      final decoded = decodeSearchResultsWire(encodeSearchResultsWire(results));

      _expectSameResults(decoded, results);
    });

    test('survives the JSON channel', () {
      final results = inline.search('travel', maxMatches: 2);
      final channel = decodeJson(encodeJson(encodeSearchResultsWire(results)));

      _expectSameResults(decodeSearchResultsWire(channel), results);
    });
  });

  group('cfi location codec', () {
    test('round-trips every field', () {
      final location = inline.resolveCfi(
        EpubCfi.parse(inline.buildEpubCfi(contentIndex: 5, offsetInText: 6140)),
      );
      final decoded = decodeCfiLocationWire(encodeCfiLocationWire(location));

      expect(decoded, isNotNull);
      expect(decoded!.contentIndex, location!.contentIndex);
      expect(decoded.contentPath, location.contentPath);
      expect(decoded.charOffset, location.charOffset);
      expect(decoded.textExcerpt, location.textExcerpt);
      expect(decoded.elementTrail, location.elementTrail);
    });

    test('carries JSON null for a miss', () {
      expect(encodeCfiLocationWire(null), isNull);
      expect(decodeCfiLocationWire(null), isNull);
      expect(
        decodeCfiLocationWire(
          decodeJson(encodeJson(<String, Object?>{wireKeyLocation: null}))[wireKeyLocation]
              as Map<String, Object?>?,
        ),
        isNull,
      );
    });
  });

  group('error wire', () {
    test('keeps the FormatException type', () {
      final error = decodeErrorWire('FormatException', 'bad pattern');

      expect(error, isA<FormatException>());
      expect((error as FormatException).message, 'bad pattern');
    });
  });
}
