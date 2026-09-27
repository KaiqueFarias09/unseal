// Session worker ops: the stateful session handler must serve
// resources, document text, search, progression and CFI results
// identical to the resident engine, and keep failure types stable
// across the wire.
//
// runWorkerOp is pure and VM-safe, so the whole protocol is tested
// here without a browser; the shell in web/unseal_worker.dart only
// unwraps messages around it — including the rule that a `sessionOpen`
// reply replaces the resident session and a `sessionDispose` reply
// clears it.
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/src/platform/web/worker_ops.dart';
import 'package:unseal/unseal.dart';

Uint8List _bytes(final String name) =>
    Uint8List.fromList(File('test/resources/$name').readAsBytesSync());

/// The search payload exactly the way the client sends it.
Map<String, Object?> _searchPayload(
  final String query, {
  final SearchMode mode = SearchMode.contains,
  final bool isCaseSensitive = false,
  final bool isTolerant = true,
  final int nearChars = 60,
  final int contextChars = 48,
  final int maxMatches = 200,
}) => <String, Object?>{
  wireKeyQuery: query,
  wireKeyMode: mode.name,
  wireKeyCaseSensitive: isCaseSensitive,
  wireKeyTolerant: isTolerant,
  wireKeyNearChars: nearChars,
  wireKeyContextChars: contextChars,
  wireKeyMaxMatches: maxMatches,
};

