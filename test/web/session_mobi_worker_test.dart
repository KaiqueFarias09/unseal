@TestOn('browser')
library;

import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/platform/web/worker_client.dart';
import 'package:unseal/unseal.dart';

import '../tests/mobi/mobi_fixture_builder.dart';

Uint8List _mobiBook(final String title) {
  List<int> chapter(final String name) => convert.utf8.encode(
    '<html><body><h1>$name</h1>'
    '<p>${List.filled(30, 'palavra').join(' ')}</p></body></html>',
  );
  final secondText = convert.utf8.decode(chapter('Dois'));
  final thirdText = convert.utf8.decode(chapter('Tres'));
  final prefix = '<html><body><h1>Um</h1><p>${List.filled(30, 'palavra').join(' ')}</p>';
  const zeros = '0000000000';
  final linkedText =
      '$prefix'
      '<a filepos="$zeros">b</a>'
      '<a filepos="$zeros">c</a>'
      '</body></html>';
  final secondStart = linkedText.length + secondText.indexOf('<h1>');
  final thirdStart = linkedText.length + secondText.length + thirdText.indexOf('<h1>');
  var replacement = 0;
  final linked = convert.utf8.encode(
    linkedText.replaceAllMapped(zeros, (final _) {
      replacement++;

      return (replacement == 1 ? secondStart : thirdStart).toString().padLeft(10, '0');
    }),
  );

  return buildPdb('Web$title', [
    buildMobiRecord0(compressionType: 1, textRecordCount: 3, title: title),
    Uint8List.fromList(linked),
    Uint8List.fromList(chapter('Dois')),
    Uint8List.fromList(chapter('Tres')),
  ]);
}

/// Proves the shared worker is live (never the inline fallback) by
/// opening and retiring a probe session through the raw client.
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

  test('a MOBI session crosses the worker wire with structure only', () async {
    final bytes = _mobiBook('WireMobi');
    await _expectRealWorker(bytes);

    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);

    final book = session.book as MobiBook;
    expect(book.format, BookFormat.mobi);
    expect(book.files.html, isEmpty, reason: 'the header carries no content');
    expect(book.metadata.title, 'WireMobi');
    expect(book.readingOrder, hasLength(greaterThanOrEqualTo(2)));
    // The eager parse, run in the browser, agrees on section text.
    final eager = Unseal.parse(bytes) as MobiBook;
    final eagerText = eager.files.html.map(documentTextOf).join();
    final buffer = StringBuffer();
    for (final item in book.readingOrder) {
      buffer.write(await session.loadDocumentText(item.name));
    }
    expect(buffer.toString(), eagerText);
  });

  test('two MOBI sessions address their own books in the worker', () async {
    final a = await BookSession.open(_mobiBook('AlphaMobi'));
    final b = await BookSession.open(_mobiBook('BravoMobi'));
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    expect(a.book.metadata.title, 'AlphaMobi');
    expect(b.book.metadata.title, 'BravoMobi');

    // Out-of-order section requests across two sessions.
    final bLast = b.loadDocumentText(b.book.readingOrder.last.name);
    final aFirst = a.loadDocumentText(a.book.readingOrder.first.name);
    expect(await bLast, contains('Tres'));
    expect(await aFirst, isNotNull);

    // Metrics cross the wire too.
    final metrics = await a.metrics();
    expect(metrics.contentBytesMaterialized, greaterThan(0));
  });

  test('disposing one MOBI session leaves the other serving', () async {
    final a = await BookSession.open(_mobiBook('DisposeA'));
    final b = await BookSession.open(_mobiBook('DisposeB'));
    addTearDown(b.dispose);

    a.dispose();
    await expectLater(
      a.loadDocumentText(a.book.readingOrder.first.name),
      throwsA(isA<SessionClosedException>()),
    );
    final text = await b.loadDocumentText(b.book.readingOrder.first.name);
    expect(text, isNotNull);
  });

  test('cancelPending leaves a MOBI worker session usable', () async {
    final session = await BookSession.open(_mobiBook('CancelMobi'));
    addTearDown(session.dispose);

    session.cancelPending();
    final text = await session.loadDocumentText(session.book.readingOrder.first.name);
    expect(text, isNotNull);
  });
}
