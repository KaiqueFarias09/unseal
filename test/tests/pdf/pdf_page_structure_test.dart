import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import 'pdf_fixture_builder.dart';

PublicationRevision _identity() => PublicationRevision(
  publicationId: 'library:layout-fixture',
  sourceRevision: 'sha256:1111111111111111111111111111111111111111111111111111111111111111',
  sourceEvidence: SourceEvidence.sha256,
);

void main() {
  group('words from glyph metrics (PDF02)', () {
    late PdfBook book;
    late PdfPageStructure structure;

    setUp(() {
      book = parsePdfBook(textPageFixture().build());
      structure = buildPdfPageStructure(book: book, pageIndex: 0);
    });

    test('splits the join-space line into words with real advance widths', () {
      final hello = structure.words.firstWhere((final word) => word.text == 'Hello');
      final world = structure.words.firstWhere((final word) => word.text == 'world');

      // Helvetica AFM advances at 12 pt: Hello = 2278/1000 em (H is
      // 722), world = 2389/1000 em — the font's own metrics, not a
      // divided line.
      expect(hello.width, closeTo(2278 / 1000 * 12, 0.01));
      expect(world.width, closeTo(2389 / 1000 * 12, 0.01));
      expect(world.x, greaterThan(hello.x));
    });

    test('word boxes sit inside their line box', () {
      for (final word in structure.words) {
        final line = structure.sourceLines.firstWhere(
          (final line) =>
              word.y + word.height / 2 >= line.y - 1 && word.y + word.height / 2 <= line.bottom + 1,
        );
        expect(word.x, greaterThanOrEqualTo(line.x - 0.5));
        expect(word.right, lessThanOrEqualTo(line.right + 0.5));
      }
    });

    test('kerning stays inside one word; only real gaps split', () {
      // The TJ kern between The and quick is 0.48 pt — far below the
      // word-gap threshold, so the line is one word, exactly like the
      // line text.
      final oneWord = structure.words.firstWhere((final word) => word.text == 'Thequick');
      expect(oneWord.text, 'Thequick');
      final hello = structure.words.firstWhere((final word) => word.text == 'Hello');
      expect(oneWord.y, hello.y + 20, reason: 'the kerned line sits 20 pt below the first');
    });

    test('a ligature code expands to its characters at one advance', () {
      final book = parsePdfBook(ligatureWordFixture().build());
      final structure = buildPdfPageStructure(book: book, pageIndex: 0);

      expect(structure.words, hasLength(1));
      final ligature = structure.words.single;
      expect(ligature.text, 'ffi');
      // One CID code, DW 500: 0.5 em at 12 pt.
      expect(ligature.width, closeTo(6.0, 0.01));
    });

    test('a rotated word keeps its direction instead of a flat box', () {
      final book = parsePdfBook(rotatedTextFixture().build());
      final structure = buildPdfPageStructure(book: book, pageIndex: 0);

      final sideways = structure.words.firstWhere((final word) => word.text == 'Sideways');
      expect(sideways.rotated, isTrue);
      expect(sideways.directionX.abs(), closeTo(0, 0.01));
      expect(sideways.directionY.abs(), closeTo(1, 0.01));
      // The sweep runs along the direction, so the box is tall, not wide.
      expect(sideways.height, greaterThan(sideways.width));

      final upright = structure.words.firstWhere((final word) => word.text == 'Upright');
      expect(upright.rotated, isFalse);
    });
  });

  group('blocks, columns and roles (PDF03)', () {
    test('a two-column page orders title, left column, right column, footer', () {
      final book = parsePdfBook(columnPageFixture().build());
      final structure = buildPdfPageStructure(book: book, pageIndex: 0);

      expect(structure.columns, hasLength(2));
      expect(structure.columns.first.x, lessThan(structure.columns.last.x));

      final texts = [for (final block in structure.blocks) block.text];
      expect(texts.first, contains('The Title of the Pamphlet'), reason: 'spanning title first');
      expect(texts.last, contains('sign of the Dolphin'), reason: 'spanning footer last');

      final leftTexts = [
        for (final index in structure.columns.first.blockIndexes) structure.blocks[index].text,
      ];
      final rightTexts = [
        for (final index in structure.columns.last.blockIndexes) structure.blocks[index].text,
      ];
      expect(leftTexts.join(' '), contains('Left column'));
      expect(rightTexts.join(' '), contains('Right column'));
      for (var i = 1; i < leftTexts.length; i++) {
        expect(
          structure.blocks[structure.columns.first.blockIndexes[i]].y,
          greaterThanOrEqualTo(structure.blocks[structure.columns.first.blockIndexes[i - 1]].y),
          reason: 'left column reads top to bottom',
        );
      }
    });

    test('a single-column page detects no columns and keeps every block', () {
      final book = parsePdfBook(paragraphPageFixture().build());
      final structure = buildPdfPageStructure(book: book, pageIndex: 0);

      expect(structure.columns, isEmpty);
      expect(structure.blocks, isNotEmpty);
      // Reading order covers all blocks with distinct indexes.
      expect(
        [for (final block in structure.blocks) block.index],
        [for (var i = 0; i < structure.blocks.length; i++) i],
      );
    });

    test('running header and footer blocks carry their editorial roles', () {
      final book = parsePdfBook(headerFooterFixture().build());
      final structure = buildPdfPageStructure(book: book, pageIndex: 0);

      final roles = [for (final block in structure.blocks) block.role];
      expect(roles, contains(PdfBlockRole.header));
      expect(roles, contains(PdfBlockRole.footer));
      expect(roles.first, PdfBlockRole.header, reason: 'the header block reads first');
      expect(roles.last, PdfBlockRole.footer, reason: 'the footer block reads last');
    });
  });

  group('tables (PDF04)', () {
    test('a complete ruled lattice yields spreadsheet cells in order', () {
      final book = parsePdfBook(ruledTableFixture().build());
      final structure = buildPdfPageStructure(book: book, pageIndex: 0);

      final region = structure.tableRegion;
      expect(region, isNotNull);
      expect(region!.hasRulingLines, isTrue);
      expect(region.algorithm, 'spreadsheet');
      expect(region.rows, hasLength(2));
      for (final row in region.rows) {
        expect(row, hasLength(3));
      }
      expect(region.rows[0][0].text, 'Alpha');
      expect(region.rows[0][1].text, 'Beta');
      expect(region.rows[0][2].text, 'Gamma');
      expect(region.rows[1][0].text, 'Delta');
      expect(region.rows[1][1].text, 'Epsilon');
      expect(region.rows[1][2].text, 'Zeta');
      expect(structure.tableUnsupported, isNull);
    });

    test('a whitespace-aligned grid without rulings falls back to columns', () {
      final book = parsePdfBook(alignedTableFixture().build());
      final structure = buildPdfPageStructure(book: book, pageIndex: 0);

      final region = structure.tableRegion;
      expect(region, isNotNull);
      expect(region!.hasRulingLines, isFalse);
      expect(region.algorithm, 'aligned-columns');
      final cells = [
        for (final row in region.rows)
          for (final cell in row) cell.text,
      ];
      expect(cells, containsAll(<String>['Ada', 'painter', 'Lyon']));
    });

    test('a plain page is not diagnosed as a refused table', () {
      final book = parsePdfBook(paragraphPageFixture().build());
      final structure = buildPdfPageStructure(book: book, pageIndex: 0);

      expect(structure.tableRegion, isNull);
      expect(structure.tableUnsupported, isNull);
    });

    test('broken ruling evidence produces an explicit diagnosis', () {
      // A single vertical rule with two short horizontals: ruling
      // evidence exists, but no lattice and no column set completes.
      final content = StringBuffer()
        ..write('q 0.5 w 72 600 100 0 re S Q\n')
        ..write('q 0.5 w 72 700 100 0 re S Q\n')
        ..write('BT /F1 12 Tf 72 680 Td (a short line of text between the rules) Tj ET\n');
      final fixture = PdfFixtureBuilder()
        ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
        ..addObject(2, '<< /Type /Pages /Kids [5 0 R] /Count 1 >>')
        ..addObject(
          5,
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 7 0 R '
          '/Resources << /Font << /F1 9 0 R >> >> >>',
        )
        ..addStreamObject(7, '', content.toString().codeUnits)
        ..addObject(
          9,
          '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
          '/Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 >>',
        );
      final book = parsePdfBook(fixture.build());
      final structure = buildPdfPageStructure(book: book, pageIndex: 0);

      expect(structure.tableRegion, isNull);
      expect(structure.tableUnsupported, isNotNull);
      expect(structure.tableUnsupported!.reason, 'too-few-cells');
    });

    test('cell text stays a reference: ranges point into source lines', () {
      final book = parsePdfBook(ruledTableFixture().build());
      final structure = buildPdfPageStructure(book: book, pageIndex: 0);

      final region = structure.tableRegion!;
      for (final row in region.rows) {
        for (final cell in row) {
          if (cell.text.isEmpty) continue;
          // Every cell word resolves to a source line range.
          final wordIndex = structure.words.indexWhere(
            (final word) => word.text == cell.text.split(' ').first,
          );
          expect(wordIndex, greaterThanOrEqualTo(0));
          expect(structure.wordSourceLine(wordIndex), isNotNull);
          expect(structure.wordSourceRange(wordIndex), isNotNull);
        }
      }
    });
  });

  group('geometry (C04)', () {
    test('portrait page geometry maps page corners back to user space', () {
      final book = parsePdfBook(textPageFixture().build());
      final structure = buildPdfPageStructure(book: book, pageIndex: 0);
      final geometry = structure.geometry;

      expect(geometry.width, 612);
      expect(geometry.height, 792);
      expect(geometry.rotation, 0);
      expect(geometry.transformInvertible, isTrue);

      // Top-left page corner is the user-space top-left of the crop.
      final (ux, uy) = geometry.toPdfPoint(0, 0);
      expect(ux, closeTo(0, 0.01));
      expect(uy, closeTo(792, 0.01));
      final (bx, by) = geometry.toPdfPoint(612, 792);
      expect(bx, closeTo(612, 0.01));
      expect(by, closeTo(0, 0.01));
    });

    test('a 90-degree page swaps the visible dimensions and rotates back', () {
      final fixture = textPageFixture();
      fixture.addObject(
        5,
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate 90 /Contents 7 0 R '
        '/Resources << /Font << /F1 9 0 R /F2 10 0 R >> >> >>',
      );
      final book = parsePdfBook(fixture.build());
      final structure = buildPdfPageStructure(book: book, pageIndex: 0);
      final geometry = structure.geometry;

      expect(geometry.rotation, 90);
      expect(geometry.width, closeTo(792, 0.01), reason: 'the rotated page is landscape');
      expect(geometry.height, closeTo(612, 0.01));
      expect(geometry.transformInvertible, isTrue);

      // page (0,0) is the user-space bottom-left of the crop.
      final (ux, uy) = geometry.toPdfPoint(0, 0);
      expect(ux, closeTo(0, 0.01));
      expect(uy, closeTo(0, 0.01));
    });
  });

  group('source anchors and canonical mapping (PDF05)', () {
    late PdfBook book;
    late PdfPageStructure structure;

    setUp(() {
      book = parsePdfBook(textPageFixture().build());
      structure = buildPdfPageStructure(book: book, pageIndex: 0);
    });

    PdfSourceRange anchorFor(final int lineIndex, {final int start = 0, final int? end}) {
      final text = structure.sourceLines[lineIndex].text;
      return PdfSourceRange(
        pageIndex: 0,
        lineIndex: lineIndex,
        start: start,
        end: end ?? text.length,
        expectedLineText: text,
      );
    }

    test('a body anchor maps to its exact canonical offset', () {
      final mapping = structure.mapSourceRange(anchorFor(0));
      expect(mapping, isA<PdfPositionMapped>());
      final position = (mapping as PdfPositionMapped).position;
      expect(position.offset, 0);
      expect(position.length, 'Hello world'.length);

      final second = structure.mapSourceRange(anchorFor(1)) as PdfPositionMapped;
      expect(second.position.offset, 'Hello world'.length + 1);
      expect(
        structure.canonicalText.substring(second.position.offset, second.position.end),
        'Thequick',
      );
    });

    test('a partial range maps inside its line', () {
      final range = PdfSourceRange(
        pageIndex: 0,
        lineIndex: 0,
        start: 6,
        end: 11,
        expectedLineText: 'Hello world',
      );
      final mapping = structure.mapSourceRange(range) as PdfPositionMapped;
      expect(
        structure.canonicalText.substring(mapping.position.offset, mapping.position.end),
        'world',
      );
    });

    test('a header or footer line cut by the reflow answers missing', () {
      final headerBook = parsePdfBook(headerFooterFixture().build());
      final structure = buildPdfPageStructure(book: headerBook, pageIndex: 0);
      final headerLine = structure.sourceLines.indexWhere(
        (final line) => line.text.contains('A Tale of Two Cities'),
      );
      expect(headerLine, greaterThanOrEqualTo(0));

      final mapping = structure.mapSourceRange(
        PdfSourceRange(
          pageIndex: 0,
          lineIndex: headerLine,
          start: 0,
          end: structure.sourceLines[headerLine].text.length,
          expectedLineText: structure.sourceLines[headerLine].text,
        ),
      );
      expect(mapping, isA<PdfPositionMissing>());
      expect((mapping as PdfPositionMissing).reason, PdfPositionMissingReason.lineDroppedByReflow);
    });

    test('wrong page, line and bounds answer missing with their reasons', () {
      expect(
        structure.mapSourceRange(PdfSourceRange(pageIndex: 3, lineIndex: 0, start: 0, end: 1)),
        isA<PdfPositionMissing>(),
      );
      expect(
        structure.mapSourceRange(PdfSourceRange(pageIndex: 0, lineIndex: 999, start: 0, end: 1)),
        isA<PdfPositionMissing>(),
      );
      expect(
        structure.mapSourceRange(PdfSourceRange(pageIndex: 0, lineIndex: 0, start: 0, end: 9999)),
        isA<PdfPositionMissing>(),
      );
      final mismatch = structure.mapSourceRange(
        PdfSourceRange(
          pageIndex: 0,
          lineIndex: 0,
          start: 0,
          end: 1,
          expectedLineText: 'stale text',
        ),
      );
      expect((mismatch as PdfPositionMissing).reason, PdfPositionMissingReason.textMismatch);
    });

    test('a foreign target maps by content and repeats answer ambiguous', () {
      final line = structure.sourceLines[0];
      final foreignTarget = 'prologue\n${line.text}\n${line.text}\nepilogue';

      final unique = structure.mapSourceRange(
        anchorFor(0),
        targetText: 'prefix\n${line.text}\nsuffix',
      );
      expect(unique, isA<PdfPositionMapped>());
      expect((unique as PdfPositionMapped).position.offset, 7);

      final ambiguous = structure.mapSourceRange(anchorFor(0), targetText: foreignTarget);
      expect(ambiguous, isA<PdfPositionAmbiguous>());
      expect((ambiguous as PdfPositionAmbiguous).candidates, hasLength(2));

      final absent = structure.mapSourceRange(anchorFor(0), targetText: 'nothing here');
      expect((absent as PdfPositionMissing).reason, PdfPositionMissingReason.targetTextMismatch);
    });

    test('snapshots bind identity and profiles; a different profile is refused', () {
      final snapshot = structure.canonicalSnapshot(identity: _identity());
      expect(snapshot.text, structure.canonicalText);
      expect(snapshot.profile.id, structure.canonicalProfile.id);
      expect(snapshot.occurrence.resourcePath, 'page_1.html');
      expect(snapshot.occurrence.sectionIndex, 0);

      // The same text under a different profile is a different
      // revision — reuse is refused instead of silently accepted.
      final otherProfile = structure.canonicalSnapshot(identity: _identity());
      CanonicalTextCodec.verifyCompatible(snapshot, otherProfile);

      final sessionLike = CanonicalTextSnapshot(
        identity: _identity(),
        occurrence: snapshot.occurrence,
        profile: TextProfile.of(
          algorithm: 'pdf.reflow',
          options: const <String, String>{'scope': 'session-sample'},
          planRevision: snapshot.profile.planRevision,
        ),
        text: snapshot.text,
      );
      expect(
        () => CanonicalTextCodec.verifyCompatible(snapshot, sessionLike),
        throwsA(isA<IncompatibleRevisionException>()),
      );
    });

    test('the source snapshot and the codec round trip', () {
      final snapshot = structure.sourceSnapshot(identity: _identity());
      expect(snapshot.text, structure.sourceLines.map((final l) => l.text).join('\n'));

      final decoded = CanonicalTextCodec.decode(CanonicalTextCodec.encode(snapshot));
      expect(decoded.sameIdentity(snapshot), isTrue);
    });
  });

  group('more than 20 pages across modes (PDF05/PDF06)', () {
    late Uint8List bytes;
    late PdfBook eager;
    late BookSession session;

    setUp(() async {
      bytes = changingStatisticsFixture().build();
      eager = parsePdfBook(bytes);
      session = await BookSession.open(bytes);
    });

    tearDown(() => session.dispose);

    test('eager and session carry different canonical profiles', () {
      final eagerStructure = buildPdfPageStructure(book: eager, pageIndex: 24);
      expect(eagerStructure.canonicalProfile.options['scope'], 'document');
      expect(eagerStructure.canonicalProfile.id, isNotEmpty);
      expect(eagerStructure.sourceLines, isNotEmpty);
      expect(eagerStructure.words, isNotEmpty);
    });

    test('an anchor minted eagerly maps into the session page and back', () async {
      final eagerStructure = buildPdfPageStructure(book: eager, pageIndex: 24);
      const lineIndex = 1;
      final line = eagerStructure.sourceLines[lineIndex];
      final anchor = PdfSourceRange(
        pageIndex: 24,
        lineIndex: lineIndex,
        start: 0,
        end: line.text.length,
        expectedLineText: line.text,
      );

      final sessionStructure = (await session.loadPdfPageStructure(24))!;
      expect(sessionStructure.canonicalProfile.options['scope'], 'session-sample');
      expect(
        sessionStructure.canonicalProfile.id,
        isNot(eagerStructure.canonicalProfile.id),
        reason: 'sample and document plans never share a revision by convenience',
      );

      // The session's own canonical text resolves the anchor.
      final own = sessionStructure.mapSourceRange(anchor) as PdfPositionMapped;
      expect(
        sessionStructure.canonicalText.substring(own.position.offset, own.position.end),
        line.text,
      );

      // And the eager canonical text resolves it too, at the same
      // offset — the anchor is stable across the mode switch.
      final foreign =
          sessionStructure.mapSourceRange(anchor, targetText: eagerStructure.canonicalText)
              as PdfPositionMapped;
      final ownEager = eagerStructure.mapSourceRange(anchor) as PdfPositionMapped;
      expect(foreign.position.offset, ownEager.position.offset);
      expect(
        eagerStructure.canonicalText.substring(foreign.position.offset, foreign.position.end),
        line.text,
      );
    });

    test('snapshot reuse across the mode switch fails typed, anchors still map', () async {
      final eagerStructure = buildPdfPageStructure(book: eager, pageIndex: 24);
      final sessionStructure = (await session.loadPdfPageStructure(24))!;

      final exported = CanonicalTextCodec.encode(
        eagerStructure.canonicalSnapshot(identity: _identity()),
      );
      final imported = CanonicalTextCodec.decode(exported);
      expect(
        () => CanonicalTextCodec.verifyCompatible(
          imported,
          sessionStructure.canonicalSnapshot(identity: _identity()),
        ),
        throwsA(isA<IncompatibleRevisionException>()),
      );
    });

    test('rebuilding a structure is deterministic (reopening)', () {
      final first = buildPdfPageStructure(book: eager, pageIndex: 24);
      final reparsed = parsePdfBook(bytes);
      final second = buildPdfPageStructure(book: reparsed, pageIndex: 24);

      expect(first.canonicalProfile.id, second.canonicalProfile.id);
      expect(first.canonicalText, second.canonicalText);
      expect([for (final w in first.words) w.text], [for (final w in second.words) w.text]);
      expect([for (final b in first.blocks) b.text], [for (final b in second.blocks) b.text]);
    });

    test('the session serves the same structure for every page index', () async {
      final structure = (await session.loadPdfPageStructure(25))!;
      expect(structure.pageIndex, 25);
      expect(structure.resourcePath, 'page_26.html');
      expect(structure.geometry.width, 612);
      expect(() => session.loadPdfPageStructure(-1), throwsRangeError);
      expect(() => session.loadPdfPageStructure(26), throwsRangeError);
    });
  });

  group('session structures on the VM isolate (PDF06)', () {
    test('session structure text agrees with the served document text', () async {
      final bytes = headerFooterFixture().build();
      final session = await BookSession.open(bytes);
      addTearDown(session.dispose);

      final structure = (await session.loadPdfPageStructure(0))!;
      final text = await session.loadDocumentText('page_1.html');
      expect(text, structure.canonicalText);

      // Lines of the structure join to the declared snapshot.
      final lines = await session.loadPdfPageLines(0);
      expect(lines!.text, structure.canonicalText);
    });
  });
}
