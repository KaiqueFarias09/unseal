import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

// PR05 (isolate lane): two source sessions over the real session
// isolate — interleaved and reverse-order loads, cancellation of a
// pending read, disposal under load, and the survivor session. The
// worker lane lives in test/web/pdf_source_worker_test.dart.
const dickensPdf = 'test/resources/pdf/dickens-sample.pdf';
const alicePdf = 'test/resources/pdf/gutenberg/pg11-generated.pdf';
const mobyDickPdf = 'test/resources/pdf/gutenberg/pg2701-generated.pdf';

Uint8List _bytes(final String path) => Uint8List.fromList(File(path).readAsBytesSync());

/// A source that stalls every read, so lifecycle events race real
/// in-flight requests.
final class SlowSource implements UnsealByteSource {
  SlowSource(this.bytes, {this.delay = const Duration(milliseconds: 25)});

  final Uint8List bytes;
  final Duration delay;
  final Completer<void> _firstRead = Completer<void>();
  var _closed = false;
  var _reads = 0;

  bool get closed => _closed;
  int get readCount => _reads;
  Future<void> get firstRead => _firstRead.future;

  @override
  int get length => bytes.length;

  @override
  String? get revision => null;

  @override
  Future<Uint8List> readRange(final int offset, final int count) async {
    if (_closed) throw const ByteSourceClosedException();
    _reads++;
    if (!_firstRead.isCompleted) _firstRead.complete();
    await Future<void>.delayed(delay);

    return Uint8List.sublistView(bytes, offset, offset + count);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

void main() {
  test('two source sessions interleave and serve reverse-order loads', () async {
    final dickens = _bytes(dickensPdf);
    final alice = _bytes(alicePdf);
    final sessionA = await BookSession.openSource(SlowSource(dickens, delay: Duration.zero));
    final sessionB = await BookSession.openSource(SlowSource(alice, delay: Duration.zero));
    addTearDown(sessionA.dispose);
    addTearDown(sessionB.dispose);

    final pagesA = (sessionA.book as PdfBook).pageCount;
    final pagesB = (sessionB.book as PdfBook).pageCount;

    // Reverse order: the last page of each first, then the first page.
    final lastA = await sessionA.loadDocumentText('page_$pagesA.html');
    final lastB = await sessionB.loadDocumentText('page_$pagesB.html');
    final firstA = await sessionA.loadDocumentText('page_1.html');
    final firstB = await sessionB.loadDocumentText('page_1.html');

    final eagerA = Unseal.parse(dickens) as PdfBook;
    final eagerB = Unseal.parse(alice) as PdfBook;
    expect(lastA, eagerA.pageTexts[pagesA - 1].text);
    expect(firstA, eagerA.pageTexts[0].text);
    expect(lastB, eagerB.pageTexts[pagesB - 1].text);
    expect(firstB, eagerB.pageTexts[0].text);
  });

  test('cancelPending fails the in-flight read; the session keeps serving', () async {
    final source = SlowSource(_bytes(mobyDickPdf));
    final session = await BookSession.openSource(source);
    addTearDown(session.dispose);

    final pages = (session.book as PdfBook).pageCount;
    // A deep page needs wire reads the cache cannot serve.
    final pending = session.loadDocumentText('page_${pages - 40}.html');
    await source.firstRead;
    session.cancelPending();
    await expectLater(pending, throwsA(isA<SessionCancelledException>()));

    // The engine survives: a fresh op completes with the right bytes.
    final recovered = await session.loadDocumentText('page_$pages.html');
    final eager = Unseal.parse(_bytes(mobyDickPdf)) as PdfBook;
    expect(recovered, eager.pageTexts[pages - 1].text);
  });

  test('disposing under load fails the op, closes the source, keeps the peer', () async {
    final doomedSource = SlowSource(_bytes(mobyDickPdf));
    final peerSource = SlowSource(_bytes(alicePdf), delay: Duration.zero);
    final doomed = await BookSession.openSource(doomedSource);
    final peer = await BookSession.openSource(peerSource);
    addTearDown(peer.dispose);

    final doomedPages = (doomed.book as PdfBook).pageCount;
    final pending = doomed.loadDocumentText('page_${doomedPages - 40}.html');
    await doomedSource.firstRead;
    doomed.dispose();
    await expectLater(pending, throwsA(isA<SessionClosedException>()));
    expect(doomedSource.closed, isTrue, reason: 'dispose closed the host source');

    // Late bridge replies land on a dead session: they serve nobody
    // and must not disturb the peer.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await expectLater(
      doomed.loadDocumentText('page_1.html'),
      throwsA(isA<SessionClosedException>()),
    );

    final peerPages = (peer.book as PdfBook).pageCount;
    final peerEager = Unseal.parse(_bytes(alicePdf)) as PdfBook;
    expect(
      await peer.loadDocumentText('page_$peerPages.html'),
      peerEager.pageTexts[peerPages - 1].text,
    );
  });

  test('a source closed by its owner fails pending reads typed', () async {
    final source = SlowSource(_bytes(mobyDickPdf), delay: const Duration(milliseconds: 40));
    final session = await BookSession.openSource(source);
    addTearDown(session.dispose);

    // A deep page needs wire reads the cache cannot serve.
    final pages = (session.book as PdfBook).pageCount;
    final pending = session.loadDocumentText('page_${pages - 40}.html');
    await source.firstRead;
    await source.close();
    await expectLater(pending, throwsA(isA<UnsealException>()));
  });
}
