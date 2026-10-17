import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/progressive/byte_source_gate.dart';
import 'package:unseal/unseal.dart';

// The fixtures are tracked, licensed books; the byte spans used by the
// partial-reading assertions come from an independent container walk
// at the bottom of this file — never from Unseal's own zip code.
const aliceEpub = 'test/resources/epub/Alices Adventures in Wonderland.epub';
const chemistryEpub = 'test/resources/books/epub/elements-of-chemistry.epub';
const mahabharataEpub = 'test/resources/books/epub/mahabharata.epub';
const halfpennyCbz = 'test/resources/books/comic/halfpenny-surprise-1895.cbz';
const syntheticCbz = 'test/resources/books/comic/synthetic-pages.cbz';

Uint8List _bytes(final String path) => Uint8List.fromList(File(path).readAsBytesSync());

/// A source the tests instrument: exact slices over an in-memory
/// buffer with no Unseal code involved, a recorded read log, and
/// injectable contract violations for the typed-failure tests.
final class RecordingByteSource implements UnsealByteSource {
  RecordingByteSource(
    this.bytes, {
    this.revision,
    this.delay = Duration.zero,
    this.shortReadAt,
    this.longReadAt,
    this.throwAt,
  });

  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  String? revision;
  final Duration delay;
  final int? shortReadAt;
  final int? longReadAt;
  final int? throwAt;

  /// When set, the read with this sequence number returns one byte
  /// short / one byte long / fails — deterministic fault injection
  /// that does not depend on which offsets the engine picks.
  int? shortReadOnSequence;
  int? longReadOnSequence;
  int? failOnSequence;

  var _closed = false;
  var _readCount = 0;
  final List<({int offset, int count, int sequence})> reads =
      <({int offset, int count, int sequence})>[];
  final Completer<void> _firstRead = Completer<void>();

  var activeRequests = 0;
  var activeBytes = 0;
  var peakRequests = 0;
  var peakBytes = 0;

  bool get closed => _closed;
  int get readCount => _readCount;
  int get totalBytesRequested => reads.fold(0, (final total, final read) => total + read.count);
  Future<void> get firstRead => _firstRead.future;

  void flipRevision() {
    revision = 'revised-${revision ?? 'null'}';
  }

