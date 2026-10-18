@TestOn('browser')
library;

import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/worker_client.dart';
import 'package:unseal/unseal.dart';

import '../../tool/rar5_stream_encoder.dart';
import '../support/rar_fixtures.dart';

/// The committed `rar5-hash-m3.cbr` — a real RAR 7.23 `-htb` archive
/// (SHA-256 fa2fb6138e26ca1cebe3f044e3d5bb51fbd43981580deab56634be95c46a82ec)
/// embedded as base64 because browser tests cannot read files. The D05
/// reference stage re-checks this embedding against the committed
/// fixture, so drift fails the gate instead of silently pinning stale
/// bytes.
const String _m3FixtureBase64 =
    'UmFyIRoHAQDz4YLrCwEFBwAGAQGAgIAAvblJI0cCAy6KAACKAKSDAoAAAQp6LXRpbnkuanBnIgIAaEgC'
    'y9Od8ip5Yv9ggeh7/lKif52LG7hT2qQh0W0Z5kQKAxND1NRq4C46Kf/Y/+AAAQID/9lJlQLHSwIDLuGA'
    'AACIggKkgwKAAwEMbS1tZWRpdW0uanBnIgIAcAfO3VE0ZNv9R6SzT4VJK9eUOksXrKQyjFreO2JbMbQKA'
    'xNW1NRq2zgnDsLGXjVVUj+TIEncLhcaj7tUdcbkJkRZBACA8gBAiLD5PaCSMCE/OY8cPcOzmFwAQCBB2o'
    'FcbLZ1AFq9NxsQdz3pnH4M7VvGfY1czK4ngLZ6ZluQd73nlWA0NWs79c+VEmAdd1ZRAwUEAA==';

Uint8List get _m3Fixture => Uint8List.fromList(convert.base64Decode(_m3FixtureBase64));

Uint8List _hashedFixture({final int corruptDigestIndex = -1}) => buildRar5Archive(
  entries: [FixtureEntry('a.jpg', tinyJpegPage), FixtureEntry('b.jpg', tinyJpegPage)],
  method: 3,
  dictExp: 0,
  blake2spHashes: true,
  corruptDigestIndex: corruptDigestIndex,
);

/// Proves the shared worker is live (never the inline fallback), the
/// same ritual as `session_pdf_cbr_worker_test.dart`.
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

  test('the real -htb corpus parses through the worker with verified digests', () async {
    final bytes = _m3Fixture;
    await _expectRealWorker(bytes);

    final book = await Unseal.read(bytes) as ComicBook;
    expect(book.pages.length, 2);
    final digests = {
      for (final page in book.pages) page.path: crypto.sha256.convert(page.content).toString(),
    };
    expect(
      digests['z-tiny.jpg'],
      '6367c1cf813d3e75e37bb7ab9da58d563c98f1ae28abd6227fa07b4b8d21ce4a',
    );
    expect(
      digests['m-medium.jpg'],
      '787b295e593265aed86aad646ddc7057da5f1ec515166efb091616f26a31c56a',
    );
  });

  test('the inline browser parse verifies the same digests', () {
    final book = parseComicBook(_m3Fixture);
    expect(book.pages.length, 2);
    for (final page in book.pages) {
      final expected = page.path == 'z-tiny.jpg'
          ? '6367c1cf813d3e75e37bb7ab9da58d563c98f1ae28abd6227fa07b4b8d21ce4a'
          : '787b295e593265aed86aad646ddc7057da5f1ec515166efb091616f26a31c56a';
      expect(crypto.sha256.convert(page.content).toString(), expected, reason: page.path);
    }
  });

  test('a corrupted digest rejects typed through the worker', () async {
    // Worker liveness is proven by the other tests; the corrupt archive
    // cannot open the probe session, so go straight to the read.
    final bytes = _hashedFixture(corruptDigestIndex: 1);
    await expectLater(
      Unseal.read(bytes),
      throwsA(
        isA<ComicException>().having(
          (final error) => error.toString(),
          'message',
          contains('fails its declared BLAKE2sp data hash'),
        ),
      ),
    );
  });

  test('a hash-carrying session verifies inside the worker', () async {
    final bytes = _hashedFixture();
    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);
    final pages = (session.book as ComicBook).pages;
    expect(pages.length, 2);
    final expected = crypto.sha256.convert(tinyJpegPage).toString();
    for (final page in pages) {
      final content = await session.loadResource(page.path);
      expect(content, isNotNull);
      expect(crypto.sha256.convert(content!).toString(), expected, reason: page.path);
    }
  });

  test('an archive without hash records keeps the absence contract', () async {
    final bytes = buildRar5Archive(
      entries: [FixtureEntry('a.jpg', tinyJpegPage)],
      method: 3,
      dictExp: 0,
    );
    final book = await Unseal.read(bytes) as ComicBook;
    expect(book.pages.length, 1);
  });
}
