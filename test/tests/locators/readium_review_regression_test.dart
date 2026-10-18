import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

Uint8List _twoChapters() {
  final archive = Archive();
  void add(String path, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('META-INF/container.xml', '''<container><rootfiles>
<rootfile full-path="book.opf"/></rootfiles></container>''');
  add('book.opf', '''<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Review</dc:title></metadata>
<manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
<item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="a"/><itemref idref="b"/></spine></package>''');
  for (final name in ['a', 'b']) {
    add(
      '$name.xhtml',
      '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>${'text ' * 600}</p></body></html>',
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test('PDF imports require the matching host document URI in eager and session modes', () async {
    final bytes = File('test/resources/pdf/gutenberg/pg11-generated.pdf').readAsBytesSync();
    final book = parsePdfBook(bytes);
    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);
    final locator = ReadiumLocator(
      href: 'host:book.pdf',
      type: 'application/pdf',
      locations: ReadiumLocations(fragments: ['page=1']),
    );
    expect(book.toBookLocator(locator), isA<ReadiumUnsupported<BookLocator>>());
    expect(
      book.toBookLocator(locator, documentUri: 'host:other.pdf'),
      isA<ReadiumUnsupported<BookLocator>>(),
    );
    expect(
      book.toBookLocator(locator, documentUri: locator.href),
      isA<ReadiumExact<BookLocator>>(),
    );
    expect(await session.toBookLocator(locator), isA<ReadiumUnsupported<BookLocator>>());
    expect(
      await session.toBookLocator(locator, documentUri: 'host:other.pdf'),
      isA<ReadiumUnsupported<BookLocator>>(),
    );
    expect(
      await session.toBookLocator(locator, documentUri: locator.href),
      isA<ReadiumExact<BookLocator>>(),
    );
  });

  test('a resolved CFI cannot override the href or occurrence hint', () async {
    final bytes = _twoChapters();
    final book = parseEpubBook(bytes);
    final cfi =
        (book.toReadiumLocator(const TextLocator(sectionIndex: 1, start: 3, end: 3))
                as ReadiumExact<ReadiumLocator>)
            .locator
            .locations
            .fragments
            .single;
    final locator = ReadiumLocator(
      href: 'a.xhtml',
      type: 'application/xhtml+xml',
      locations: ReadiumLocations(fragments: [cfi]),
    );
    expect(book.toBookLocator(locator), isA<ReadiumUnsupported<BookLocator>>());
    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);
    final direct = await session.toReadiumLocator(CfiLocator(cfi));
    expect(direct, isA<ReadiumExact<ReadiumLocator>>());
    expect((direct as ReadiumExact<ReadiumLocator>).locator.href, 'b.xhtml');
    expect(direct.locator.locations.fragments, [cfi]);
    expect(await session.toBookLocator(locator), isA<ReadiumUnsupported<BookLocator>>());
    expect(
      await session.toBookLocator(
        ReadiumLocator(href: 'a.xhtml', type: 'application/xhtml+xml'),
        occurrenceHint: 1,
      ),
      isA<ReadiumUnsupported<BookLocator>>(),
    );
  });

  test('string locator decoding applies the supplied semantic limits', () {
    expect(
      () => readiumLocatorFromJson(
        '{"href":"a","type":"text/plain","locations":{"fragments":["a","b"]}}',
        limits: const ReadiumLocatorLimits(maxFragments: 1),
      ),
      throwsA(isA<ReadiumLocatorLimitException>()),
    );
    expect(
      () => readiumLocatorFromJson(
        '{"href":"a","type":"text/plain","text":{"highlight":"long"}}',
        limits: const ReadiumLocatorLimits(maxTextContextLength: 2),
      ),
      throwsA(isA<ReadiumLocatorLimitException>()),
    );
  });

  test('anchor storage and cumulative text scans respect their budgets', () async {
    expect(
      () => ReadiumPositionProfile.v1.anchorUtf16Offsets(
        'a' * 3000,
        limits: const ReadiumPositionLimits(maxPositions: 1),
      ),
      throwsA(isA<ReadiumPositionLimitException>()),
    );
    final bytes = _twoChapters();
    final book = parseEpubBook(bytes);
    const limits = ReadiumPositionLimits(maxTextCodeUnits: 4000);
    expect(
      () => ReadiumPositionListBuilder.ofBook(book, limits: limits),
      throwsA(isA<ReadiumPositionLimitException>()),
    );
    final session = await BookSession.open(bytes);
    addTearDown(session.dispose);
    await expectLater(
      ReadiumPositionListBuilder.ofSession(session, limits: limits),
      throwsA(isA<ReadiumPositionLimitException>()),
    );
  });

  test('a host-extended reading order cannot certify missing session text', () async {
    final session = await BookSession.open(_twoChapters());
    addTearDown(session.dispose);
    (session.book as EpubBook).spinePaths!.add('missing.xhtml');
    final coverage = <ReadiumPositionCoverage>[];
    final result = await ReadiumPositionListBuilder.ofSession(session, onCoverage: coverage.add);
    expect(result.coverage.missingResources, 1);
    expect(result.coverage.isComplete, isFalse);
    expect(result.list.total, 6);
    expect(coverage.last.positionsEmitted, 6);
    expect(coverage.last.isComplete, isFalse);
  });

  test('coverage callbacks report positions after the occurrence was emitted', () async {
    final session = await BookSession.open(_twoChapters());
    addTearDown(session.dispose);
    final coverage = <ReadiumPositionCoverage>[];
    final result = await ReadiumPositionListBuilder.ofSession(session, onCoverage: coverage.add);
    expect(coverage.first.positionsEmitted, 3);
    expect(coverage.last.positionsEmitted, result.list.total);
    expect(coverage.last.isComplete, isTrue);
  });
}
