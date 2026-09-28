import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/pdf/header/pdf_document.dart';
import 'package:unseal/src/features/pdf/reader/pdf_byte_source.dart';
import 'package:unseal/src/features/pdf/reader/pdf_content_stream.dart';
import 'package:unseal/src/features/pdf/reader/pdf_page_tree.dart';
import 'package:unseal/src/features/pdf/reflow/pdf_reflow.dart';
import 'package:unseal/unseal.dart';

import 'pdf_fixture_builder.dart';

/// The §3.3 reflow contract: the document-global decisions live in a
/// [PdfReflowPlan], and rendering pages under a plan is byte-identical
/// to the eager whole-document pass — page by page, one page at a
/// time, exactly the way a lazy reader materializes them.
void main() {
  group('PDF reflow plan', () {
    test('per-page applyWithPlan reproduces apply byte-for-byte', () {
      for (final bytes in [
        paragraphPageFixture().build(),
        headerFooterFixture().build(),
        multiPageSampleFixture().build(),
      ]) {
        final (pageTexts, pages) = extractPages(bytes);
        final (eagerFiles, eagerTexts) = PdfReflow.apply(pageTexts, pages);
        final plan = PdfReflowPlan.scan(pageTexts, pages);

        for (var i = 0; i < pageTexts.length; i++) {
          final (files, texts) = PdfReflow.applyWithPlan(
            [pageTexts[i]],
            [pages[i]],
            plan,
            firstPageNumber: i + 1,
          );

          expect(files, hasLength(1));
          expect(files.single.name, 'page_${i + 1}.html');
          expect(
            files.single.content,
            eagerFiles[i].content,
            reason: 'page ${i + 1}: plan-rendered HTML diverged from the eager pass',
          );
          expect(
            _canonical(texts.single),
            _canonical(eagerTexts[i]),
            reason: 'page ${i + 1}: plan-path canonical text diverged from the eager pass',
          );
        }
      }
    });

    test('a sliced range renders with absolute page numbers', () {
      final (pageTexts, pages) = extractPages(multiPageSampleFixture().build());
      final (eagerFiles, eagerTexts) = PdfReflow.apply(pageTexts, pages);
      final plan = PdfReflowPlan.scan(pageTexts, pages);

      final (files, texts) = PdfReflow.applyWithPlan(
        pageTexts.sublist(10, 13),
        pages.sublist(10, 13),
        plan,
        firstPageNumber: 11,
      );

      expect(files.map((final file) => file.name).toList(), [
        'page_11.html',
        'page_12.html',
        'page_13.html',
      ]);
      for (var i = 0; i < files.length; i++) {
        expect(files[i].content, eagerFiles[10 + i].content);
        expect(_canonical(texts[i]), _canonical(eagerTexts[10 + i]));
      }
    });

    test('the plan carries the header/footer cut, font vote, statistics and continuations', () {
      final (pageTexts, pages) = extractPages(multiPageSampleFixture().build());
      final plan = PdfReflowPlan.scan(pageTexts, pages);

      // Running header and numbered footer detected on the sampled
      // pages.
      expect(plan.headerSkip, greaterThan(0));
      expect(plan.footerSkip, greaterThan(0));

      // Every page's first paragraph continues the previous page's
      // last paragraph — the cross-page decision lives in the plan.
      expect(plan.continuationPages.length, pageTexts.length - 1);
      expect(plan.continuationPages.contains(1), isFalse);
      expect(plan.continuationPages.containsAll([2, 12, pageTexts.length]), isTrue);
    });

    test('the 20-page sample decides the same header/footer cut as the full scan', () {
      final (pageTexts, pages) = extractPages(multiPageSampleFixture().build());
      expect(pageTexts.length, greaterThan(20));

      final sampled = PdfReflowPlan.scan(pageTexts.sublist(0, 20), pages.sublist(0, 20));
      final full = PdfReflowPlan.scan(pageTexts, pages);

      // The edge scanner samples the first 20 pages and stops, so the
      // cut it decides cannot move when later pages exist.
      expect(sampled.headerSkip, full.headerSkip);
      expect(sampled.footerSkip, full.footerSkip);
    });

    test('the plan path keeps the canonical invariant', () {
      final (pageTexts, pages) = extractPages(multiPageSampleFixture().build());
      final plan = PdfReflowPlan.scan(pageTexts, pages);

      for (var i = 0; i < pageTexts.length; i++) {
        final (files, texts) = PdfReflow.applyWithPlan(
          [pageTexts[i]],
          [pages[i]],
          plan,
          firstPageNumber: i + 1,
        );

        expect(DocumentTextScanner(files.single.content).scan(), texts.single.text);
      }
    });
  });
}

