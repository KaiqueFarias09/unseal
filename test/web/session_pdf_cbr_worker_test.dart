@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/platform/web/worker_client.dart';
import 'package:unseal/unseal.dart';

import '../../tool/rar5_stream_encoder.dart';
import '../support/rar_fixtures.dart';
import '../tests/pdf/pdf_fixture_builder.dart';

Uint8List _pdfBytes() => Uint8List.fromList(textPageFixture().build());

Uint8List _multiPagePdfBytes() => Uint8List.fromList(multipageTextFixture(pageCount: 3).build());

Uint8List _cbrBytes() => Uint8List.fromList(
  buildRar4Files(<String, List<int>>{
    'ComicInfo.xml': comicInfoXml.codeUnits,
    'b.jpg': tinyJpegPage,
    'a.jpg': tinyJpegPage,
  }),
);

/// A RAR 5 archive whose single page is a compressed stream — built in
/// the browser with the same encoder that generates the VM fixtures.
final Uint8List _rar5Page = Uint8List.fromList([
  ...tinyJpegPage,
  ...tinyJpegPage,
  ...tinyJpegPage,
  ...tinyJpegPage,
]);

Uint8List _rar5CompressedBytes() =>
    buildRar5Archive(entries: [FixtureEntry('a.jpg', _rar5Page)], method: 3, dictExp: 0);

/// Proves the shared worker is live (never the inline fallback) by
/// opening and retiring a probe session over [bytes] through the raw
/// client, the same ritual as `session_worker_isolation_test.dart`.
Future<void> _expectRealWorker(final Uint8List bytes) async {
  final probe = await WorkerClient.instance.sessionOpenInWorker(bytes);
  expect(probe, isNotNull, reason: 'this integration test must exercise the real Web Worker');
  WorkerClient.instance.sessionDisposeInWorker(probe!.sessionId);
}