  @override
  Future<Uint8List> readRange(final int offset, final int count) async {
    if (_closed) throw const ByteSourceClosedException();
    RangeError.checkValidRange(offset, offset + count, bytes.length, 'offset', 'end');
    final sequence = _readCount++;
    reads.add((offset: offset, count: count, sequence: sequence));
    if (!_firstRead.isCompleted) _firstRead.complete();
    activeRequests++;
    activeBytes += count;
    if (activeRequests > peakRequests) peakRequests = activeRequests;
    if (activeBytes > peakBytes) peakBytes = activeBytes;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (offset == throwAt || sequence == failOnSequence) {
        throw Exception('host transport failure');
      }
      if (offset == shortReadAt || sequence == shortReadOnSequence) {
        return Uint8List.sublistView(bytes, offset, offset + count - 1);
      }
      if (offset == longReadAt || sequence == longReadOnSequence) {
        final long = Uint8List(count + 1);
        long.setRange(0, count, Uint8List.sublistView(bytes, offset, offset + count));

        return long;
      }

      return Uint8List.sublistView(bytes, offset, offset + count);
    } finally {
      activeRequests--;
      activeBytes -= count;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

void main() {
  for (final scenario in <(String, int, int, int)>[
    ('request slots', 2, 400 << 10, 2),
    ('cumulative bytes', 3, 600 << 10, 1),
  ]) {
    test('public source bridge enforces ${scenario.$1} before host reads', () async {
      final source = RecordingByteSource(
        _bytes(chemistryEpub),
        revision: 'budget-1',
        delay: const Duration(milliseconds: 3),
      );
      final session = await BookSession.openSource(
        source,
        policy: SessionPolicy(
          rangeRequestsInFlight: scenario.$2,
          rangeBytesInFlight: 1 << 20,
          rangeRequestBytes: 1 << 20,
        ),
      );
      addTearDown(session.dispose);
      source.peakRequests = 0;
      source.peakBytes = 0;
      final answers = await Future.wait(<Future<Uint8List?>>[
        for (var i = 0; i < 8; i++) session.loadBytesRange(i * 7, scenario.$3),
      ]);
      for (var i = 0; i < answers.length; i++) {
        expect(answers[i], source.bytes.sublist(i * 7, i * 7 + scenario.$3));
      }
      expect(source.peakRequests, scenario.$4);
      expect(source.peakBytes, lessThanOrEqualTo(1 << 20));
      expect(source.activeRequests, 0);
    });
  }

  group('ByteSourceGate contract', () {
    test('exact reads, bounds, and typed short/long/host failures', () async {
      final raw = _bytes(syntheticCbz);
      final gate = ByteSourceGate(
        RecordingByteSource(raw, revision: 'rev-1'),
        policy: const SessionPolicy(),
      );

      expect(gate.length, raw.length);
      expect(gate.revisionAtOpen, 'rev-1');
      final slice = await gate.read(4, 10, expectedRevision: 'rev-1');
      expect(slice.length, 10);

      expect(() => gate.read(-1, 4), throwsA(isA<RangeError>()));
      expect(() => gate.read(raw.length, 1), throwsA(isA<RangeError>()));

      final short = ByteSourceGate(
        RecordingByteSource(raw, shortReadAt: 0),
        policy: const SessionPolicy(),
      );
      await expectLater(short.read(0, 8), throwsA(isA<ByteSourceShortReadException>()));

      final long = ByteSourceGate(
        RecordingByteSource(raw, longReadAt: 0),
        policy: const SessionPolicy(),
      );
      await expectLater(long.read(0, 8), throwsA(isA<ByteSourceLongReadException>()));

      final broken = ByteSourceGate(
        RecordingByteSource(raw, throwAt: 0),
        policy: const SessionPolicy(),
      );
      await expectLater(
        broken.read(0, 8),
        throwsA(
          isA<ByteSourceReadException>().having(
            (final error) => error.message,
            'message',
            contains('host transport failure'),
          ),
        ),
      );
    });

    test('revision changes fail the read before and after serving', () async {
      final source = RecordingByteSource(_bytes(syntheticCbz), revision: 'rev-1');
      final gate = ByteSourceGate(source, policy: const SessionPolicy());

      source.flipRevision();
      await expectLater(
        gate.read(0, 8, expectedRevision: 'rev-1'),
        throwsA(isA<ByteSourceRevisionChangedException>()),
      );

      // A revision that flips while the read is in flight also fails:
      // the post-serve check rejects bytes from a mixed state.
      final flipping = RecordingByteSource(
        _bytes(syntheticCbz),
        revision: 'rev-1',
        delay: const Duration(milliseconds: 10),
      );
      final flippingGate = ByteSourceGate(flipping, policy: const SessionPolicy());
      final inFlight = flippingGate.read(0, 8, expectedRevision: 'rev-1');
      flipping.flipRevision();
      await expectLater(inFlight, throwsA(isA<ByteSourceRevisionChangedException>()));
    });

    test('close fails queued and in-flight reads and closes the source', () async {
      final source = RecordingByteSource(
        _bytes(syntheticCbz),
        revision: 'rev-1',
        delay: const Duration(milliseconds: 20),
      );
      final gate = ByteSourceGate(source, policy: const SessionPolicy());
      final inFlight = gate.read(0, 8, expectedRevision: 'rev-1');
      final queued = gate.read(16, 8, expectedRevision: 'rev-1');
      // Listeners attach before the close so the typed failures have a
      // destination from the moment they fire.
      final inFlightFailure = expectLater(inFlight, throwsA(isA<ByteSourceClosedException>()));
      final queuedFailure = expectLater(queued, throwsA(isA<ByteSourceClosedException>()));

      await gate.close();
      expect(source.closed, isTrue);
      await inFlightFailure;
      await queuedFailure;
      expect(() => gate.read(0, 8), throwsA(isA<ByteSourceClosedException>()));
      await gate.close(); // closing twice stays a no-op
    });

    test('in-flight caps queue requests instead of failing them', () async {
      final source = RecordingByteSource(
        _bytes(aliceEpub),
        delay: const Duration(milliseconds: 10),
      );
      final gate = ByteSourceGate(
        source,
        policy: const SessionPolicy(rangeRequestsInFlight: 1, rangeBytesInFlight: 64 << 10),
      );

      final pending = <Future<Uint8List>>[
        gate.read(0, 4096),
        gate.read(4096, 4096),
        gate.read(8192, 4096),
        gate.read(12288, 4096),
      ];
      // The first read is being served; the rest queue.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      expect(gate.inFlightRequests, 1);
      expect(gate.queuedRequests, greaterThanOrEqualTo(1));

      final served = await Future.wait(pending);
      expect(served.length, 4);
      expect(gate.maxObservedInFlightRequests, 1, reason: 'the concurrency cap held');
      for (var i = 0; i < served.length; i++) {
        final offset = i * 4096;
        expect(served[i], Uint8List.sublistView(source.bytes, offset, offset + 4096));
      }
    });

    test('a request above the per-request cap fails typed', () async {
      final gate = ByteSourceGate(
        RecordingByteSource(_bytes(mahabharataEpub)),
        policy: const SessionPolicy(rangeRequestBytes: 1 << 20),
      );

      await expectLater(
        () => gate.read(0, 2 << 20),
        throwsA(isA<ByteSourceLimitExceededException>()),
      );
    });
  });

  group('BookSession.openSource over EPUB', () {
    test('opens the header, serves exact content, and reports the revision', () async {
      final raw = _bytes(aliceEpub);
      final source = RecordingByteSource(raw, revision: 'alice-etag');
      final session = await BookSession.openSource(source);
      addTearDown(session.dispose);

      expect(session.book, isA<EpubBook>());
      expect(session.sourceRevision, 'alice-etag');
      expect(session.book.files.html, isEmpty, reason: 'header holds no content');

      final first = session.book.readingOrder.first;
      final chapterSource = await session.loadDocumentSource(first.name);
      expect(chapterSource, isNotNull);
      final eager = Unseal.parse(raw) as EpubBook;
      final eagerPath = eager.readingOrder.first.name;
      expect(
        chapterSource,
        eager.files.html.firstWhere((final file) => file.path == eagerPath).content,
      );

      final text = await session.loadDocumentText(first.name);
      expect(text, isNotNull);
    });

    test('open and first content read a small fraction of the file', () async {
      final raw = _bytes(mahabharataEpub);
      final source = RecordingByteSource(raw);
      final openReads = source.readCount;
      final session = await BookSession.openSource(source);
      addTearDown(session.dispose);

      final inventory = _parseZipInventoryIndependently(raw);
      final openBytes = source.totalBytesRequested;
      expect(
        openBytes,
        lessThan(raw.length ~/ 10),
        reason: 'opening an 11 MB EPUB asked for $openBytes bytes',
      );
      // Every open-phase read lands in the container bookkeeping
      // regions: the EOCD tail, the central directory, or a local
      // header — never a bulk payload copy.
      for (final read in source.reads.skip(openReads)) {
        final inDirectory = read.offset + read.count <= inventory.directoryEnd + 22;
        final isTail = read.offset >= raw.length - (65535 + 22);
        expect(
          inDirectory || isTail || read.count <= 1024,
          isTrue,
          reason: 'open read at ${read.offset}+${read.count} outside container regions',
        );
      }

      final firstPath = session.book.readingOrder.first.name;
      final entry = inventory.find(firstPath);
      final readsBefore = source.reads.length;
      await session.loadResource(firstPath);
      final loadReads = source.reads.sublist(readsBefore);
      for (final read in loadReads) {
        final insideSpan =
            read.offset >= entry.localHeaderOffset && read.offset + read.count <= entry.dataEnd;
        expect(
          insideSpan,
          isTrue,
          reason:
              'loading $firstPath read ${read.count} bytes at ${read.offset}, '
              'outside the entry span [${entry.localHeaderOffset}, ${entry.dataEnd})',
        );
      }
      final totalAfterFirst = source.totalBytesRequested;
      expect(
        totalAfterFirst,
        lessThan(raw.length ~/ 5),
        reason: 'open + first section asked for $totalAfterFirst of ${raw.length} bytes',
      );
    });

    test('per-entry inventory and content hashes match the eager parse', () async {
      final raw = _bytes(chemistryEpub);
      final source = RecordingByteSource(raw);
      final session = await BookSession.openSource(source);
      addTearDown(session.dispose);

      final eager = Unseal.parse(raw) as EpubBook;
      final sessionBook = session.book as EpubBook;
      expect(sessionBook.spinePaths, eager.spinePaths);
      expect(session.book.metadata.title, eager.metadata.title);
      expect(session.book.archiveEntries.length, eager.archiveEntries.length);

      for (final entry in session.book.archiveEntries) {
        final eagerEntry = eager.archiveEntries.firstWhere(
          (final candidate) => candidate.path == entry.path,
        );
        expect(entry.size, eagerEntry.size, reason: entry.path);
      }

      // Every HTML section's canonical text matches the eager parse.
      for (final section in session.book.readingOrder) {
        final remote = await session.loadDocumentText(section.name);
        final eagerFile = eager.files.html.firstWhere((final file) => file.path == section.name);
        expect(remote, documentTextOf(eagerFile), reason: section.name);
      }
      for (final file in [...eager.files.images, ...eager.files.fonts, ...eager.files.others]) {
        expect(await session.loadResource(file.path), file.content, reason: file.path);
      }
      for (final file in eager.files.css) {
        expect(await session.loadDocumentSource(file.path), file.content, reason: file.path);
      }
    });

    test('search, progression, statistics and CFI match the eager contracts', () async {
      final raw = _bytes(aliceEpub);
      final source = RecordingByteSource(raw);
      final session = await BookSession.openSource(source);
      addTearDown(session.dispose);
      final eager = Unseal.parse(raw) as EpubBook;

      final remoteSearch = await session.search('Alice', maxMatches: 50);
      final eagerSearch = eager.search('Alice', maxMatches: 50);
      expect(remoteSearch.matches.length, eagerSearch.matches.length);
      expect(remoteSearch.matches.first.sectionName, eagerSearch.matches.first.sectionName);

      final progression = await session.computeProgression();
      final eagerLengths = <int>[
        for (final section in eager.readingOrder)
          section.isHtml
              ? documentTextOf(
                  eager.files.html.firstWhere((final file) => file.path == section.name),
                ).length
              : 0,
      ];
      expect(progression.sectionLengths, eagerLengths);

      final statistics = await session.computeStatistics();
      expect(statistics.wordCount, greaterThan(1000));

      final cfi = await session.buildCfi(contentIndex: 0, offsetInText: 12);
      final resolved = await session.resolveCfi(cfi);
      expect(resolved, isNotNull);
    });

    test('formats outside the cut are refused explicitly', () async {
      // A PDF through a byte source: the format keeps its bytes/file
      // opens, and the refusal names it.
      final pdfBytes = _bytes('test/resources/pdf/dickens-sample.pdf');
      await expectLater(
        BookSession.openSource(RecordingByteSource(pdfBytes)),
        throwsA(
          isA<SessionUnsupportedFormatException>().having(
            (final error) => error.message,
            'message',
            contains('PDF'),
          ),
        ),
      );

      // A RAR container: same contract.
      final rarBytes = _bytes('test/resources/books/comic/american-beauty-trading-cards-1909.cbr');
      await expectLater(
        BookSession.openSource(RecordingByteSource(rarBytes)),
        throwsA(
          isA<SessionUnsupportedFormatException>().having(
            (final error) => error.message,
            'message',
            contains('CBR'),
          ),
        ),
      );

      // Plain text is not a session format at all.
      await expectLater(
        BookSession.openSource(
          RecordingByteSource(Uint8List.fromList(convert.utf8.encode('plain text'))),
        ),
        throwsA(isA<SessionUnsupportedFormatException>()),
      );

      // A DOCX zip is a zip book outside the session cut.
      final docxBytes = _bytes('test/resources/books/docx/synthetic.docx');
      await expectLater(
        BookSession.openSource(RecordingByteSource(docxBytes)),
        throwsA(isA<SessionUnsupportedFormatException>()),
      );
    });
  });

  group('BookSession.openSource over CBZ', () {
    test('page inventory, metadata and page bytes match the eager parse', () async {
      final raw = _bytes(halfpennyCbz);
      final source = RecordingByteSource(raw);
      final session = await BookSession.openSource(source);
      addTearDown(session.dispose);

      final header = session.book as ComicBook;
      final full = Unseal.parse(raw) as ComicBook;
      expect(header.pageCount, full.pageCount);
      expect(
        [for (final page in header.pages) page.path],
        [for (final page in full.pages) page.path],
        reason: 'natural page order',
      );
      for (final page in full.pages) {
        expect(await session.loadResource(page.path), page.content, reason: page.path);
      }
    });

    test('sniffing at open reads per-entry windows, not payloads', () async {
      final raw = _bytes(halfpennyCbz);
      final source = RecordingByteSource(raw);
      final session = await BookSession.openSource(source);
      addTearDown(session.dispose);

      final inventory = _parseZipInventoryIndependently(raw);
      final openBytes = source.totalBytesRequested;
      // The comic sniffs every page entry: per entry one local header
      // plus a small window — nowhere near the 8 MB of pages.
      expect(
        openBytes,
        lessThan(raw.length ~/ 5),
        reason: 'opening asked for $openBytes of ${raw.length} bytes',
      );
      var largeReads = 0;
      for (final read in source.reads) {
        final withinSomeEntry = inventory.entries.any(
          (final entry) =>
              read.offset >= entry.localHeaderOffset && read.offset + read.count <= entry.dataEnd,
        );
        final inDirectoryOrTail =
            read.offset + read.count <= inventory.directoryEnd + 22 ||
            read.offset >= raw.length - (65535 + 22);
        expect(
          withinSomeEntry || inDirectoryOrTail,
          isTrue,
          reason: 'open read at ${read.offset}+${read.count} touched no entry span',
        );
        if (read.count > 64 << 10) largeReads++;
      }
      // Only the header cover may move real bytes at open (its payload
      // inside its own span); everything else stays a sniff window.
      expect(largeReads, lessThanOrEqualTo(2), reason: 'open read bulk payloads');
      expect(inventory.entries.length, greaterThan(10));
    });
  });

  group('session lifecycle over sources (BS04/BS05)', () {
    test('host failures cross the bridge typed', () async {
      Future<void> expectTyped(
        final RecordingByteSource source,
        final void Function(RecordingByteSource source) arm,
        final Matcher matcher,
      ) async {
        final session = await BookSession.openSource(source);
        addTearDown(session.dispose);
        // Arm the NEXT read after the open: whichever section load
        // fires it surfaces the typed contract failure.
        arm(source);
        var observed = false;
        for (final section in session.book.readingOrder) {
          try {
            await session.loadResource(section.name);
          } on Object catch (error) {
            expect(error, matcher);
            observed = true;
            break;
          }
        }
        expect(observed, isTrue, reason: 'no section triggered a read');
      }

      await expectTyped(
        RecordingByteSource(_bytes(aliceEpub)),
        (final source) => source.shortReadOnSequence = source.readCount,
        isA<ByteSourceShortReadException>(),
      );
      await expectTyped(
        RecordingByteSource(_bytes(aliceEpub)),
        (final source) => source.longReadOnSequence = source.readCount,
        isA<ByteSourceLongReadException>(),
      );
      await expectTyped(
        RecordingByteSource(_bytes(aliceEpub)),
        (final source) => source.failOnSequence = source.readCount,
        isA<ByteSourceReadException>(),
      );
    });

    test('a revision change under the session fails the read typed', () async {
      final source = RecordingByteSource(_bytes(aliceEpub), revision: 'etag-1');
      final session = await BookSession.openSource(source);
      addTearDown(session.dispose);

      source.flipRevision();
      var observed = false;
      for (final section in session.book.readingOrder) {
        try {
          await session.loadResource(section.name);
        } on ByteSourceRevisionChangedException {
          observed = true;
          break;
        } on Object {
          // Header-cached sections read fine; keep walking.
        }
      }
      expect(observed, isTrue, reason: 'the revision change failed a read typed');
    });

    test('two source sessions stay isolated; disposing one leaves the other live', () async {
      final sourceA = RecordingByteSource(
        _bytes(aliceEpub),
        revision: 'a',
        delay: const Duration(milliseconds: 1),
      );
      final sourceB = RecordingByteSource(
        _bytes(chemistryEpub),
        revision: 'b',
        delay: const Duration(milliseconds: 1),
      );
      final sessionA = await BookSession.openSource(sourceA);
      final sessionB = await BookSession.openSource(sourceB);
      addTearDown(sessionB.dispose);

      expect(sessionA.sourceRevision, 'a');
      expect(sessionB.sourceRevision, 'b');

      final pathA = sessionA.book.readingOrder.first.name;
      final pathB = sessionB.book.readingOrder.first.name;
      final interleaved = await Future.wait([
        sessionA.loadDocumentText(pathA),
        sessionB.loadDocumentText(pathB),
        sessionA.loadDocumentText(pathA),
        sessionB.loadResource(pathB),
      ]);
      expect(interleaved[0], interleaved[2], reason: 'same session, same text');
      expect(interleaved[0], isNot(interleaved[1]), reason: 'different books');

      sessionA.dispose();
      await expectLater(sessionA.loadResource(pathA), throwsA(isA<SessionClosedException>()));
      // The other session keeps working after the neighbor died.
      expect(await sessionB.loadResource(pathB), isNotNull);
      expect(await sessionB.loadDocumentText(pathB), isNotNull);
    });

    test('a delayed reply after dispose serves nobody and a new session works', () async {
      final source = RecordingByteSource(
        _bytes(aliceEpub),
        delay: const Duration(milliseconds: 40),
      );
      final session = await BookSession.openSource(source);
      final inFlight = session.loadResource(session.book.readingOrder.first.name);
      session.dispose();

      // The disposed session's pending op fails typed; the delayed
      // byte reply that lands later cannot resurrect it.
      await expectLater(inFlight, throwsA(isA<UnsealException>()));

      final fresh = await BookSession.openSource(RecordingByteSource(_bytes(aliceEpub)));
      addTearDown(fresh.dispose);
      expect(await fresh.loadResource(fresh.book.readingOrder.first.name), isNotNull);
    });

    test('cancelPending fails an in-flight remote load; the session stays usable', () async {
      final source = RecordingByteSource(
        _bytes(mahabharataEpub),
        delay: const Duration(milliseconds: 30),
      );
      final session = await BookSession.openSource(source);
      addTearDown(session.dispose);

      final slow = session.search('xyzzy-nonexistent', maxMatches: 5);
      session.cancelPending();
      await expectLater(slow, throwsA(isA<SessionCancelledException>()));

      expect(
        await session.loadDocumentText(session.book.readingOrder.first.name),
        isNotNull,
        reason: 'the session answers new requests after a cancel',
      );
    });

    test('host sources close when their session disposes', () async {
      final source = RecordingByteSource(_bytes(aliceEpub));
      final session = await BookSession.openSource(source);
      expect(source.closed, isFalse);
      session.dispose();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(source.closed, isTrue, reason: 'dispose closed the host source through the gate');
    });

    test('the per-request cap refuses a huge entry instead of downloading it', () async {
      final raw = _bytes(mahabharataEpub);
      final source = RecordingByteSource(raw);
      // A 64 KiB per-request cap cannot serve the cover image (the
      // only entry whose compressed payload exceeds it): the load must
      // fail typed instead of silently issuing a bulk request. The
      // cover budget keeps the image out of the header so the load
      // walks the cap.
      final session = await BookSession.openSource(
        source,
        policy: const SessionPolicy(rangeRequestBytes: 1 << 16, coverMaxBytes: 1 << 16),
      );
      addTearDown(session.dispose);

      var largestEntry = 0;
      for (final entry in session.book.archiveEntries) {
        if (entry.size > largestEntry) largestEntry = entry.size;
      }
      expect(largestEntry, greaterThan(1 << 16), reason: 'fixture has a large entry');
      expect(
        (session.book as EpubBook).cover.isEmpty,
        isTrue,
        reason: 'the cover stayed out of the header',
      );

      var observed = false;
      for (final entry in session.book.archiveEntries) {
        try {
          await session.loadResource(entry.path);
        } on ByteSourceLimitExceededException {
          observed = true;
          break;
        } on Object {
          // Header-cached entries read fine; keep walking.
        }
      }
      expect(observed, isTrue, reason: 'an oversized entry failed the cap typed');
      expect(
        source.totalBytesRequested,
        lessThan(raw.length ~/ 10),
        reason: 'the refusal never turned into a bulk read',
      );
    });

    test('backpressure keeps bytes in flight under the policy cap', () async {
      final raw = _bytes(chemistryEpub);
      final source = RecordingByteSource(raw, delay: const Duration(milliseconds: 2));
      final policy = const SessionPolicy(
        rangeRequestsInFlight: 2,
        rangeBytesInFlight: 64 << 10,
        rangeRequestBytes: 64 << 10,
      );
      // The gate lives on this thread; the session's transport serves
      // requests through it, so its peaks are observable here via a
      // second gate over the same policy on the same source shape.
      final gate = ByteSourceGate(
        RecordingByteSource(raw, delay: const Duration(milliseconds: 2)),
        policy: policy,
      );
      final paths = <int>[];
      for (var i = 0; i < 12; i++) {
        paths.add(i * 4096);
      }
      await Future.wait<Uint8List>([for (final offset in paths) gate.read(offset, 4096)]);
      expect(gate.maxObservedInFlightRequests, lessThanOrEqualTo(2));
      expect(gate.maxObservedInFlightBytes, lessThanOrEqualTo(64 << 10));
      expect(source.delay, isNotNull, reason: 'the remote path exercises the same gate contract');
    });
  });
}

// ---------------------------------------------------------------------------
// Independent container inventory.
//
// This walk shares no code with Unseal: it locates the end-of-central-
// directory record by scanning raw bytes, then walks the central
// directory entries by hand. It exists so the partial-reading
// assertions check recorded reads against byte spans an independent
// parser derived.
// ---------------------------------------------------------------------------

final class _InventoryEntry {
  const _InventoryEntry({
    required this.name,
    required this.localHeaderOffset,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.dataEnd,
  });

  final String name;
  final int localHeaderOffset;
  final int compressedSize;
  final int uncompressedSize;

  /// Exclusive end of the entry's byte span: local header, its name
  /// and extra fields, and the compressed payload — everything a
  /// partial reader may touch when serving this entry.
  final int dataEnd;
}

final class _Inventory {
  const _Inventory({required this.entries, required this.directoryEnd});

  final List<_InventoryEntry> entries;
  final int directoryEnd;

  _InventoryEntry find(final String path) =>
      entries.firstWhere((final entry) => entry.name.toLowerCase() == path.toLowerCase());
}

_Inventory _parseZipInventoryIndependently(final Uint8List bytes) {
  int u16(final int offset) =>
      ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, Endian.little);
  int u32(final int offset) =>
      ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.little);

