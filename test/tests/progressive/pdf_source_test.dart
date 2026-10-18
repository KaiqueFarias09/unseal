import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/src/foundation/archive/async_byte_reader.dart';
import 'package:unseal/unseal.dart';

// PR01/PR03/PR06/PR07 coverage for PDF over `BookSession.openSource`:
// the public entry, identity and typed failures, independently observed
// partial reads on the two large fixtures fixed in
// doc/proposals/C01-pdf-byte-source.md, public counters and
// backpressure, and content parity with the bytes session down to
// anchors and index reuse.
const dickensPdf = 'test/resources/pdf/dickens-sample.pdf';
const mobyDickPdf = 'test/resources/pdf/gutenberg/pg2701-generated.pdf';
const jbig2Pdf = 'test/resources/pdf/jbig2/jbig2_huffman_2.pdf';
const euclidPdf = 'test/resources/books/pdf/elements-of-euclid-pg.pdf';
const r6Pdf = 'test/resources/pdf/encrypted/r6.pdf';
const ownerOnlyPdf = 'test/resources/pdf/encrypted/owner-only.pdf';
const r6Password = 'user123';

/// The large-file ceiling fixed in the proposal, before implementation.
const partialReadCeiling = 0.5;

Uint8List _bytes(final String path) => Uint8List.fromList(File(path).readAsBytesSync());

/// The independent observer: exact slices over an in-memory buffer,
/// every range recorded. The merged coverage the partial-reading
/// assertions compute is derived here, outside Unseal's code.
final class RecordingByteSource implements UnsealByteSource {
  RecordingByteSource(this.bytes, {this.revision, this.delay = Duration.zero});

  final Uint8List bytes;
  @override
  String? revision;
  final Duration delay;

  var _closed = false;
  var activeRequests = 0;
  var peakRequests = 0;
  final List<({int offset, int count})> reads = <({int offset, int count})>[];

  bool get closed => _closed;
  int get readCount => reads.length;
  int get totalBytes => reads.fold(0, (final total, final read) => total + read.count);

  /// Unique byte coverage of everything read so far, computed by a
  /// plain interval merge on the recorded log.
  int uniqueBytes() {
    final sorted = [...reads]..sort((final a, final b) => a.offset.compareTo(b.offset));
    var unique = 0;
    var cursor = -1;
    for (final read in sorted) {
      final end = read.offset + read.count;
      if (end <= cursor) continue;
      unique += end - (read.offset > cursor ? read.offset : cursor);
      cursor = end;
    }

    return unique;
  }

  @override
  int get length => bytes.length;