void main() {
  setUp(() {
    // The Chrome lane builds this worker before running test/web/.
    UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
  });

  tearDown(UnsealWorker.dispose);

  test('a PDF session in the worker decodes the header and serves pages', () async {
    final bytes = _pdfBytes();
    await _expectRealWorker(bytes);

    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);

    // Header decode: the placeholder pages carry the whole structure.
    final book = session.book as PdfBook;
    expect(book.pageCount, 1);
    expect(book.bytes, isEmpty, reason: 'the header carries no document bytes');
    expect([for (final item in book.readingOrder) item.name], <String>['page_1.html']);
    expect(session.byteLength, bytes.length);

    // Page materialization across the worker wire.
    final full = Unseal.parse(bytes) as PdfBook;
    final text = await session.loadDocumentText('page_1.html');
    expect(text, isNotNull);
    expect(text, isNotEmpty);
    expect(text, full.pageTexts.single.text, reason: 'canonical text parity');

    final lines = await session.loadPdfPageLines(0);
    expect(lines, isNotNull);
    expect(lines!.lines, isNotEmpty);

    // Search shares the same canonical offset space in the worker.
    final results = await session.search('Hello', maxMatches: 10);
    expect(results.matches, isNotEmpty);
    expect(results.matches.first.sectionName, 'page_1.html');

    // Raw slices of the resident source.
    expect(await session.loadBytesRange(0, 4), Uint8List.fromList('%PDF'.codeUnits));
  });

  test('a PDF session in the worker serves page structures with geometry', () async {
    final bytes = Uint8List.fromList(
      changingStatisticsFixture(pageCount: 26, plainPages: 20).build(),
    );
    await _expectRealWorker(bytes);

    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);

    // Page 24 (0-based) sits after the 20-page sample: the session's
    // sampled plan and the eager document plan are different profiles
    // by construction.
    final structure = await session.loadPdfPageStructure(24);
    expect(structure, isNotNull, reason: 'the worker answered the pdfStructure op');
    final page = structure!;
    expect(page.pageIndex, 24);
    expect(page.canonicalProfile.options['scope'], 'session-sample');
    expect(page.geometry.width, 612);
    expect(page.geometry.transformInvertible, isTrue);

    // Geometry and text survive the wire unchanged.
    final lines = await session.loadPdfPageLines(24);
    expect(lines!.text, page.canonicalText);
    expect(page.words, isNotEmpty);
    expect(page.blocks, isNotEmpty);
    final word = page.words.first;
    expect(word.text, isNotEmpty);
    expect(word.width, greaterThan(0));

    // The mapping vocabulary works on the decoded structure.
    final anchor = PdfSourceRange(
      pageIndex: 24,
      lineIndex: 1,
      start: 0,
      end: page.sourceLines[1].text.length,
      expectedLineText: page.sourceLines[1].text,
    );
    final mapping = page.mapSourceRange(anchor);
    expect(mapping, isA<PdfPositionMapped>());
    final position = (mapping as PdfPositionMapped).position;
    expect(page.canonicalText.substring(position.offset, position.end), page.sourceLines[1].text);
  });

  test('a CBR session in the worker lists pages and serves their bytes', () async {
    final bytes = _cbrBytes();
    await _expectRealWorker(bytes);

    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);

    final book = session.book as ComicBook;
    expect(book.format, BookFormat.cbr);
    expect(book.pageCount, 2);
    expect(
      [for (final page in book.pages) page.path],
      <String>['a.jpg', 'b.jpg'],
      reason: 'natural page order (ComicInfo excluded)',
    );
    expect(book.metadata.title, 'Session Parity 1', reason: 'ComicInfo crossed the wire');
    expect(session.byteLength, bytes.length);

    expect(await session.loadResource('a.jpg'), tinyJpegPage);
    expect(await session.loadBytesRange(0, 4), Uint8List.fromList('Rar!'.codeUnits));
  });

  test('a RAR 5 compressed CBR session in the worker serves decoded pages', () async {
    final bytes = _rar5CompressedBytes();
    await _expectRealWorker(bytes);

    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);

    final book = session.book as ComicBook;
    expect(book.format, BookFormat.cbr);
    expect(book.pageCount, 1);
    expect(book.pages.single.path, 'a.jpg');
    // The decoded page matches the pre-image bytes the encoder started
    // from — the worker ran the RAR 5 LZ decoder, not a passthrough.
    // Out-of-order across two sessions: the same bytes everywhere.
    final other = await BookSession.open(bytes);
    addTearDown(other.dispose);
    final otherBook = other.book as ComicBook;
    expect(await other.loadResource(otherBook.pages.single.path), _rar5Page);
    expect(await session.loadResource(book.pages.single.path), _rar5Page);
    expect(await session.loadResource(book.pages.single.path), _rar5Page, reason: 'reread');
  });

  test('a solid CBR session in the worker serves forward, reverse and rereads', () async {
    // A solid chain: later pages reference earlier ones' dictionary
    // state, so the worker runs the sequential decoder end to end.
    final pages = <FixtureEntry>[
      for (var i = 0; i < 4; i++)
        FixtureEntry(
          'page-$i.jpg',
          Uint8List.fromList([...tinyJpegPage, ...List<int>.filled(2048, i), ...tinyJpegPage]),
        ),
    ];
    final bytes = Uint8List.fromList(
      buildRar5Archive(entries: pages, method: 3, dictExp: 0, archiveSolid: true),
    );
    await _expectRealWorker(bytes);

    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);
    final book = session.book as ComicBook;
    expect(book.pageCount, 4);

    for (var i = 0; i < pages.length; i++) {
      expect(await session.loadResource(pages[i].name), pages[i].content, reason: 'forward $i');
    }
    for (var i = pages.length - 1; i >= 0; i--) {
      expect(await session.loadResource(pages[i].name), pages[i].content, reason: 'reverse $i');
    }

    // A second session interleaves with its own dictionary.
    final other = await BookSession.open(bytes);
    addTearDown(other.dispose);
    final otherBook = other.book as ComicBook;
    expect(await other.loadResource(otherBook.pages.last.path), pages.last.content);
    expect(await session.loadResource(book.pages.first.path), pages.first.content);

    final cancelled = session.loadResource(book.pages.last.path);
    final cancelledExpectation = expectLater(cancelled, throwsA(isA<SessionCancelledException>()));
    final survivingRead = other.loadResource(otherBook.pages.first.path);
    session.cancelPending();
    await cancelledExpectation;
    expect(await survivingRead, pages.first.content);
    expect(
      await session.loadResource(book.pages.last.path),
      pages.last.content,
      reason: 'cancelled solid sessions remain usable',
    );

    final disposed = session.loadResource(book.pages.first.path);
    final disposedExpectation = expectLater(disposed, throwsA(isA<SessionClosedException>()));
    session.dispose();
    await disposedExpectation;
    expect(
      () => session.loadResource(book.pages.last.path),
      throwsA(isA<SessionClosedException>()),
    );
    expect(
      await other.loadResource(otherBook.pages.last.path),
      pages.last.content,
      reason: 'disposing one solid dictionary does not end the other session',
    );
    final reopened = await BookSession.open(bytes);
    addTearDown(reopened.dispose);
    expect(
      await reopened.loadResource(pages.last.name),
      pages.last.content,
      reason: 'late replies cannot replace a fresh solid session',
    );
  });

  test('two PDF sessions in the worker stay isolated', () async {
    final oneBytes = _pdfBytes();
    await _expectRealWorker(oneBytes);

    final one = await BookSession.open(oneBytes);
    final many = await BookSession.open(_multiPagePdfBytes());
    addTearDown(many.dispose);

    expect(await one.loadDocumentText('page_1.html'), isNotNull);
    expect((many.book as PdfBook).pageCount, 3);

    one.dispose();
    expect(
      () => one.loadDocumentText('page_1.html'),
      throwsA(isA<SessionClosedException>()),
      reason: 'the web transport rejects disposed sessions synchronously',
    );
    expect(await many.loadDocumentText('page_2.html'), isNotNull);
  });

  test('disposing a worker session fails subsequent ops typed', () async {
    final bytes = _pdfBytes();
    await _expectRealWorker(bytes);

    final session = await BookSession.open(bytes);
    expect(await session.loadDocumentText('page_1.html'), isNotNull);

    session.dispose();
    expect(() => session.loadDocumentText('page_1.html'), throwsA(isA<SessionClosedException>()));
    expect(() => session.loadBytesRange(0, 4), throwsA(isA<SessionClosedException>()));
  });
}
