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

/// The Readium interchange corpus and position-list generation run on
/// Chrome with the real Web Worker backing the session: the corpus cases
/// mirror `tool/readium/corpus/locator-cases.json` (whose expectations
/// the official toolkit produced), and the session walks the worker
/// transport step by step.
void main() {
  setUp(() {
    UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
  });

  tearDown(UnsealWorker.dispose);

  test('the real worker serves the session', () async {
    final probe = await WorkerClient.instance.sessionOpenInWorker(
      _epub('Readium probe', 'verify the real worker is active'),
    );
    expect(probe, isNotNull, reason: 'this test must exercise the real worker');
    WorkerClient.instance.sessionDisposeInWorker(probe!.sessionId);
  });

  test('locator interchange follows the toolkit over the corpus', () {
    // Example 1 of the official spec, expectations produced by executing
    // @readium/shared 2.8.0 (see build evidence reference.json).
    final example1 = tryDecodeReadiumLocator({
      'href': 'http://example.com/chapter1',
      'type': 'text/html',
      'title': 'Chapter 1',
      'locations': {'position': 4, 'progression': 0.03401, 'totalProgression': 0.01349},
      'text': {'after': 'It is a truth universally acknowledged'},
    });
    expect(example1, isNotNull);
    expect(example1!.locations.position, 4);
    final encoded = example1.serialize();
    expect(encoded['href'], 'http://example.com/chapter1');
    expect((encoded['locations'] as Map)['position'], 4);

    // Toolkit refusals and tolerances hold on the web.
    expect(tryDecodeReadiumLocator({'type': 'text/html'}), isNull);
    final legacy = tryDecodeReadiumLocator({
      'href': 'c.xhtml',
      'type': 'application/xhtml+xml',
      'locations': {'fragment': 'partialcfi(/4[body01])'},
    });
    expect(legacy!.locations.fragments, ['partialcfi(/4[body01])']);
    final split = tryDecodeReadiumLocator({
      'href': 'c.xhtml#frag',
      'type': 'application/xhtml+xml',
    });
    expect(split!.href, 'c.xhtml');
    expect(split.locations.fragments, ['frag']);
  });

  test('position lists generate over the worker session with parity', () async {
    final paragraph = 'x' * 3000; // two anchor boundaries inside one section
    final bytes = _epub('Web positions', paragraph);

    final eager = ReadiumPositionListBuilder.ofBook(parseEpubBook(bytes));
    expect(eager.list.total, 3);

    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);
    final coverage = <ReadiumPositionCoverage>[];
    final built = await ReadiumPositionListBuilder.ofSession(session, onCoverage: coverage.add);

    expect(built.cancelled, isFalse);
    expect(coverage.last.isComplete, isTrue);
    expect(coverage.last.positionsEmitted, built.list.total);
    expect(
      readiumPositionListToJsonString(built.list),
      readiumPositionListToJsonString(eager.list),
    );
    expect(built.list.positions.last.locations.position, 3);
  });

  test('session conversion confirms CFI through the worker', () async {
    final bytes = _epub('Web conversion', 'some words to locate here');
    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);

    final text = await session.loadDocumentText('chapter.xhtml');
    expect(text, isNotNull);
    final offset = text!.indexOf('words');

    final outcome = await session.toReadiumLocator(
      TextLocator(sectionIndex: 0, start: offset, end: offset),
    );
    expect(outcome, isA<ReadiumExact<ReadiumLocator>>());
    final locator = (outcome as ReadiumExact<ReadiumLocator>).locator;
    expect(locator.href, 'chapter.xhtml');
    expect(locator.locations.fragments.single, startsWith('epubcfi('));

    final foreignOccurrence = await session.toBookLocator(locator, occurrenceHint: 1);
    expect(foreignOccurrence, isA<ReadiumUnsupported<BookLocator>>());
    final back = await session.toBookLocator(locator);
    expect(back, isA<ReadiumExact<BookLocator>>());
    expect(((back as ReadiumExact<BookLocator>).locator as TextLocator).start, offset);
  });

  test('session cancellation keeps the worker session usable', () async {
    final bytes = _epub('Web cancellation', 'cancel between steps');
    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);
    final token = ReadiumPositionCancellationToken()..isCancelled = true;

    final build = await ReadiumPositionListBuilder.ofSession(session, cancellation: token);
    expect(build.cancelled, isTrue);
    expect(build.coverage.isComplete, isFalse);

    final results = await session.search('cancel');
    expect(results.matches, isNotEmpty);
  });
}
