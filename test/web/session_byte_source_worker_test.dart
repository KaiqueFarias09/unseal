@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/worker_client.dart';
import 'package:unseal/unseal.dart';

Uint8List _utf8(final String value) => Uint8List.fromList(convert.utf8.encode(value));

Uint8List _epub(final String title, final String paragraph) {
  final archive = Archive();
  archive.addFile(
    ArchiveFile('mimetype', 20, _utf8('application/epub+zip'))..compression = CompressionType.none,
  );
  final container = _utf8('''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
  archive.addFile(ArchiveFile('META-INF/container.xml', container.length, container));
  final package = _utf8('''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    version="3.0" unique-identifier="uid">
  <metadata><dc:identifier id="uid">urn:uuid:$title</dc:identifier><dc:title>$title</dc:title><dc:language>en</dc:language></metadata>
  <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="chapter"/></spine>
</package>''');
  archive.addFile(ArchiveFile('content.opf', package.length, package));
  final chapter = _utf8(
    '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>$paragraph</p></body></html>',
  );
  archive.addFile(ArchiveFile('chapter.xhtml', chapter.length, chapter));

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _cbz(final List<String> pages) {
  final archive = Archive();
  for (var i = 0; i < pages.length; i++) {
    final png = Uint8List(96);
    // Full PNG signature so the session's sniffer classifies the page.
    png.setAll(0, <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    archive.addFile(ArchiveFile('page-${i + 1}.png', png.length, png));
  }

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// The main-thread source the worker's byteSource.v1 requests hit.
/// It records every range so the partial-reading assertion runs on the
/// browser too, and it can delay answers to prove late replies serve
/// nobody.
final class RecordingByteSource implements UnsealByteSource {
  RecordingByteSource(this.bytes, {this.revision, this.delay = Duration.zero});

  final Uint8List bytes;
  @override
  final String? revision;
  final Duration delay;
  var _closed = false;
  final List<({int offset, int count})> reads = <({int offset, int count})>[];

  bool get closed => _closed;
  int get totalBytesRequested => reads.fold(0, (final total, final read) => total + read.count);

  @override
  int get length => bytes.length;

  @override
  Future<Uint8List> readRange(final int offset, final int count) async {
    if (_closed) throw const ByteSourceClosedException();
    RangeError.checkValidRange(offset, offset + count, bytes.length, 'offset', 'end');
    reads.add((offset: offset, count: count));
    if (delay > Duration.zero) await Future<void>.delayed(delay);

    return Uint8List.sublistView(bytes, offset, offset + count);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

void main() {
  setUp(() {
    // The Chrome lane builds this worker before running test/web/.
    UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
  });

  tearDown(UnsealWorker.dispose);

  test('two source sessions run in the real worker without exchanging bytes', () async {
    final a = RecordingByteSource(
      _epub('Source A', 'alpha byte-range content'),
      revision: 'a-1',
      delay: const Duration(milliseconds: 2),
    );
    final b = RecordingByteSource(
      _epub('Source B', 'bravo byte-range content'),
      revision: 'b-1',
      delay: const Duration(milliseconds: 2),
    );

    final sessionA = await BookSession.openSource(a);
    final sessionB = await BookSession.openSource(b);
    addTearDown(sessionA.dispose);
    addTearDown(sessionB.dispose);

    expect(sessionA.book.metadata.title, 'Source A');
    expect(sessionB.book.metadata.title, 'Source B');
    expect(sessionA.sourceRevision, 'a-1');
    expect(sessionB.sourceRevision, 'b-1');

    final pathA = sessionA.book.readingOrder.first.name;
    final pathB = sessionB.book.readingOrder.first.name;
    final interleaved = await Future.wait([
      sessionA.loadDocumentText(pathA),
      sessionB.loadDocumentText(pathB),
      sessionA.loadDocumentText(pathA),
    ]);
    expect(interleaved[0], interleaved[2], reason: 'same session, same text');
    expect(interleaved[0], contains('alpha byte-range content'));
    expect(interleaved[1], contains('bravo byte-range content'));

    expect(a.reads, isNotEmpty, reason: 'the worker pulled ranges from source A');
    expect(b.reads, isNotEmpty, reason: 'the worker pulled ranges from source B');
  });

  test('a CBZ session over a source loads pages through the worker bridge', () async {
    final source = RecordingByteSource(_cbz(['p1', 'p2', 'p3']));
    final session = await BookSession.openSource(source);
    addTearDown(session.dispose);

    final header = session.book as ComicBook;
    expect(header.pageCount, 3);
    final page = await session.loadResource(header.pages.first.path);
    expect(page, isNotNull);
    expect(page!.length, 96);
    // A 700-byte toy container: the bound just proves no bulk copy —
    // per-entry sniff windows plus one page payload.
    expect(source.totalBytesRequested, lessThan(source.bytes.length * 4));
  });

  test('disposing one source session leaves the other live and closes its source', () async {
    final a = RecordingByteSource(_epub('Dispose A', 'doomed content'));
    final b = RecordingByteSource(
      _epub('Survivor B', 'surviving content'),
      delay: const Duration(milliseconds: 2),
    );
    final sessionA = await BookSession.openSource(a);
    final sessionB = await BookSession.openSource(b);
    addTearDown(sessionB.dispose);

    final pathA = sessionA.book.readingOrder.first.name;
    final inFlightA = sessionA.loadDocumentText(pathA);
    sessionA.dispose();
    await expectLater(inFlightA, throwsA(isA<UnsealException>()));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(a.closed, isTrue, reason: 'dispose closed the host source through the gate');

    final pathB = sessionB.book.readingOrder.first.name;
    expect(await sessionB.loadDocumentText(pathB), contains('surviving content'));

    // The dead session stays dead; its replies serve nobody.
    await expectLater(sessionA.loadResource(pathA), throwsA(isA<SessionClosedException>()));
  });

  test('a source refusal crosses the bridge typed in the browser', () async {
    // A PDF through a source is refused before any bridge traffic.
    await expectLater(
      BookSession.openSource(
        RecordingByteSource(
          Uint8List.fromList(<int>[0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34]),
        ),
      ),
      throwsA(
        isA<SessionUnsupportedFormatException>().having(
          (final error) => error.message,
          'message',
          contains('PDF'),
        ),
      ),
    );
  });

  test('worker probe: the source path really rides the worker', () async {
    final source = RecordingByteSource(_epub('Worker probe', 'verify the real worker is active'));
    final opened = await WorkerClient.instance.sessionOpenSourceInWorker(source);
    expect(opened, isNotNull, reason: 'this integration test must exercise the real Web Worker');
    WorkerClient.instance.sessionDisposeInWorker(opened!.sessionId);
  });
}
