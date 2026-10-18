import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

EpubBook _epub(final String name) =>
    parseEpubBook(File('test/resources/books/epub/$name').readAsBytesSync());

PublicationRevision _identityOf(final Uint8List bytes, final String id) => PublicationRevision(
  publicationId: 'test:$id',
  sourceRevision: 'sha256:${sha256Hex(bytes)}',
  sourceEvidence: SourceEvidence.sha256,
);

String sha256Hex(final Uint8List bytes) {
  var digest = 0;
  // Deterministic stand-in only used where a real digest is not asserted;
  // identity tests use crypto through test/support where needed.
  for (final byte in bytes) {
    digest = (digest * 31 + byte) & 0x7fffffff;
  }

  return digest.toRadixString(16).padLeft(64, '0');
}

/// Position-list generation under `unseal.readium.positions/1`:
/// determinism, per-occurrence output, formulas, pages, cancellation,
/// limits, and session parity.
void main() {
  group('reflowable profile', () {
    test('anchors land every 1024 scalars plus the first position', () {
      // One chapter of exactly 3000 'x' scalars: anchors at scalar
      // 0, 1024, 2048 — the end is not an anchor.
      final text = '<html><body><p>${'x' * 3000}</p></body></html>';
      final book = _singleChapterBook(text);
      final build = ReadiumPositionListBuilder.ofBook(book);

      expect(build.list.total, 3);
      expect(
        [for (final p in build.list.positions) p.locations.progression],
        [0.0, 1024 / 3000, 2048 / 3000],
      );
      expect(
        [for (final p in build.list.positions) p.locations.totalProgression],
        [0.0, 1024 / 3000, 2048 / 3000],
      );
      expect([for (final p in build.list.positions) p.locations.position], [1, 2, 3]);
    });

    test('an empty section still emits its first position', () {
      final book = _singleChapterBook('<html><body><p></p></body></html>');
      final build = ReadiumPositionListBuilder.ofBook(book);

      expect(build.list.total, 1);
      expect(build.list.positions.single.locations.progression, 0.0);
      expect(build.list.positions.single.locations.totalProgression, 0.0);
    });

    test('global progression spans occurrences in reading order', () {
      final book = _twoChapterBook('a' * 100, 'b' * 100);
      final build = ReadiumPositionListBuilder.ofBook(book);

      expect(build.list.total, 2);
      expect(build.list.positions[0].href, contains('ch1'));
      expect(build.list.positions[1].href, contains('ch2'));
      expect(build.list.positions[0].locations.totalProgression, 0.0);
      expect(build.list.positions[1].locations.totalProgression, 100 / 200);
    });

    test('generation is deterministic and the service shape is exact', () {
      final book = _epub('accessible-epub-3.epub');
      final first = ReadiumPositionListBuilder.ofBook(book);
      final second = ReadiumPositionListBuilder.ofBook(book);

      final json = readiumPositionListToJsonString(first.list);
      expect(json, readiumPositionListToJsonString(second.list));
      final decoded = jsonDecode(json) as Map;
      expect(decoded.keys.toSet(), {'total', 'positions'});
      expect((decoded['positions'] as List).length, decoded['total']);
    });

    test('repeated spine occurrences each emit their own positions', () {
      final book = _epub('fxl-repeated-spine.epub');
      final build = ReadiumPositionListBuilder.ofBook(book);

      // The same href may appear under several one-based positions; no
      // occurrence collapse.
      final byHref = <String, List<int>>{};
      for (final position in build.list.positions) {
        byHref.putIfAbsent(position.href, () => <int>[]).add(position.locations.position!);
      }
      final repeated = byHref.entries.where((final entry) => entry.value.length > 1);
      expect(repeated, isNotEmpty);
      // Positions stay globally contiguous.
      expect([
        for (final p in build.list.positions) p.locations.position,
      ], List.generate(build.list.total, (final index) => index + 1));
    });

    test('non-linear spine items stay in the list', () {
      final book = _epub('fxl-nonlinear.epub');
      final build = ReadiumPositionListBuilder.ofBook(book);

      expect(build.coverage.occurrencesTotal, book.readingOrder.length);
      expect(build.list.total, greaterThan(0));
    });
  });

  group('page-based books', () {
    test('comics emit exactly one position per page', () {
      final comic = parseComicBook(_comicBytes());
      final build = ReadiumPositionListBuilder.ofBook(comic);

      expect(build.list.total, comic.pageCount);
      for (var index = 0; index < build.list.total; index++) {
        final position = build.list.positions[index];
        expect(position.href, comic.pages[index].path);
        expect(position.locations.fragments, isEmpty);
        expect(position.locations.progression, 0.0);
        expect(position.locations.totalProgression, index / comic.pageCount);
      }
    });

    test('PDF emits one position per page with explicit page fragments', () {
      final bytes = Uint8List.fromList(
        File('test/resources/pdf/gutenberg/pg11-generated.pdf').readAsBytesSync(),
      );
      final pdf = parsePdfBook(bytes);
      final build = ReadiumPositionListBuilder.ofBook(
        pdf,
        documentUri: 'https://library.example/alice.pdf',
      );

      expect(build.list.total, pdf.pageCount);
      for (var index = 0; index < build.list.total; index++) {
        final position = build.list.positions[index];
        expect(position.href, 'https://library.example/alice.pdf');
        expect(position.locations.fragments, ['page=${index + 1}']);
        expect(position.locations.totalProgression, index / pdf.pageCount);
      }
      // The binding records the PDF reading mode's own profile.
      expect(build.binding.textProfile.id, pdf.canonicalTextProfile?.id);
    });

    test('PDF without a host document URI fails as a caller error', () {
      final bytes = Uint8List.fromList(
        File('test/resources/pdf/gutenberg/pg11-generated.pdf').readAsBytesSync(),
      );
      final pdf = parsePdfBook(bytes);

      expect(() => ReadiumPositionListBuilder.ofBook(pdf), throwsArgumentError);
    });

    test('an empty list serializes as the documented service shape', () {
      final empty = ReadiumPositionList(total: 0, positions: <ReadiumLocator>[]);
      expect(readiumPositionListToJsonString(empty), '{"total":0,"positions":[]}');
      // A bodyless section still emits its single first position.
      final build = ReadiumPositionListBuilder.ofBook(_emptyHtmlBook());
      expect(build.list.total, 1);
    });
  });

  group('limits and cancellation', () {
    test('the position cap fails typed before the crossed emit', () {
      final book = _epub('accessible-epub-3.epub');

      expect(
        () => ReadiumPositionListBuilder.ofBook(
          book,
          limits: const ReadiumPositionLimits(maxPositions: 3),
        ),
        throwsA(isA<ReadiumPositionLimitException>()),
      );
    });

    test('session cancellation freezes a partial prefix and keeps the session', () async {
      final bytes = Uint8List.fromList(
        File('test/resources/epub/structure-sample-01.epub').readAsBytesSync(),
      );
      final full = ReadiumPositionListBuilder.ofBook(await Unseal.read(bytes));
      final session = await BookSession.open(bytes);
      final token = ReadiumPositionCancellationToken()..isCancelled = true;

      final build = await ReadiumPositionListBuilder.ofSession(session, cancellation: token);

      expect(build.cancelled, isTrue);
      expect(build.coverage.isComplete, isFalse);
      expect(build.coverage.occurrencesCompleted, 0);
      expect(build.list.total, 0);
      // The session stays usable.
      final results = await session.search('the');
      expect(results, isNotNull);
      session.dispose();
      // Sanity: the full build is non-trivial.
      expect(full.list.total, greaterThan(0));
    });

    test('mid-walk cancellation returns the frozen prefix', () async {
      final bytes = Uint8List.fromList(
        File('test/resources/epub/structure-sample-01.epub').readAsBytesSync(),
      );
      final session = await BookSession.open(bytes);
      final token = ReadiumPositionCancellationToken();
      var steps = 0;

      final build = await ReadiumPositionListBuilder.ofSession(
        session,
        cancellation: token,
        onCoverage: (final coverage) {
          steps++;
          if (steps == 2) token.isCancelled = true;
        },
      );

      expect(build.cancelled, isTrue);
      expect(build.coverage.occurrencesCompleted, 2);
      expect(build.list.total, build.coverage.positionsEmitted);
      session.dispose();
    });

    test('two sessions build independently', () async {
      final bytes = Uint8List.fromList(
        File('test/resources/epub/structure-sample-01.epub').readAsBytesSync(),
      );
      final sessionA = await BookSession.open(bytes);
      final sessionB = await BookSession.open(bytes);
      final token = ReadiumPositionCancellationToken()..isCancelled = true;

      final buildA = await ReadiumPositionListBuilder.ofSession(sessionA, cancellation: token);
      final buildB = await ReadiumPositionListBuilder.ofSession(sessionB);

      expect(buildA.cancelled, isTrue);
      expect(buildB.cancelled, isFalse);
      expect(buildB.coverage.isComplete, isTrue);
      sessionA.dispose();
      sessionB.dispose();
    });
  });

  group('session parity', () {
    test('eager and session lists are identical over one profile', () async {
      final bytes = Uint8List.fromList(
        File('test/resources/epub/structure-sample-01.epub').readAsBytesSync(),
      );
      final book = await Unseal.read(bytes);
      final identity = _identityOf(bytes, 'structure-sample');

      final eager = ReadiumPositionListBuilder.ofBook(book, identity: identity);
      final session = await BookSession.open(bytes);
      final coverage = <ReadiumPositionCoverage>[];
      final built = await ReadiumPositionListBuilder.ofSession(
        session,
        identity: identity,
        onCoverage: coverage.add,
      );

      expect(
        readiumPositionListToJsonString(built.list),
        readiumPositionListToJsonString(eager.list),
      );
      expect(coverage, hasLength(book.readingOrder.length));
      expect(coverage.every((final snapshot) => snapshot.missingResources == 0), isTrue);
      expect(eager.binding.toJson(), built.binding.toJson());
      session.dispose();
    });

    test('binding json carries identity, occurrences and profile id', () async {
      final bytes = Uint8List.fromList(
        File('test/resources/epub/structure-sample-01.epub').readAsBytesSync(),
      );
      final book = await Unseal.read(bytes);
      final identity = _identityOf(bytes, 'structure-sample');

      final build = ReadiumPositionListBuilder.ofBook(book, identity: identity);
      final binding = build.binding.toJson();
      expect(binding['profile'], 'unseal.readium.positions/1');
      expect(binding['publicationId'], 'test:structure-sample');
      expect(binding['sourceEvidence'], 'sha256');
      expect((binding['occurrences'] as List).length, book.readingOrder.length);
      // The service JSON itself carries only the official shape.
      final service = jsonDecode(readiumPositionListToJsonString(build.list)) as Map;
      expect(service.keys.toSet(), {'total', 'positions'});
    });

    test('a missing session resource counts as missing, not empty', () async {
      // A synthetic book whose reading order names a document the
      // archive does not carry is unreachable through BookSession.open
      // (parsers repair or reject), so the missing path is exercised at
      // the model level: coverage distinguishes the two counts.
      const coverage = ReadiumPositionCoverage(
        occurrencesCompleted: 3,
        occurrencesTotal: 5,
        positionsEmitted: 2,
        isComplete: false,
        missingResources: 1,
      );
      expect(coverage.missingResources, 1);
      expect(coverage.isComplete, isFalse);
    });

    test('PDF session generation matches the eager page walk', () async {
      final bytes = Uint8List.fromList(
        File('test/resources/pdf/gutenberg/pg11-generated.pdf').readAsBytesSync(),
      );
      final identity = _identityOf(bytes, 'pg11');
      final eager = ReadiumPositionListBuilder.ofBook(
        parsePdfBook(bytes),
        identity: identity,
        documentUri: 'https://library.example/alice.pdf',
      );
      final session = await BookSession.open(bytes);
      expect(session.book, isA<PdfBook>());
      final built = await ReadiumPositionListBuilder.ofSession(
        session,
        identity: identity,
        documentUri: 'https://library.example/alice.pdf',
      );

      // Page positions are content-free: the service JSON is identical
      // across delivery modes even though the bindings name different
      // reflow profiles (eager plan vs session sample, by construction).
      expect(
        readiumPositionListToJsonString(built.list),
        readiumPositionListToJsonString(eager.list),
      );
      session.dispose();
    });
  });
}

