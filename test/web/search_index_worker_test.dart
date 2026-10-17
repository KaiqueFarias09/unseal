@TestOn('browser')
library;

import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/worker_client.dart';
import 'package:unseal/unseal.dart';

import '../support/indexed_pdf_fixture.dart';

Uint8List _utf8(final String value) => Uint8List.fromList(convert.utf8.encode(value));

/// A small EPUB whose sections carry the acceptance corpus: accented
/// Portuguese, an astral word, a soft-hyphen-split word, and repeated
/// paths are exercised in the suites that build them; here the spine
/// holds two distinct sections plus a duplicate path occurrence.
Uint8List _corpusEpub() {
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
  <metadata><dc:identifier id="uid">urn:uuid:unicode</dc:identifier><dc:title>Unicode</dc:title><dc:language>pt</dc:language></metadata>
  <manifest>
    <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
    <item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="a"/><itemref idref="b"/></spine>
</package>''');
  archive.addFile(ArchiveFile('content.opf', package.length, package));
  final sectionA = _utf8(
    '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body><p>A navegação do leitor e o navio&#x1F6A2; veloz.</p></body></html>''',
  );
  archive.addFile(ArchiveFile('a.xhtml', sectionA.length, sectionA));
  final sectionB = _utf8(
    '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body><p>Corre&#x00AD;ção de texto e feitiço.</p></body></html>''',
  );
  archive.addFile(ArchiveFile('b.xhtml', sectionB.length, sectionB));

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  setUp(() {
    // The Chrome lane builds this worker before running test/web/.
    UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
  });

  tearDown(UnsealWorker.dispose);

  test('PDF worker indexes reopen in the same mode and reject eager mode payloads', () async {
    final bytes = indexedPdfFixture();
    final probe = await WorkerClient.instance.sessionOpenInWorker(bytes);
    expect(probe, isNotNull, reason: 'PDF persistence must run through the real worker');
    WorkerClient.instance.sessionDisposeInWorker(probe!.sessionId);

    final eager = await Unseal.read(bytes) as PdfBook;
    expect(eager.canonicalTextProfile!.options['scope'], 'document');
    final eagerIndex = await BookSearchIndex.build(eager);
    final eagerPayload = eagerIndex.serialize();
    final eagerReopened = await Unseal.read(bytes);
    expect(
      BookSearchIndex.deserialize(eagerPayload, book: eagerReopened).query('needle').hits,
      hasLength(22),
    );

    final source = await BookSession.open(bytes);
    final target = await BookSession.open(bytes);
    addTearDown(source.dispose);
    addTearDown(target.dispose);
    final sessionBook = source.book as PdfBook;
    expect(sessionBook.canonicalTextProfile!.options['scope'], 'session-sample');
    expect(sessionBook.canonicalTextProfile!.id, isNot(eager.canonicalTextProfile!.id));
    expect(await source.loadDocumentText('page_1.html'), documentTextOf(eager.files.html.first));

    await source.buildSearchIndex();
    final payload = await source.exportSearchIndex();
    await target.importSearchIndex(payload);
    expect((await target.searchIndexed('needle')).hits, hasLength(22));
    await expectLater(
      target.importSearchIndex(eagerPayload),
      throwsA(isA<SearchIndexIncompatibleException>()),
    );
    expect(
      () => BookSearchIndex.deserialize(payload, book: eager),
      throwsA(isA<SearchIndexIncompatibleException>()),
    );
    expect((await target.searchIndexed('needle')).hits, hasLength(22));
  });

  test('the indexed search runs inside the real worker', () async {
    final probe = await WorkerClient.instance.sessionOpenInWorker(_corpusEpub());
    expect(probe, isNotNull, reason: 'this integration test must exercise the real Web Worker');
    WorkerClient.instance.sessionDisposeInWorker(probe!.sessionId);

    final session = await BookSession.open(_corpusEpub());
    addTearDown(session.dispose);

    final coverage = await session.buildSearchIndex(sectionsPerBatch: 1);
    expect(coverage.isComplete, isTrue);
    expect(coverage.indexedSections, 2);

    // Unaccented query finds the accented text; the hit cuts the
    // original range.
    final results = await session.searchIndexed('navegacao');
    expect(results.hits, hasLength(1));
    final text = await session.loadDocumentText(results.hits.single.sectionName);
    expect(text!.substring(results.hits.single.start, results.hits.single.end), 'navegação');

    // Prefix inside the worker.
    final prefix = await session.searchIndexed('nave', mode: IndexedQueryMode.prefix);
    expect(prefix.hits, hasLength(1));

    // The astral word: one token, original range spanning both
    // surrogate pairs of the emoji.
    final astral = await session.searchIndexed('navio🚢');
    expect(astral.hits, hasLength(1));
    expect(text.substring(astral.hits.single.start, astral.hits.single.end), 'navio🚢');
    expect(astral.hits.single.end - astral.hits.single.start, 'navio🚢'.length);

    // Soft-hyphen join: the query folds to the term the scanner cut
    // around the ignorable U+00AD.
    final hyphen = await session.searchIndexed('correcao');
    expect(hyphen.hits, hasLength(1));
    expect(hyphen.hits.single.sectionName, 'b.xhtml');
    final sectionB = await session.loadDocumentText('b.xhtml');
    expect(sectionB!.substring(hyphen.hits.single.start, hyphen.hits.single.end), 'Corre­ção');
  });

  test('digest vectors computed in Chrome match the fixed values', () async {
    // The C02 revision vectors must be byte-identical on the web.
    expect(
      textRevisionOf('abc'),
      'sha256:13e228567e8249fce53337f25d7970de3bd68ab2653424c7b8f9fd05e33caedf',
    );
    expect(
      readingOrderRevisionOf([
        const ReadingOrderItem(name: 'cap1.html', isHtml: true),
        const ReadingOrderItem(name: 'page1.html', isHtml: false),
      ]),
      'sha256:c51a9bd78f25cfdc73dd96e1b94abdb62d62179030409e39047a294fcd7f6529',
    );
  });

  test('export from one worker session imports into another', () async {
    final source = await BookSession.open(_corpusEpub());
    addTearDown(source.dispose);
    await source.buildSearchIndex();
    final payload = await source.exportSearchIndex();

    final target = await BookSession.open(_corpusEpub());
    addTearDown(target.dispose);
    final coverage = await target.importSearchIndex(payload);
    expect(coverage.isComplete, isTrue);

    final expected = await source.searchIndexed('navegacao');
    final actual = await target.searchIndexed('navegacao');
    expect(actual.hits.single.sectionName, expected.hits.single.sectionName);
    expect(actual.hits.single.start, expected.hits.single.start);
    expect(actual.hits.single.end, expected.hits.single.end);
    // Scores survive the wire within double rounding.
    expect((actual.hits.single.score - expected.hits.single.score).abs(), lessThan(1e-12));
  });

  test('typed index failures cross the worker wire', () async {
    final session = await BookSession.open(_corpusEpub());
    addTearDown(session.dispose);

    // No resident index: typed base failure.
    await expectLater(session.searchIndexed('navegacao'), throwsA(isA<SearchIndexException>()));

    // A corrupted payload keeps its incompatible type across the wire.
    await session.buildSearchIndex();
    final payload = await session.exportSearchIndex();
    final broken = <String, Object?>{...payload, 'schemaVersion': 42};
    await expectLater(
      session.importSearchIndex(broken),
      throwsA(isA<SearchIndexIncompatibleException>()),
    );
  });
}