  @override
  Future<Uint8List> readRange(final int offset, final int count) async {
    if (_closed) throw const ByteSourceClosedException();
    RangeError.checkValidRange(offset, offset + count, bytes.length, 'offset', 'end');
    activeRequests++;
    if (activeRequests > peakRequests) peakRequests = activeRequests;
    reads.add((offset: offset, count: count));
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    activeRequests--;

    return Uint8List.sublistView(bytes, offset, offset + count);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

void main() {
  group('PDF opens over a host byte source (PR01)', () {
    test('the public entry returns the full header book', () async {
      final raw = _bytes(dickensPdf);
      final source = RecordingByteSource(raw, revision: 'etag-c01');
      final session = await BookSession.openSource(source);
      addTearDown(session.dispose);

      final eager = Unseal.parse(raw) as PdfBook;
      final book = session.book;
      expect(book, isA<PdfBook>());
      final pdf = book as PdfBook;
      expect(pdf.pageCount, eager.pageCount);
      expect(pdf.metadata.title, eager.metadata.title);
      expect(pdf.metadata.authors, eager.metadata.authors);
      expect(pdf.navigation.navPoints, eager.navigation.navPoints);
      expect(book.readingOrder, hasLength(eager.pageCount));
      expect(session.byteLength, raw.length);
      expect(session.sourceRevision, 'etag-c01');
      expect(session.isProgressive, isTrue);
    });

    test('encrypted documents open with the password and fail typed without', () async {
      final r6 = _bytes(r6Pdf);
      final plain = _bytes(dickensPdf);

      final locked = await BookSession.openSource(RecordingByteSource(r6), password: r6Password);
      addTearDown(locked.dispose);
      final lockedText = await locked.loadDocumentText('page_1.html');
      final eagerPlain = Unseal.parse(plain) as PdfBook;
      expect(lockedText, eagerPlain.pageTexts[0].text);

      await expectLater(
        BookSession.openSource(RecordingByteSource(r6)),
        throwsA(
          isA<PdfEncryptedException>().having(
            (final error) => error.requiresNonEmptyPassword,
            'requiresNonEmptyPassword',
            isTrue,
          ),
        ),
      );

      await expectLater(
        BookSession.openSource(RecordingByteSource(r6), password: 'wrong'),
        throwsA(isA<PdfEncryptedException>()),
      );

      // Owner-only encryption (empty user password) opens unchanged.
      final ownerOnly = await BookSession.openSource(RecordingByteSource(_bytes(ownerOnlyPdf)));
      addTearDown(ownerOnly.dispose);
      expect(await ownerOnly.loadDocumentText('page_1.html'), isNotNull);
    });

    test('broken sources and documents fail typed', () async {
      await expectLater(
        BookSession.openSource(RecordingByteSource(Uint8List(0))),
        throwsA(isA<EmptyBytesException>()),
      );

      // A valid container signature over nothing: parse-time
      // corruption, not an unsupported format.
      await expectLater(
        BookSession.openSource(
          RecordingByteSource(
            Uint8List.fromList(<int>[0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34]),
          ),
        ),
        throwsA(isA<PdfException>()),
      );

      // Non-PDF bytes keep the format refusal.
      await expectLater(
        BookSession.openSource(RecordingByteSource(Uint8List.fromList(List.filled(64, 0x41)))),
        throwsA(isA<SessionUnsupportedFormatException>()),
      );
    });
  });

  group('partial reads on the fixed large fixtures (PR03)', () {
    for (final fixture in [jbig2Pdf, euclidPdf]) {
      test('open + first content reads under 50% of $fixture', () async {
        final raw = _bytes(fixture);
        final source = RecordingByteSource(raw);
        final session = await BookSession.openSource(source);
        addTearDown(session.dispose);

        final pageCount = (session.book as PdfBook).pageCount;
        final firstPastSample = math.min(20, pageCount); // 0-based page 20
        final text = await session.loadDocumentText('page_${firstPastSample + 1}.html');
        expect(text, isNotNull);

        final unique = source.uniqueBytes();
        final fraction = unique / raw.length;
        expect(
          fraction,
          lessThan(partialReadCeiling),
          reason:
              '$fixture: open+first content read $unique unique bytes of '
              '${raw.length} (${(fraction * 100).toStringAsFixed(2)}%)',
        );

        final metrics = await session.metrics();
        expect(
          metrics.pdfRangeResidentPeak,
          lessThan(raw.length ~/ 2),
          reason: 'no complete-file buffer may stay resident',
        );
      });

      test('a distant jump on $fixture costs a bounded extra read', () async {
        final raw = _bytes(fixture);
        final source = RecordingByteSource(raw);
        final session = await BookSession.openSource(source);
        addTearDown(session.dispose);

        final pageCount = (session.book as PdfBook).pageCount;
        await session.loadDocumentText('page_21.html');
        final before = source.readCount;
        final beforeUnique = source.uniqueBytes();
        final last = await session.loadDocumentText('page_$pageCount.html');
        expect(last, isNotNull);

        final jumpUnique = source.uniqueBytes() - beforeUnique;
        expect(source.readCount - before, lessThan(40));
        expect(
          jumpUnique,
          lessThan(raw.length ~/ 10),
          reason: 'a distant page jump must not drag a large share of the file',
        );
      });
    }
  });

  group('public counters and backpressure (PR06)', () {
    test('metrics report the loader ledger observed on the wire', () async {
      final raw = _bytes(dickensPdf);
      final source = RecordingByteSource(raw);
      final session = await BookSession.openSource(source);
      addTearDown(session.dispose);

      final metrics = await session.metrics();
      expect(metrics.containerReads, greaterThan(0));
      // The ledger covers every wire byte, the format probe included.
      expect(metrics.sourceBytesRead, source.totalBytes);
      expect(metrics.pdfRangeFetches, greaterThan(0));
      expect(metrics.pdfRangeFetchBytes, greaterThan(0));
      expect(metrics.pdfRangeUniqueBytes, lessThanOrEqualTo(source.totalBytes));
      expect(metrics.pdfRangeResidentPeak, greaterThan(0));
    });

    test('concurrent ops queue on the shared parser and the wire stays capped', () async {
      final raw = _bytes(mobyDickPdf);

      // Two materializations race for the shared parser: they queue,
      // both complete, and the host never sees parallel reads above
      // the session's in-flight cap.
      final source = RecordingByteSource(raw, delay: const Duration(milliseconds: 1));
      final session = await BookSession.openSource(
        source,
        policy: const SessionPolicy(rangeRequestsInFlight: 1),
      );
      addTearDown(session.dispose);

      final first = session.loadDocumentText('page_25.html');
      final second = session.loadDocumentText('page_26.html');
      final results = await Future.wait([first, second]);
      expect(results[0], isNotNull);
      expect(results[1], isNotNull);

      final metrics = await session.metrics();
      // The session isolate serves op messages one at a time (platform
      // port batching), so the queue depth stays observable but small;
      // the inline-path test below proves depth 2+ against the loader.
      expect(metrics.pdfRangeQueuedStepsPeak, greaterThanOrEqualTo(1));
      expect(source.peakRequests, 1, reason: 'the single-slot cap held');
      expect(
        // Concurrent results must equal the bytes-session results.
        results[0],
        await (await BookSession.open(_bytes(mobyDickPdf))).loadDocumentText('page_25.html'),
      );
    });

    test('the inline engine queues concurrent steps on the shared parser', () async {
      final raw = _bytes(mobyDickPdf);
      final source = RecordingByteSource(raw, delay: const Duration(milliseconds: 1));
      final engine = await SessionEngine.openRemote(
        CallbackAsyncByteReader(length: source.length, revision: null, read: source.readRange),
        policy: const SessionPolicy(rangeRequestsInFlight: 1),
      );

      final first = engine.documentText('page_25.html');
      final second = engine.documentText('page_26.html');
      final results = await Future.wait([first, second]);
      expect(results[0], isNotNull);
      expect(results[1], isNotNull);
      expect(engine.metrics()['pdfRangeQueuedStepsPeak'], greaterThanOrEqualTo(2));
      expect(source.peakRequests, 1);
    });
  });

  group('content parity and anchors over sources (PR07)', () {
    test('page text, lines, structure, search, progression equal the bytes session', () async {
      final raw = _bytes(dickensPdf);
      final bytesSession = await BookSession.open(raw);
      addTearDown(bytesSession.dispose);
      final sourceSession = await BookSession.openSource(RecordingByteSource(raw));
      addTearDown(sourceSession.dispose);

      expect(
        await sourceSession.loadDocumentText('page_1.html'),
        await bytesSession.loadDocumentText('page_1.html'),
      );

      final sourceLines = await sourceSession.loadPdfPageLines(0);
      final bytesLines = await bytesSession.loadPdfPageLines(0);
      expect(sourceLines!.lines.length, bytesLines!.lines.length);
      for (var i = 0; i < sourceLines.lines.length; i++) {
        expect(sourceLines.lines[i].text, bytesLines.lines[i].text);
      }

      final sourceStructure = (await sourceSession.loadPdfPageStructure(0))!;
      final bytesStructure = (await bytesSession.loadPdfPageStructure(0))!;
      expect(sourceStructure.canonicalText, bytesStructure.canonicalText);
      expect(sourceStructure.words.length, bytesStructure.words.length);
      expect(sourceStructure.geometry.width, bytesStructure.geometry.width);
      expect(sourceStructure.geometry.height, bytesStructure.geometry.height);

      final sourceSearch = await sourceSession.search('Chapter');
      final bytesSearch = await bytesSession.search('Chapter');
      expect(sourceSearch.matches.length, bytesSearch.matches.length);
      expect(sourceSearch.matches.first.start, bytesSearch.matches.first.start);
      expect(sourceSearch.matches.first.sectionName, bytesSearch.matches.first.sectionName);

      expect(
        (await sourceSession.computeProgression()).sectionLengths,
        (await bytesSession.computeProgression()).sectionLengths,
      );
    });

    test('search index builds, queries, exports and refuses foreign reuse', () async {
      final raw = _bytes(dickensPdf);
      final sourceSession = await BookSession.openSource(RecordingByteSource(raw));
      addTearDown(sourceSession.dispose);

      final coverage = await sourceSession.buildSearchIndex();
      expect(coverage.isComplete, isTrue);
      final hits = await sourceSession.searchIndexed('Chapter');
      expect(hits.hits, isNotEmpty);
      expect(hits.coverage.isComplete, isTrue);

      // The serialized index reopens over the same book from bytes —
      // same profile, same reading order.
      final bytesSession = await BookSession.open(raw);
      addTearDown(bytesSession.dispose);
      final imported = await bytesSession.importSearchIndex(
        await sourceSession.exportSearchIndex(),
      );
      expect(imported.isComplete, isTrue);

      // A different book refuses the reuse explicitly.
      final other = await BookSession.openSource(
        RecordingByteSource(_bytes('test/resources/pdf/gutenberg/pg11-generated.pdf')),
      );
      addTearDown(other.dispose);
      await expectLater(
        other.importSearchIndex(await sourceSession.exportSearchIndex()),
        throwsA(isA<UnsealException>()),
      );
    });

    test('an anchor captured in one source session resolves in another', () async {
      final raw = _bytes(dickensPdf);
      final first = await BookSession.openSource(RecordingByteSource(raw));
      addTearDown(first.dispose);

      final structure = (await first.loadPdfPageStructure(0))!;
      final identity = PublicationRevision(
        publicationId: 'c01:anchor-parity',
        sourceRevision: 'c01:fixed-revision',
        sourceEvidence: SourceEvidence.host,
      );
      final snapshot = structure.canonicalSnapshot(identity: identity);
      final quote = structure.canonicalText;
      final start = quote.indexOf('Chapter');
      expect(start, greaterThanOrEqualTo(0));
      final anchor = DurableAnnotations.capture(snapshot: snapshot, start: start, end: start + 24);

      final second = await BookSession.openSource(RecordingByteSource(raw));
      addTearDown(second.dispose);
      final reopened = (await second.loadPdfPageStructure(
        0,
      ))!.canonicalSnapshot(identity: identity);
      final resolution = DurableAnnotations.resolve(anchor: anchor, targets: [reopened]);
      expect(resolution, isA<AnchorResolved>());
      expect((resolution as AnchorResolved).verified, isTrue);
      expect(resolution.range.text, anchor.quote.exact);

      // A host claiming a different revision refuses the reuse.
      final revised = (await second.loadPdfPageStructure(0))!.canonicalSnapshot(
        identity: PublicationRevision(
          publicationId: identity.publicationId,
          sourceRevision: 'c01:other-revision',
          sourceEvidence: SourceEvidence.host,
        ),
      );
      expect(
        DurableAnnotations.resolve(anchor: anchor, targets: [revised]),
        isA<AnchorIncompatibleRevision>(),
      );
    });
  });
}