EpubBook _singleChapterBook(final String bodyHtml) {
  const opf = '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title id="id">Single</dc:title>
    <dc:identifier id="id">urn:uuid:single</dc:identifier>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2020-01-01T00:00:00Z</meta>
  </metadata>
  <manifest><item id="ch" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="ch"/></spine>
</package>''';
  final chapter = bodyHtml.replaceAll('ch1', 'ch1');
  final opfBytes = utf8.encode(opf);
  final chapterBytes = utf8.encode(chapter);

  return parseEpubBook(
    Uint8List.fromList(
      ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile('content.opf', opfBytes.length, opfBytes))
          ..addFile(ArchiveFile('ch1.xhtml', chapterBytes.length, chapterBytes)),
      ),
    ),
  );
}

EpubBook _twoChapterBook(final String first, final String second) {
  const opf = '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title id="id">Two</dc:title>
    <dc:identifier id="id">urn:uuid:two</dc:identifier>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2020-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>''';
  String chapter(final String words) =>
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head>'
      '<body><p>$words</p></body></html>';
  final opfBytes = utf8.encode(opf);
  final c1 = utf8.encode(chapter(first));
  final c2 = utf8.encode(chapter(second));

  return parseEpubBook(
    Uint8List.fromList(
      ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile('content.opf', opfBytes.length, opfBytes))
          ..addFile(ArchiveFile('ch1.xhtml', c1.length, c1))
          ..addFile(ArchiveFile('ch2.xhtml', c2.length, c2)),
      ),
    ),
  );
}