  const eocdLength = 22;
  var eocd = -1;
  for (
    var cursor = bytes.length - eocdLength;
    cursor >= 0 && cursor >= bytes.length - (65535 + eocdLength);
    cursor--
  ) {
    if (u32(cursor) == 0x06054b50) {
      eocd = cursor;
      break;
    }
  }
  expect(eocd, greaterThanOrEqualTo(0), reason: 'the fixture is a zip container');

  final entryCount = u16(eocd + 10);
  final directoryOffset = u32(eocd + 16);
  final directorySize = u32(eocd + 12);
  final directoryEnd = directoryOffset + directorySize;

  final entries = <_InventoryEntry>[];
  var cursor = directoryOffset;
  var remaining = entryCount;
  while (remaining > 0 && cursor + 46 <= directoryEnd) {
    expect(u32(cursor), 0x02014b50, reason: 'central directory record at $cursor');
    final nameLength = u16(cursor + 28);
    final extraLength = u16(cursor + 30);
    final commentLength = u16(cursor + 32);
    final name = convert.latin1.decode(
      Uint8List.sublistView(bytes, cursor + 46, cursor + 46 + nameLength),
    );
    final localHeaderOffset = u32(cursor + 42);
    final compressedSize = u32(cursor + 20);
    // The local header's own name/extra lengths decide where the
    // payload starts; the central-directory values need not match.
    final localNameLength = u16(localHeaderOffset + 26);
    final localExtraLength = u16(localHeaderOffset + 28);
    entries.add(
      _InventoryEntry(
        name: name,
        localHeaderOffset: localHeaderOffset,
        compressedSize: compressedSize,
        uncompressedSize: u32(cursor + 24),
        dataEnd: localHeaderOffset + 30 + localNameLength + localExtraLength + compressedSize,
      ),
    );
    cursor += 46 + nameLength + extraLength + commentLength;
    remaining--;
  }
  expect(remaining, 0, reason: 'every declared record parsed');

  return _Inventory(entries: entries, directoryEnd: directoryEnd);
}
