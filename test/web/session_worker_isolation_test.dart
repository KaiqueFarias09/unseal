@TestOn('browser')
library;

import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/worker_client.dart';
import 'package:unseal/unseal.dart';

Uint8List _utf8(final String value) => Uint8List.fromList(convert.utf8.encode(value));

Uint8List _epub(final String title, final String paragraph) {
  final archive = Archive();
  final mimetype = ArchiveFile('mimetype', 20, _utf8('application/epub+zip'))
    ..compression = CompressionType.none;
  archive.addFile(mimetype);
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
  final chapter = _utf8('''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body><p>$paragraph</p></body></html>''');
  archive.addFile(ArchiveFile('chapter.xhtml', chapter.length, chapter));

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  setUp(() {
    // The Chrome lane builds this worker before running test/web/.
    UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
  });

  tearDown(UnsealWorker.dispose);

  test('two open sessions continue to address their own books', () async {
    final workerProbe = await WorkerClient.instance.sessionOpenInWorker(
      _epub('Worker probe', 'verify the real worker is active'),
    );
    expect(
      workerProbe,
      isNotNull,
      reason: 'this integration test must exercise the real Web Worker',
    );
    WorkerClient.instance.sessionDisposeInWorker(workerProbe!.sessionId);

    final a = await BookSession.open(_epub('Book A', 'alpha session content'));
    addTearDown(a.dispose);
    final b = await BookSession.open(_epub('Book B', 'bravo session content'));
    addTearDown(b.dispose);

    expect(a.book.metadata.title, 'Book A');
    expect(b.book.metadata.title, 'Book B');
    expect(await a.loadDocumentText(a.book.readingOrder.single.name), 'alpha session content');
    expect(await b.loadDocumentText(b.book.readingOrder.single.name), 'bravo session content');
  });

  test('disposing one session leaves the other worker session alive', () async {
    final workerProbe = await WorkerClient.instance.sessionOpenInWorker(
      _epub('Worker probe', 'verify the real worker is active'),
    );
    expect(
      workerProbe,
      isNotNull,
      reason: 'this integration test must exercise the real Web Worker',
    );
    WorkerClient.instance.sessionDisposeInWorker(workerProbe!.sessionId);

    final a = await BookSession.open(_epub('Book A', 'alpha session content'));
    final b = await BookSession.open(_epub('Book B', 'bravo session content'));
    addTearDown(b.dispose);

    a.dispose();

    expect(await b.loadDocumentText(b.book.readingOrder.single.name), 'bravo session content');
  });
}
