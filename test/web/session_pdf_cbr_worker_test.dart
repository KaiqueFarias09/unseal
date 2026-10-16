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