(List<PdfPageText>, List<PdfPage>) extractPages(final Uint8List bytes) {
  final document = PdfDocument.parse(MemoryPdfByteSource(bytes));
  final pages = PdfPageTree.parse(document);
  final extractor = PdfTextExtractor(document);

  return ([for (final page in pages) extractor.extract(page)], pages);
}

/// The canonical text with full line geometry: parity must hold
/// character-for-character and coordinate-for-coordinate.
String _canonical(final PdfPageText text) =>
    '${text.contentStreamCount}/${text.skippedContentStreams}/${text.columnOrderApplied}/'
    '${text.images.map((final image) => image.path).join('|')}#'
    '${text.lines.map((final line) {
      return '${line.text}|${line.x}|${line.y}|${line.width}|${line.height}'
          '|${line.fontSize}|${line.rotated}';
    }).join('\n')}';

/// A [pageCount]-page book with a running header, a numbered footer,
/// one larger mid-page line (so the font vote and em spans matter)
/// and body paragraphs that run to the page bottom — every global
/// reflow decision fires, and every page after the first opens with
/// a continuation of the previous page's closing paragraph.
PdfFixtureBuilder multiPageSampleFixture({final int pageCount = 25}) {
  final fixture = PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
    );
  final kids = <String>[];
  for (var i = 0; i < pageCount; i++) {
    final page = 20 + i;
    final contents = 100 + i;
    kids.add('$page 0 R');
    fixture.addObject(
      page,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents $contents 0 R '
      '/Resources << /Font << /F1 9 0 R >> >> >>',
    );
    final body = StringBuffer()
      ..write('BT /F1 12 Tf 72 755 Td (A Tale of Two Cities) Tj ET\n')
      ..write(
        'BT /F1 12 Tf 72 700 Td (Body first line of page ${i + 1} opens the running sample '
        'text and keeps) Tj ET\n',
      )
      ..write(
        'BT /F1 12 Tf 72 685 Td (going with filler words so the measured line spans most of '
        'the) Tj ET\n',
      )
      ..write(
        'BT /F1 12 Tf 72 670 Td (column width while the paragraph stays together across '
        'every) Tj ET\n',
      )
      ..write(
        'BT /F1 12 Tf 72 655 Td (wrapped line of this page without any break in the middle '
        'of) Tj ET\n',
      )
      ..write('BT /F1 18 Tf 72 640 Td (A larger line lifts the sample font statistics) Tj ET\n')
      ..write(
        'BT /F1 12 Tf 72 615 Td (more filler text follows the larger line to keep the '
        'column) Tj ET\n',
      )
      ..write(
        'BT /F1 12 Tf 72 600 Td (shape steady until page ${i + 1} closes the running sample '
        'text) Tj ET\n',
      )
      ..write('BT /F1 12 Tf 250 60 Td (Page ${i + 1}) Tj ET\n');
    fixture.addStreamObject(contents, '', body.toString().codeUnits);
  }
  fixture.addObject(2, '<< /Type /Pages /Kids [${kids.join(' ')}] /Count $pageCount >>');

  return fixture;
}
