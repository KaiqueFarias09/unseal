import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/unseal.dart';

import '../../support/rar_fixtures.dart' show tinyJpegPage;
import '../pdf/pdf_fixture_builder.dart';

Uint8List _bytes(final String name) =>
    Uint8List.fromList(File('test/resources/$name').readAsBytesSync());

/// The eager reference of [bytes]: the whole parse the session must
/// behave like.
PdfBook _eager(final Uint8List bytes) => Unseal.parse(bytes) as PdfBook;

void main() {
  // Every gutenberg fixture exceeds the 20-page sample bound; the
  // byte-parity documents are generated in-test (≤ 20 pages, where
  // the sampled plan IS the full plan).
  final eightPages = Uint8List.fromList(
    multipageTextFixture(pageCount: 8, withHeaderFooter: true).build(),
  );
  final continuationPages = Uint8List.fromList(continuationPagesFixture().build());
  final fourHundredPages = Uint8List.fromList(
    multipageTextFixture(pageCount: 400, withHeaderFooter: true).build(),
  );
  const gutenberg31 = 'pdf/gutenberg/pg5200-generated.pdf';

  group('PDF session × eager parity (≤ sample bound: byte-identical)', () {
    for (final (name, bytes) in [
      ('8-page synthetic', eightPages),
      ('continuation fixture', continuationPages),
    ]) {
      test('per-page canonical text and reflow HTML match byte for byte: $name', () {
        final full = _eager(bytes);
        final engine = SessionEngine.openBytes(bytes);
        addTearDown(engine.close);
        final header = engine.book as PdfBook;

        expect(header.pageCount, full.pageCount);
        expect(
          [for (final item in header.readingOrder) item.name],
          [for (var i = 1; i <= full.pageCount; i++) 'page_$i.html'],
          reason: 'one reading-order slot per page',
        );
        expect(header.hasTextLayer, isFalse, reason: 'the header carries no page texts');
        expect(header.bytes, isEmpty, reason: 'the header carries no document bytes');

        for (var i = 0; i < full.pageCount; i++) {
          final path = 'page_${i + 1}.html';
          expect(
            engine.documentText(path),
            full.pageTexts[i].text,
            reason: 'canonical text of page ${i + 1}',
          );
          expect(
            engine.documentSource(path),
            full.files.html[i].content,
            reason: 'reflow HTML of page ${i + 1}',
          );
        }
      });

      test('materializing in reverse order keeps every page byte-identical: $name', () {
        final full = _eager(bytes);
        final engine = SessionEngine.openBytes(bytes);
        addTearDown(engine.close);

        for (var i = full.pageCount; i >= 1; i--) {
          expect(
            engine.documentText('page_$i.html'),
            full.pageTexts[i - 1].text,
            reason: 'canonical text of page $i (reverse walk)',
          );
        }
      });

      test('search, progression, statistics and navigation match: $name', () {
        final full = _eager(bytes);
        final engine = SessionEngine.openBytes(bytes);
        addTearDown(engine.close);

        final sessionSearch = engine.search('quixoticmarker', maxMatches: 1000);
        final eagerSearch = full.search('quixoticmarker', maxMatches: 1000);
        expect(sessionSearch.matches.length, eagerSearch.matches.length);
        for (var i = 0; i < eagerSearch.matches.length; i++) {
          expect(sessionSearch.matches[i].sectionName, eagerSearch.matches[i].sectionName);
          expect(sessionSearch.matches[i].start, eagerSearch.matches[i].start);
          expect(sessionSearch.matches[i].end, eagerSearch.matches[i].end);
        }

        final progression = engine.computeProgression();
        expect(progression.sectionLengths, [for (final page in full.pageTexts) page.text.length]);

        final statistics = engine.computeStatistics();
        final eagerStatistics = BookStatistics.fromTexts([
          for (final file in full.files.html) file.plainText,
        ]);
        expect(statistics.wordCount, eagerStatistics.wordCount);
        expect(statistics.characterCount, eagerStatistics.characterCount);

        expect(
          headerNavigationPoints(engine.book.navigation).length,
          full.navigation.navPoints.length,
        );
      });
    }

    test('the running header and footer cut applies to every page, eager and session alike', () {
      // The §3.4 frozen decision: skips come from the sampled plan,
      // and the eager scanner reads the same first 20 pages. The
      // observable contract on a 400-page book: the repeated
      // header/footer lines are gone from every page's canonical text
      // both ways (the direct plan-level pin lives in
      // pdf_reflow_plan_test.dart).
      final full = _eager(fourHundredPages);
      final engine = SessionEngine.openBytes(fourHundredPages);
      addTearDown(engine.close);

      expect(full.pageTexts.first.text, isNot(contains('A Tale of Two Cities')));
      expect(full.pageTexts.last.text, isNot(contains('A Tale of Two Cities')));
      for (var i = 1; i <= full.pageCount; i++) {
        final text = engine.documentText('page_$i.html')!;
        expect(text, isNot(contains('A Tale of Two Cities')), reason: 'header cut, page $i');
        expect(text, isNot(contains('Page $i')), reason: 'footer cut, page $i');
      }
    });
  });

  group('PDF session equivalence (real fixtures beyond the sample bound)', () {
    test('gutenberg 31-pager: same match counts, non-empty pages, close progression', () {
      final bytes = _bytes(gutenberg31);
      final full = _eager(bytes);
      final engine = SessionEngine.openBytes(bytes);
      addTearDown(engine.close);

      // The outline is the one structure with byte parity: it is
      // parsed, not reflowed.
      expect(engine.book.navigation.navPoints.length, full.navigation.navPoints.length);

      // Distinctive queries from different parts of the book: the
      // equivalence contract is equal match counts and sections.
      for (final query in ['accommodation', ' Humphry ', 'reconstruct']) {
        final sessionSearch = engine.search(query.trim(), maxMatches: 1000);
        final eagerSearch = full.search(query.trim(), maxMatches: 1000);
        expect(sessionSearch.matches.length, eagerSearch.matches.length, reason: query);
      }

      var progressionReached = 0;
      for (var i = 1; i <= full.pageCount; i++) {
        final text = engine.documentText('page_$i.html');
        expect(text, isNotNull, reason: 'page $i materializes');
        if (text!.trim().isNotEmpty) progressionReached++;
      }
      expect(progressionReached, full.pageCount, reason: 'every page carries text');

      final progression = engine.computeProgression();
      final eagerTotal = full.pageTexts.fold<int>(
        0,
        (final sum, final page) => sum + page.text.length,
      );
      final delta = (progression.totalCharacters - eagerTotal).abs() / eagerTotal;
      expect(delta, lessThan(0.05), reason: 'progression totals within 5% of eager');
    });

    test('400-page synthetic: identical skips, equal distinctive counts, 5% progression', () {
      final full = _eager(fourHundredPages);
      final engine = SessionEngine.openBytes(fourHundredPages);
      addTearDown(engine.close);

      final sessionSearch = engine.search('quixoticmarker', maxMatches: 1000);
      expect(sessionSearch.matches.length, 400, reason: 'one marker hit per page');
      final eagerSearch = full.search('quixoticmarker', maxMatches: 1000);
      expect(sessionSearch.matches.length, eagerSearch.matches.length);

      for (var i = 1; i <= full.pageCount; i++) {
        expect(engine.documentText('page_$i.html'), isNotEmpty, reason: 'page $i');
      }

      final progression = engine.computeProgression();
      final eagerTotal = full.pageTexts.fold<int>(
        0,
        (final sum, final page) => sum + page.text.length,
      );
      expect((progression.totalCharacters - eagerTotal).abs() / eagerTotal, lessThan(0.05));
    });
  });

  group('PDF session content ops', () {
    test('textFile returns reflow-shaped TextFiles and resource is null for pages', () {
      final engine = SessionEngine.openBytes(eightPages);
      addTearDown(engine.close);

      final file = engine.textFile('page_3.html')!;
      expect(file.name, 'page_3.html');
      expect(file.type, 'html');
      expect(file.path, 'page_3.html');
      expect(file.content, startsWith('<!DOCTYPE html>'));

      expect(engine.textFile('page_0.html'), isNull);
      expect(engine.textFile('page_9.html'), isNull);
      expect(engine.textFile('nope.html'), isNull);
      expect(engine.resource('page_1.html'), isNull, reason: 'pages are not resources');
      expect(
        engine.resourceLength('page_1.html'),
        isNull,
        reason: 'no materialization for lengths',
      );
    });

    test('loadBytesRange slices the raw document under the policy cap', () {
      final engine = SessionEngine.openBytes(
        fourHundredPages,
        policy: const SessionPolicy(rangeMaxBytes: 1 << 16),
      );
      addTearDown(engine.close);

      expect(engine.byteLength, fourHundredPages.length);
      expect(engine.bytesRange(0, 8), fourHundredPages.sublist(0, 8));
      expect(
        engine.bytesRange(fourHundredPages.length - 4, 100),
        fourHundredPages.sublist(fourHundredPages.length - 4),
      );
      expect(engine.bytesRange(0, 1 << 20).length, 1 << 16, reason: 'policy clamp');
      expect(() => engine.bytesRange(-1, 4), throwsA(isA<RangeError>()));
      expect(() => engine.bytesRange(0, -1), throwsA(isA<RangeError>()));
      expect(() => engine.bytesRange(fourHundredPages.length + 1, 4), throwsA(isA<RangeError>()));
    });

    test('images decode on demand by object number, without the eager cap', () {
      final bytes = Uint8List.fromList(imagePageFixture(tinyJpegPage).build());
      final full = _eager(bytes);
      final engine = SessionEngine.openBytes(bytes);
      addTearDown(engine.close);

      expect(full.files.images, hasLength(1));
      final eagerImage = full.files.images.single;
      expect(engine.resource(eagerImage.path), eagerImage.content);
      // After materialization the length is known.
      expect(engine.resourceLength(eagerImage.path), eagerImage.content.length);
      expect(engine.resource('images/pdf-image-9999.jpg'), isNull);
      expect(engine.resource('images/pdf-image-8.png'), isNull, reason: 'wrong extension');
      expect(engine.resource('images/nope.png'), isNull);
    });

    test(
      'documentText equals the joined loadPdfPageLines lines (intra-session invariant)',
      () async {
        final session = await BookSession.open(eightPages);
        addTearDown(session.dispose);

        for (var i = 0; i < 8; i++) {
          final text = await session.loadDocumentText('page_${i + 1}.html');
          final lines = await session.loadPdfPageLines(i);
          expect(lines, isNotNull, reason: 'page ${i + 1}');
          expect(
            lines!.lines.map((final line) => line.text).join('\n'),
            text,
            reason: 'page ${i + 1}: the §3.4.4 offset space holds',
          );
        }
      },
    );

    test('CFI stays EPUB-only', () async {
      final session = await BookSession.open(eightPages);
      addTearDown(session.dispose);

      expect(await session.resolveCfi('epubcfi(/6/2!/4/2)'), isNull);
      expect(
        () => session.buildCfi(contentIndex: 0, offsetInText: 0),
        throwsA(isA<UnsealException>()),
      );
    });
  });

  group('PDF session cache policy', () {
    test('a tiny budget evicts whole pages without corrupting them', () {
      final bytes = fourHundredPages;
      final full = _eager(bytes);
      final engine = SessionEngine.openBytes(
        bytes,
        policy: const SessionPolicy(cacheBytes: 1 << 20),
      );
      addTearDown(engine.close);

      // Two passes over 400 reflow pages overflow the effective
      // minimum budget many times over; every reload must reproduce
      // the eager canonical text exactly.
      for (var pass = 0; pass < 2; pass++) {
        for (var i = 1; i <= full.pageCount; i++) {
          expect(
            engine.documentText('page_$i.html'),
            full.pageTexts[i - 1].text,
            reason: 'page $i pass $pass',
          );
        }
      }
    });
  });

  group('PDF session lifecycle', () {
    test('cancelPending fails queued page loads typed and the session stays usable', () async {
      final session = await BookSession.open(fourHundredPages);
      addTearDown(session.dispose);

      final loads = <Future<Object?>>[
        for (var i = 1; i <= 40; i++) ...[
          session.loadDocumentText('page_$i.html'),
          session.loadPdfPageLines(i - 1),
        ],
      ];
      session.cancelPending();

      for (final load in loads) {
        await expectLater(load, throwsA(isA<SessionCancelledException>()));
      }
      expect(
        await session.loadDocumentText('page_1.html'),
        isNotNull,
        reason: 'still usable after the cancel',
      );
    });

    test('dispose closes the session and fails subsequent ops', () async {
      final session = await BookSession.open(eightPages);
      expect((await session.loadDocumentText('page_1.html')), isNotNull);

      session.dispose();
      expect(() => session.loadDocumentText('page_1.html'), throwsA(isA<SessionClosedException>()));
    });

    test('two concurrent PDF sessions and one CBR stay isolated', () async {
      final cbr = _bytes('books/comic/synthetic-stored-pages.cbr');
      final sessions = await Future.wait([
        BookSession.open(eightPages),
        BookSession.open(fourHundredPages),
        BookSession.open(cbr),
      ]);
      addTearDown(sessions[0].dispose);
      addTearDown(sessions[1].dispose);
      addTearDown(sessions[2].dispose);

      final results = await Future.wait([
        sessions[0].loadDocumentText('page_2.html'),
        sessions[1].loadDocumentText('page_2.html'),
        sessions[2].loadResource((sessions[2].book as ComicBook).pages.first.path),
      ]);

      final full8 = _eager(eightPages);
      final full400 = _eager(fourHundredPages);
      final fullCbr = Unseal.parse(cbr) as ComicBook;
      expect(results[0], full8.pageTexts[1].text);
      expect(results[1], full400.pageTexts[1].text);
      expect(results[2], fullCbr.pages.first.content);

      // Disposing one session leaves the others serving.
      sessions[0].dispose();
      expect(await sessions[1].loadDocumentText('page_3.html'), isNotNull);
      expect(
        await sessions[2].loadResource((sessions[2].book as ComicBook).pages.last.path),
        isNotNull,
      );
    });

    test('file-backed PDF sessions match the eager parse across the isolate', () async {
      final temp = Directory.systemTemp.createTempSync('unseal-pdf');
      addTearDown(() => temp.deleteSync(recursive: true));
      final path = '${temp.path}/book.pdf';
      File(path).writeAsBytesSync(eightPages);

      final session = await BookSession.openFile(path);
      addTearDown(session.dispose);
      final full = _eager(eightPages);

      expect((session.book as PdfBook).pageCount, full.pageCount);
      expect(await session.loadDocumentText('page_5.html'), full.pageTexts[4].text);
      final lines = await session.loadPdfPageLines(4);
      expect(lines, isNotNull);
      expect(lines!.lines.map((final line) => line.text).join('\n'), full.pageTexts[4].text);
      expect(session.byteLength, eightPages.length);
    });
  });

  group('PDF session adversarial opens', () {
    test('wrong password fails typed; the right one opens with eager parity', () async {
      final bytes = _bytes('pdf/encrypted/r6.pdf');
      final eager = parsePdfBook(bytes, password: 'user123');

      await expectLater(
        BookSession.open(bytes, password: 'nope'),
        throwsA(isA<PdfEncryptedException>()),
      );
      await expectLater(BookSession.open(bytes), throwsA(isA<PdfEncryptedException>()));

      final session = await BookSession.open(bytes, password: 'user123');
      addTearDown(session.dispose);
      expect((session.book as PdfBook).pageCount, eager.pageCount);
      expect(await session.loadDocumentText('page_1.html'), eager.pageTexts.single.text);
    });

    test('broken xref opens through the recovery scan, like the eager parse', () {
      final builder = multipageTextFixture(pageCount: 4, withHeaderFooter: true)
        ..corruptXref = true;
      final bytes = Uint8List.fromList(builder.build());
      final full = _eager(bytes);

      final engine = SessionEngine.openBytes(bytes);
      addTearDown(engine.close);

      expect((engine.book as PdfBook).pageCount, full.pageCount);
      expect(engine.documentText('page_1.html'), full.pageTexts[0].text);
    });

    test('hostile bytes stay typed and lenient bytes match the eager outcome', () async {
      // Garbage after the magic: the parser refuses typed, eager and
      // session alike.
      final garbage = Uint8List.fromList([
        ...'%PDF-1.7\n'.codeUnits,
        ...List<int>.filled(64, 0x20),
      ]);
      expect(() => Unseal.parse(garbage), throwsA(isA<PdfException>()));
      await expectLater(BookSession.open(garbage), throwsA(isA<PdfException>()));

      // A content stream whose declared /Length runs past EOF: the
      // parser bounds the stream, and the session matches the eager
      // outcome whatever it is (the recovery scan opens both).
      final bombBuilder = PdfFixtureBuilder()
        ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
        ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
        ..addObject(
          5,
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
          '/Resources << >> >>',
        )
        ..addStreamObject(7, '', 'BT ET'.codeUnits);
      final bomb = Uint8List.fromList(bombBuilder.build());
      final truncated = Uint8List.sublistView(bomb, 0, bomb.length - 6);

      Object? eagerOutcome;
      try {
        eagerOutcome = (Unseal.parse(truncated) as PdfBook).pageCount;
      } on UnsealException catch (error) {
        eagerOutcome = error;
      }
      try {
        final engine = SessionEngine.openBytes(truncated);
        addTearDown(engine.close);
        expect(eagerOutcome, isA<int>(), reason: 'session opened; the eager parse opens too');
        expect((engine.book as PdfBook).pageCount, eagerOutcome, reason: 'page count parity');
      } on UnsealException {
        expect(eagerOutcome, isA<UnsealException>(), reason: 'session failed typed; eager too');
      }

      await expectLater(BookSession.open(Uint8List(0)), throwsA(isA<EmptyBytesException>()));
    });

    test('unreachable formats stay typed (txt through the pdf gate)', () async {
      await expectLater(
        BookSession.open(Uint8List.fromList('plain text book'.codeUnits)),
        throwsA(isA<SessionUnsupportedFormatException>()),
      );
    });
  });

  group('loadPdfPageLines', () {
    test('returns finite geometry for page 1 and RangeError out of range', () async {
      final session = await BookSession.open(eightPages);
      addTearDown(session.dispose);

      final lines = await session.loadPdfPageLines(0);
      expect(lines, isNotNull);
      expect(lines!.lines, isNotEmpty);
      for (final line in lines.lines) {
        expect(line.x.isFinite, isTrue);
        expect(line.y.isFinite, isTrue);
        expect(line.width.isFinite, isTrue);
        expect(line.height.isFinite, isTrue);
        expect(line.fontSize.isFinite, isTrue);
      }

      await expectLater(session.loadPdfPageLines(-1), throwsA(isA<RangeError>()));
      await expectLater(session.loadPdfPageLines(8), throwsA(isA<RangeError>()));
      await expectLater(session.loadPdfPageLines(1000), throwsA(isA<RangeError>()));
    });

    test('a non-PDF session rejects the op with RangeError', () async {
      final session = await BookSession.open(_bytes('books/comic/synthetic-stored-pages.cbr'));
      addTearDown(session.dispose);

      await expectLater(session.loadPdfPageLines(0), throwsA(isA<RangeError>()));
    });
  });
}

/// The engine returns the header's own navigation; count its points
/// recursively the way the wire test compares.
List<NavPoint> headerNavigationPoints(final Navigation navigation) {
  return [
    for (final point in navigation.navPoints) ...[point, ...headerSubPoints(point)],
  ];
}

List<NavPoint> headerSubPoints(final NavPoint point) => [
  for (final child in point.subNavPoints) ...[child, ...headerSubPoints(child)],
];