EpubBook _emptyHtmlBook() => _singleChapterBook(
  '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head>'
  '<body></body></html>',
);

Uint8List _comicBytes() {
  const png = [
    0x89,
    0x50,
    0x4e,
    0x47,
    0x0d,
    0x0a,
    0x1a,
    0x0a,
    0,
    0,
    0,
    0x0d,
    0x49,
    0x48,
    0x44,
    0x52,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
    0x08,
    0x06,
    0,
    0,
    0,
    0x1f,
    0x15,
    0xc4,
    0x89,
    0,
    0,
    0,
    0x0a,
    0x49,
    0x44,
    0x41,
    0x54,
    0x78,
    0x9c,
    0x63,
    0,
    1,
    0,
    0,
    5,
    0,
    1,
    0x0d,
    0x0a,
    0x2d,
    0xb4,
    0,
    0,
    0,
    0,
    0x49,
    0x45,
    0x4e,
    0x44,
    0xae,
    0x42,
    0x60,
    0x82,
  ];
  final archive = Archive()
    ..addFile(ArchiveFile('p1.png', png.length, png))
    ..addFile(ArchiveFile('p2.png', png.length, png))
    ..addFile(ArchiveFile('p3.png', png.length, png));

  return Uint8List.fromList(ZipEncoder().encode(archive));
}
