import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../mobi/mobi_fixture_builder.dart';

Uint8List _alice() => File('test/resources/books/mobi/alice-old-pg.mobi').readAsBytesSync();
Uint8List _kf8() => File('test/resources/books/mobi/alice-kf8-pg.azw3').readAsBytesSync();

Uint8List _small() {
  String chapter(final String title) =>
      '<html><body><h1>$title</h1>'
      '<p>${List.filled(40, 'palavra').join(' ')}</p></body></html>';
  final secondText = chapter('Dois');
  final thirdText = chapter('Tres');
  final prefix = '<html><body><h1>Um</h1><p>${List.filled(40, 'palavra').join(' ')}</p>';
  final zeros = '0' * 10;
  final linkedText =
      '$prefix'
      '<a filepos="$zeros">b</a>'
      '<a filepos="$zeros">c</a>'
      '</body></html>';
  final secondStart = linkedText.length + secondText.indexOf('<h1>');
  final thirdStart = linkedText.length + secondText.length + thirdText.indexOf('<h1>');
  var replacement = 0;
  final linkedFilled = linkedText.replaceAllMapped(zeros, (final _) {
    replacement++;

    return (replacement == 1 ? secondStart : thirdStart).toString().padLeft(10, '0');
  });
  final linked = Uint8List.fromList(convert.utf8.encode(linkedFilled));
  final second = Uint8List.fromList(convert.utf8.encode(secondText));
  final third = Uint8List.fromList(convert.utf8.encode(thirdText));
  return buildPdb('LifecycleFixture', [
    buildMobiRecord0(compressionType: 1, textRecordCount: 3, title: 'Lifecycle'),
    linked,
    second,
    third,
  ]);
}

void main() {
  group('concurrent sessions', () {
    test('two sessions over different books stay isolated', () async {
      final mobi = await BookSession.open(_alice());
      final kf8 = await BookSession.open(_kf8());
      try {
        expect((mobi.book as MobiBook).format, BookFormat.mobi);
        expect((kf8.book as MobiBook).format, BookFormat.azw3);

        final mobiText = await mobi.loadDocumentText(mobi.book.readingOrder.first.name);
        final kf8Text = await kf8.loadDocumentText(kf8.book.readingOrder.first.name);
        expect(mobiText, contains('Alice'));
        expect(kf8Text, isNotNull);
        expect(kf8Text, isNot(contains('Alice was beginning')));
      } finally {
        mobi.dispose();
        kf8.dispose();
      }
    });

    test('two sessions over the same bytes keep independent caches', () async {
      final bytes = _alice();
      final a = await BookSession.open(bytes);
      final b = await BookSession.open(bytes);
      try {
        final aMetrics = await a.metrics();
        expect(b, isNot(same(a)));
        // Loading in A does not warm B.
        expect((await b.metrics()).contentBytesMaterialized, aMetrics.contentBytesMaterialized);
        await a.loadDocumentText(a.book.readingOrder.first.name);
        expect((await b.metrics()).contentBytesMaterialized, aMetrics.contentBytesMaterialized);
      } finally {
        a.dispose();
        b.dispose();
      }
    });
  });

  group('out-of-order requests', () {
    test('sections resolve independently of request order', () async {
      final session = await BookSession.open(_small());
      try {
        final order = session.book.readingOrder;
        expect(order.length, greaterThanOrEqualTo(3));
        // Issue the last section first, then the first; both complete
        // with their own content.
        final lastFuture = session.loadDocumentText(order.last.name);
        final firstFuture = session.loadDocumentText(order.first.name);
        final last = await lastFuture;
        final first = await firstFuture;
        expect(last, contains('Tres'));
        expect(first, isNotNull);
        expect(last, isNot(first));
      } finally {
        session.dispose();
      }
    });
  });

  group('cancellation and disposal', () {
    test('cancelPending keeps the session usable', () async {
      final session = await BookSession.open(_small());
      try {
        // Nothing is in flight on the inline-sync engine; the contract
        // under cancellation is that later requests still work.
        session.cancelPending();
        final text = await session.loadDocumentText(session.book.readingOrder.first.name);
        expect(text, isNotNull);
      } finally {
        session.dispose();
      }
    });

    test('dispose fails subsequent requests with the closed failure', () async {
      final session = await BookSession.open(_small());
      final name = session.book.readingOrder.first.name;
      session.dispose();

      await expectLater(session.loadDocumentText(name), throwsA(isA<SessionClosedException>()));
      await expectLater(session.metrics(), throwsA(isA<SessionClosedException>()));
    });

    test('a disposed session reopens cleanly over the same bytes', () async {
      final bytes = _small();
      final first = await BookSession.open(bytes);
      final firstName = first.book.readingOrder.first.name;
      first.dispose();

      final second = await BookSession.open(bytes);
      try {
        final text = await second.loadDocumentText(firstName);
        expect(text, isNotNull);
        final metrics = await second.metrics();
        expect(metrics.containerReads, greaterThan(0));
      } finally {
        second.dispose();
      }
    });
  });
}
