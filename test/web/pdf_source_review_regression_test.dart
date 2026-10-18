@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:unseal/src/platform/web/worker_client.dart';
import 'package:unseal/unseal.dart';
import '../support/held_pdf_byte_source.dart';
import '../support/pdf_range_review_fixture.dart';

void main() {
  tearDown(UnsealWorker.dispose);
  for (final worker in [false, true]) {
    test(
      '${worker ? 'real worker' : 'inline browser'} resumes filters and preserves first/reverse pages',
      () async {
        if (worker) {
          UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
          final probe = await WorkerClient.instance.sessionOpenSourceInWorker(
            HeldPdfByteSource(spacedPdfRangeFixture(indirectFilter: true)),
          );
          expect(probe, isNotNull, reason: 'this lane requires a real worker');
          WorkerClient.instance.sessionDisposeInWorker(probe!.sessionId);
        }
        final filtered = await BookSession.openSource(
          HeldPdfByteSource(spacedPdfRangeFixture(indirectFilter: true)),
        );
        addTearDown(filtered.dispose);
        expect(await filtered.loadDocumentText('page_1.html'), 'Hello indirect filter');
        final session = await BookSession.openSource(HeldPdfByteSource(spacedPdfRangeFixture()));
        addTearDown(session.dispose);
        expect(await session.loadDocumentText('page_22.html'), 'Content page V');
        expect(await session.loadDocumentText('page_21.html'), 'Content page U');
        expect(await session.loadDocumentText('page_1.html'), 'Content page A');
      },
    );
    test(
      '${worker ? 'real worker' : 'inline browser'} cancels an actual pending range and keeps peer',
      () async {
        if (worker) {
          UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
          final probe = await WorkerClient.instance.sessionOpenSourceInWorker(
            HeldPdfByteSource(spacedPdfRangeFixture(indirectFilter: true)),
          );
          expect(probe, isNotNull, reason: 'this lane requires a real worker');
          WorkerClient.instance.sessionDisposeInWorker(probe!.sessionId);
        }
        final source = HeldPdfByteSource(spacedPdfRangeFixture());
        final session = await BookSession.openSource(
          source,
          policy: const SessionPolicy(rangeRequestsInFlight: 2),
        );
        final peer = await BookSession.openSource(HeldPdfByteSource(spacedPdfRangeFixture()));
        addTearDown(peer.dispose);
        addTearDown(() {
          if (!source.release.isCompleted) source.release.complete();
          session.dispose();
        });
        source.holdNext = true;
        final pending = session.loadDocumentText('page_21.html');
        final cancelled = expectLater(pending, throwsA(isA<SessionCancelledException>()));
        await source.entered.future.timeout(const Duration(seconds: 5));
        session.cancelPending();
        await cancelled;
        expect(source.active, 1);
        expect(
          await session.loadDocumentText('page_22.html').timeout(const Duration(seconds: 5)),
          'Content page V',
        );
        expect(source.release.isCompleted, isFalse);
        expect(source.peak, lessThanOrEqualTo(2));
        expect(await peer.loadDocumentText('page_22.html'), 'Content page V');
        source.release.complete();
        expect(await session.loadDocumentText('page_21.html'), 'Content page U');
        session.dispose();
        final doomedSource = HeldPdfByteSource(spacedPdfRangeFixture());
        final doomed = await BookSession.openSource(doomedSource);
        doomedSource.holdNext = true;
        final abandoned = doomed.loadDocumentText('page_21.html');
        final closed = expectLater(abandoned, throwsA(isA<SessionClosedException>()));
        await doomedSource.entered.future.timeout(const Duration(seconds: 5));
        doomed.dispose();
        await closed;
        expect(doomedSource.closed, isTrue);
        doomedSource.release.complete();
        expect(await peer.loadDocumentText('page_1.html'), 'Content page A');
      },
    );
  }
}