/// The payload a blob-referencing reply carries: the referenced blob,
/// or null when the requested entry does not exist.
Object? _referencedBlob(
  final ({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
  reply,
) {
  final index = reply.json[wireKeyBlobIndex] as int?;

  return index == null ? null : reply.blobs[index];
}

/// Field-by-field equality between a wire result and the inline one.
void _expectSameResults(final SearchResults wire, final SearchResults inline) {
  expect(wire.query, inline.query);
  expect(wire.isTruncated, inline.isTruncated);
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
  const chemistry = 'books/epub/elements-of-chemistry.epub';
  final bytes = _bytes(chemistry);

  // The reference engine the wire replies must match, and the resident
  // session exactly the way the worker shell keeps it: the engine a
  // sessionOpen reply carried back.
  late final SessionEngine reference;
  late final EpubBook full;
  late final ({String kind, Map<String, Object?> json, List<Object> blobs, SessionEngine? session})
  openReply;
  late final SessionEngine resident;

  setUpAll(() {
    reference = SessionEngine.openBytes(bytes);
    addTearDown(reference.close);
    full = Unseal.parse(bytes) as EpubBook;

    openReply = runWorkerOp(op: workerOpSessionOpen, bytes: bytes);
    resident = openReply.session!;
    addTearDown(resident.close);
  });

  group('sessionOpen op', () {
    test('replies with the encoded header and the progressive flag', () {
      expect(openReply.kind, wireReplySessionOpen);
      expect(openReply.json[wireKeyProgressive], isTrue);

      final header = decodeSessionHeaderWire(openReply.json, openReply.blobs) as EpubBook;
      expect(header.files.html, isEmpty, reason: 'header must hold no content');
      expect(header.spinePaths, full.spinePaths);
      expect(header.metadata.title, full.metadata.title);
    });

    test('forwards the policy to the engine', () {
      final comicBytes = _bytes('books/comic/halfpenny-surprise-1895.cbz');
      final reply = runWorkerOp(
        op: workerOpSessionOpen,
        bytes: comicBytes,
        payload: <String, Object?>{wireKeyCacheBytes: 1 << 20, wireKeyCoverMaxBytes: 1024},
      );
      addTearDown(reply.session!.close);

      final header = decodeSessionHeaderWire(reply.json, reply.blobs) as ComicBook;
      expect(header.cover.isEmpty, isTrue, reason: 'an oversized cover stays out of the header');
    });

    test('replaces a prior session', () {
      final prior = runWorkerOp(op: workerOpSessionOpen, bytes: bytes);
      addTearDown(prior.session!.close);

      final replacement = runWorkerOp(
        op: workerOpSessionOpen,
        bytes: bytes,
        residentSession: prior.session,
      );
      addTearDown(replacement.session!.close);

      expect(replacement.kind, wireReplySessionOpen);
      expect(replacement.session, isNotNull);
      expect(replacement.session, isNot(same(prior.session)));
      expect(
        () => prior.session!.resource('META-INF/container.xml'),
        throwsA(isA<SessionClosedException>()),
      );
    });

    test('rejects unsupported formats typed', () {
      expect(
        () => runWorkerOp(op: workerOpSessionOpen, bytes: _bytes('books/txt/synthetic.txt')),
        throwsA(isA<SessionUnsupportedFormatException>()),
      );
    });

    test('rejects broken containers with the parse failure hierarchy', () {
      expect(
        () => runWorkerOp(
          op: workerOpSessionOpen,
          bytes: Uint8List.fromList(<int>[0x50, 0x4b, 0x03, 0x04, 9, 9, 9, 9]),
        ),
        throwsA(isA<UnsealException>()),
      );
    });
  });

  group('session content ops', () {
    test('sessionResource inflates one entry or yields a null reference', () {
      final path = full.files.html.first.path;
      final reply = runWorkerOp(
        op: workerOpSessionResource,
        payload: <String, Object?>{wireKeyPath: path},
        residentSession: resident,
      );
      expect(reply.kind, wireReplySessionResource);
      expect(_referencedBlob(reply), reference.resource(path));

      final missing = runWorkerOp(
        op: workerOpSessionResource,
        payload: const <String, Object?>{wireKeyPath: 'no/such/entry.xhtml'},
        residentSession: resident,
      );
      expect(missing.kind, wireReplySessionResource);
      expect(missing.json[wireKeyBlobIndex], isNull);
      expect(missing.blobs, isEmpty);
    });

    test('sessionResources batches entries and omits missing paths', () {
      final paths = <String>{
        for (final file in full.files.html.take(3)) file.path,
        'no/such/entry.xhtml',
      };
      final reply = runWorkerOp(
        op: workerOpSessionResources,
        payload: <String, Object?>{wireKeyPaths: paths.toList()},
        residentSession: resident,
      );
      expect(reply.kind, wireReplySessionResources);

      final found = (reply.json[wireKeyPaths] as List<Object?>).cast<String>();
      expect(found.length, paths.length - 1);
      for (var i = 0; i < found.length; i++) {
        expect(reply.blobs[i], reference.resource(found[i]), reason: found[i]);
      }
    });

    test('sessionText and sessionSource carry the canonical text and the raw source', () {
      final file = full.files.html.first;

      final textReply = runWorkerOp(
        op: workerOpSessionText,
        payload: <String, Object?>{wireKeyPath: file.path},
        residentSession: resident,
      );
      expect(textReply.kind, wireReplySessionText);
      expect(_referencedBlob(textReply), documentTextOf(file));

      final sourceReply = runWorkerOp(
        op: workerOpSessionSource,
        payload: <String, Object?>{wireKeyPath: file.path},
        residentSession: resident,
      );
      expect(sourceReply.kind, wireReplySessionSource);
      expect(_referencedBlob(sourceReply), file.content);
    });

    test('sessionSearch matches the resident engine search', () {
      final reply = runWorkerOp(
        op: workerOpSessionSearch,
        payload: _searchPayload('chemistry'),
        residentSession: resident,
      );
      expect(reply.kind, wireReplySessionSearch);
      expect(reply.blobs, isEmpty);

      _expectSameResults(decodeSearchResultsWire(reply.json), reference.search('chemistry'));
    });

    test('sessionProgression and sessionStatistics measure the whole book', () {
      final progressionReply = runWorkerOp(
        op: workerOpSessionProgression,
        residentSession: resident,
      );
      expect(progressionReply.kind, wireReplySessionProgression);

      final inline = reference.computeProgression();
      final lengths = (progressionReply.json[wireKeySectionLengths] as List<Object?>).cast<int>();
      final progression = BookProgression.fromSectionLengths(lengths);
      expect(progression.sectionCount, inline.sectionCount);
      expect(progression.sectionLengths, inline.sectionLengths);
      expect(progression.totalCharacters, inline.totalCharacters);
      expect(progressionReply.json[wireKeyTotalCharacters], inline.totalCharacters);

      final statisticsReply = runWorkerOp(op: workerOpSessionStatistics, residentSession: resident);
      expect(statisticsReply.kind, wireReplySessionStatistics);
      final inlineStatistics = reference.computeStatistics();
      expect(statisticsReply.json[wireKeyWordCount], inlineStatistics.wordCount);
      expect(statisticsReply.json[wireKeyCharacterCount], inlineStatistics.characterCount);
    });
  });

  group('session cfi ops', () {
    test('sessionCfiBuild then sessionCfiResolve round-trips the offset', () {
      final file = full.files.html.first;
      final section = full.spinePaths!.indexOf(file.path);
      final offset = documentTextOf(file).length ~/ 2;

      final buildReply = runWorkerOp(
        op: workerOpSessionCfiBuild,
        payload: <String, Object?>{wireKeyContentIndex: section, wireKeyOffsetInText: offset},
        residentSession: resident,
      );
      expect(buildReply.kind, wireReplySessionCfi);
      final cfi = buildReply.json[wireKeyCfi] as String;
      expect(cfi, startsWith('epubcfi('));

      final resolveReply = runWorkerOp(
        op: workerOpSessionCfiResolve,
        payload: <String, Object?>{wireKeyCfi: cfi},
        residentSession: resident,
      );
      expect(resolveReply.kind, wireReplySessionCfiLocation);
      final location = decodeCfiLocationWire(
        resolveReply.json[wireKeyLocation] as Map<String, Object?>,
      );
      expect(location, isNotNull);
      expect(location!.contentIndex, section);
      expect(location.charOffset, offset);
    });

    test('sessionCfiResolve yields JSON null for a malformed CFI', () {
      final reply = runWorkerOp(
        op: workerOpSessionCfiResolve,
        payload: const <String, Object?>{wireKeyCfi: 'not-a-cfi'},
        residentSession: resident,
      );
      expect(reply.kind, wireReplySessionCfiLocation);
      expect(reply.json[wireKeyLocation], isNull);
    });

    test('sessionCfiBuild outside the reading order crosses as a RangeError', () {
      expect(
        () => runWorkerOp(
          op: workerOpSessionCfiBuild,
          payload: const <String, Object?>{wireKeyContentIndex: 9999, wireKeyOffsetInText: 0},
          residentSession: resident,
        ),
        throwsA(isA<RangeError>()),
      );
    });
  });

  group('session lifecycle', () {
    test('sessionDispose closes the engine; later ops fail typed', () {
      final disposable = runWorkerOp(op: workerOpSessionOpen, bytes: bytes);
      final engine = disposable.session!;

      final disposeReply = runWorkerOp(op: workerOpSessionDispose, residentSession: engine);
      expect(disposeReply.kind, wireReplySessionDispose);

      // The engine is closed, so the typed error is what the error
      // reply carries across the wire.
      expect(
        () => runWorkerOp(
          op: workerOpSessionResource,
          payload: const <String, Object?>{wireKeyPath: 'x'},
          residentSession: engine,
        ),
        throwsA(isA<SessionClosedException>()),
      );
      expect(
        () => runWorkerOp(op: workerOpSessionProgression, residentSession: engine),
        throwsA(isA<SessionClosedException>()),
      );
    });

    test('session ops without a resident session fail typed', () {
      expect(
        () => runWorkerOp(
          op: workerOpSessionResource,
          payload: const <String, Object?>{wireKeyPath: 'x'},
        ),
        throwsA(isA<SessionClosedException>()),
      );
      expect(
        () => runWorkerOp(op: workerOpSessionSearch, payload: _searchPayload('x')),
        throwsA(isA<SessionClosedException>()),
      );
      expect(
        () => runWorkerOp(op: workerOpSessionProgression),
        throwsA(isA<SessionClosedException>()),
      );
    });

    test('disposing without a session stays a no-op', () {
      final reply = runWorkerOp(op: workerOpSessionDispose);

      expect(reply.kind, wireReplySessionDispose);
    });
  });

  group('session error wire', () {
    test('keeps the session exception types', () {
      expect(decodeErrorWire('SessionClosedException', ''), isA<SessionClosedException>());
      expect(decodeErrorWire('SessionCancelledException', ''), isA<SessionCancelledException>());

      final unsupported = decodeErrorWire('SessionUnsupportedFormatException', 'no support');
      expect(unsupported, isA<SessionUnsupportedFormatException>());
      expect(
        (unsupported as SessionUnsupportedFormatException).message,
        'no progressive support'.replaceAll(' progressive', ''),
      );
    });
  });

  group('comic session ops', () {
    test('sessionOpen replies with a comic header whose pages load on demand', () {
      final comicBytes = _bytes('books/comic/halfpenny-surprise-1895.cbz');
      final reply = runWorkerOp(op: workerOpSessionOpen, bytes: comicBytes);
      addTearDown(reply.session!.close);
      expect(reply.kind, wireReplySessionOpen);
      expect(reply.json[wireKeyProgressive], isTrue);

      final header = decodeSessionHeaderWire(reply.json, reply.blobs) as ComicBook;
      expect(header.pageCount, greaterThan(0));
      for (final page in header.pages) {
        expect(page.content, isEmpty, reason: page.path);
      }

      final pageReply = runWorkerOp(
        op: workerOpSessionResource,
        payload: <String, Object?>{wireKeyPath: header.pages.first.path},
        residentSession: reply.session,
      );
      expect(_referencedBlob(pageReply), isNotEmpty);
    });
  });
}
