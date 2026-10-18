import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:unseal/src/features/progressive/byte_source_gate.dart';
import 'package:unseal/src/features/progressive/pdf_range_loader.dart';
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/src/features/progressive/transport/session_transport.dart';
import 'package:unseal/src/foundation/archive/async_byte_reader.dart';
import 'package:unseal/unseal.dart';
import '../../support/held_pdf_byte_source.dart';
import '../../support/pdf_range_review_fixture.dart';

void main() {
  test('indirect stream filter resumes instead of silently skipping page text', () async {
    final source = HeldPdfByteSource(spacedPdfRangeFixture(indirectFilter: true));
    final remote = await BookSession.openSource(source);
    final local = await BookSession.open(source.bytes);
    addTearDown(remote.dispose);
    addTearDown(local.dispose);
    expect(await local.loadDocumentText('page_1.html'), 'Hello indirect filter');
    expect(await remote.loadDocumentText('page_1.html'), 'Hello indirect filter');
  });
  for (final inline in [false, true]) {
    test(
      '${inline ? 'inline' : 'isolate'} cancellation unblocks uncached page before old reply',
      () async {
        final source = HeldPdfByteSource(spacedPdfRangeFixture());
        const policy = SessionPolicy(rangeRequestsInFlight: 2);
        late Future<String?> Function(String) read;
        late void Function() cancel;
        late void Function() dispose;
        if (inline) {
          final gate = ByteSourceGate(source, policy: policy);
          final engine = await SessionEngine.openRemote(
            CallbackAsyncByteReader(
              length: source.length,
              revision: source.revision,
              read: (final offset, final count) =>
                  gate.read(offset, count, expectedRevision: source.revision),
            ),
            policy: policy,
          );
          final transport = InlineSourceSessionTransport(engine, gate);
          read = transport.documentText;
          cancel = transport.cancelPending;
          dispose = transport.dispose;
        } else {
          final session = await BookSession.openSource(source, policy: policy);
          read = session.loadDocumentText;
          cancel = session.cancelPending;
          dispose = session.dispose;
        }
        addTearDown(() {
          if (!source.release.isCompleted) source.release.complete();
          dispose();
        });
        source.holdNext = true;
        final pending = read('page_21.html');
        final cancelled = expectLater(pending, throwsA(isA<SessionCancelledException>()));
        await source.entered.future.timeout(const Duration(seconds: 5));
        cancel();
        await cancelled;
        expect(source.active, 1, reason: 'the cancelled physical host request has not replied');
        expect(await read('page_22.html').timeout(const Duration(seconds: 5)), 'Content page V');
        expect(source.release.isCompleted, isFalse);
        expect(source.peak, lessThanOrEqualTo(2));
        source.release.complete();
        expect(await read('page_21.html'), 'Content page U');
      },
    );
  }
  test('loader cancellation also handles a range not yet cancelled by its transport', () async {
    final held = Completer<Uint8List>();
    final entered = Completer<void>();
    final loader = PdfRangeLoader(
      length: 1024,
      readRange: (final offset, final count) {
        if (offset == 0) {
          entered.complete();
          return held.future;
        }
        return Future<Uint8List>.value(Uint8List(count));
      },
    );
    final pending = loader.drive(() => loader.read(0, 10));
    final cancelled = expectLater(pending, throwsA(isA<SessionCancelledException>()));
    await entered.future;
    loader.cancelPending();
    await cancelled;
    expect(await loader.drive(() => loader.read(10, 10)), hasLength(10));
    held.complete(Uint8List(10));
    await Future<void>.delayed(Duration.zero);
    expect(loader.residentBytes, 10, reason: 'the cancelled late answer never enters the cache');
    expect(loader.fetchedBytes, 20, reason: 'late physical responses still count');
    await loader.close();
  });
  test('a late host reply after close never recreates cache or interval ledger', () async {
    final held = Completer<Uint8List>();
    final entered = Completer<void>();
    final loader = PdfRangeLoader(
      length: 1024,
      readRange: (final offset, final count) {
        entered.complete();
        return held.future;
      },
    );
    final pending = loader.drive(() => loader.read(0, 10));
    final closed = expectLater(pending, throwsA(isA<ByteSourceClosedException>()));
    await entered.future;
    await loader.close();
    await closed;
    held.complete(Uint8List(10));
    await Future<void>.delayed(Duration.zero);
    expect(loader.coverage(), isEmpty);
    expect(loader.residentBytes, 0);
    expect(loader.fetchedBytes, 10);
  });
  test('cancelled physical reads retain their host budget until the reply', () async {
    final source = HeldPdfByteSource(spacedPdfRangeFixture())..holdNext = true;
    final gate = ByteSourceGate(source, policy: const SessionPolicy(rangeRequestsInFlight: 1));
    final pending = gate.read(0, 32);
    final cancelled = expectLater(pending, throwsA(isA<SessionCancelledException>()));
    await source.entered.future;
    gate.cancelPending();
    await cancelled;
    final next = gate.read(32, 32);
    expect(gate.inFlightRequests, 1);
    expect(gate.queuedRequests, 1);
    source.release.complete();
    expect(await next, hasLength(32));
    expect(source.peak, 1);
    await gate.close();
  });
  test('read cap is checked before requesting or allocating a huge virtual range', () async {
    var fetched = false;
    final loader = PdfRangeLoader(
      length: 1 << 40,
      policy: const SessionPolicy(rangeRequestBytes: 96 << 10),
      readRange: (final _, final _) async {
        fetched = true;
        throw StateError('must not fetch');
      },
    );
    await expectLater(
      loader.drive(() => loader.read(0, 1 << 39)),
      throwsA(isA<ByteSourceLimitExceededException>()),
    );
    expect(fetched, isFalse);
    expect(loader.residentBytes, 0);
  });
  test(
    'pinned step budget fails before requesting excess bytes and cleans up on failure',
    () async {
      final loader = PdfRangeLoader(
        length: 4 << 20,
        policy: const SessionPolicy(cacheBytes: 1 << 20, rangeRequestBytes: 512 << 10),
        readRange: (final offset, final count) async => Uint8List(count),
      );
      // Use a synthetic, bounded responder; no PDF parsing is involved here.
      await expectLater(
        loader.drive(() {
          for (var offset = 0; offset < 2 << 20; offset += 512 << 10) {
            loader.read(offset, 512 << 10);
          }
        }),
        throwsA(isA<ByteSourceLimitExceededException>()),
      );
      expect(loader.fetchCount, 2);
      expect(loader.maxResidentBytes, lessThanOrEqualTo(1 << 20));
      expect(loader.residentBytes, lessThanOrEqualTo(1 << 20));
      expect(loader.coverage(), [(0, 1 << 20)]);
      await loader.close();
      expect(loader.coverage(), isEmpty);
      expect(loader.residentBytes, 0);
    },
  );
}
