import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import 'pdf_fixture_builder.dart';

/// Regression fixture for the pathological private PDF (sweep id
/// `605cee501f4e`): a Tagged-PDF content stream whose marked-content
/// property dictionaries end in a hex string immediately before the
/// closing `>>` — the shape `/Span<</ActualText<FEFF0044>>> BDC`.
///
/// Failure signature (pre-fix, measured on the outlier):
///
/// 1. The content lexer's wholesale dictionary scanner pairs the hex
///    string's closing `>` with the dictionary's `>>`, leaving one
///    stray `>` byte behind.
/// 2. The lexer has no case for a bare `>`: the keyword scan consumes
///    nothing and returns an empty operator, so the interpreter spins
///    without progress until its 4,000,000 token budget burns
///    (~108 ms per affected page), then aborts the stream — dropping
///    every text run after the first marked-content dictionary.
///
/// The fixture is synthetic: the same structural shape, no private
/// bytes. The deterministic signature is the dropped text; the perf
/// guard bounds the spin cost.
void main() {
  group('PDF marked-content property dictionaries (BDC/DP)', () {
    test('content after a <hex>>> property dictionary is still extracted', () {
      final book = parsePdfBook(markedContentFixture().build());

      final text = book.pageTexts.single.text;
      expect(text, contains('Before marked content'));
      expect(text, contains('After marked content'));
      expect(text, contains('Tail text'));
    });

    test('many marked-content pages extract without a token-budget spin', () {
      final pages = List<Uint8List>.generate(10, (final i) => markedContentPage(index: i).build());
      final watch = Stopwatch()..start();
      for (final bytes in pages) {
        final book = parsePdfBook(bytes);
        expect(book.pageTexts.single.text, contains('Tail text'));
      }
      watch.stop();

      // Pre-fix each affected page burned the full 4M token budget
      // (~108 ms here); the fixed lexer lexes past the property
      // dictionary in microseconds. The bound sits far above the
      // fixed cost and far below ten spins, so it fails pre-fix and
      // passes post-fix on any machine speed.
      expect(watch.elapsedMilliseconds, lessThan(600));
    });
  });
}

const String _markedContentBody =
    'BT /F1 12 Tf 72 720 Td (Before marked content) Tj ET\n'
    '/Span<</ActualText<FEFF0044>>> BDC\n'
    'BT /F1 12 Tf 72 700 Td (After marked content) Tj ET\n'
    'EMC\n'
    '/Span<</ActualText<FEFF2011>>> BDC\n'
    'BT /F1 12 Tf 72 680 Td (Tail text) Tj ET\n'
    'EMC\n';

/// One-page fixture carrying the outlier's marked-content shape.
PdfFixtureBuilder markedContentFixture() => markedContentPage(index: 1);

/// A one-page fixture with the page's tree objects numbered by
/// [index], so several pages can coexist in one document when needed.
PdfFixtureBuilder markedContentPage({required final int index}) {
  final page = 10 + index * 10;
  final content = page + 1;

  return PdfFixtureBuilder()
    ..addObject(1, '<< /Type /Catalog /Pages 2 0 R >>')
    ..addObject(2, '<< /Type /Pages /Kids [$page 0 R] /Count 1 >>')
    ..addObject(
      page,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents $content 0 R '
      '/Resources << /Font << /F1 9 0 R >> >> >>',
    )
    ..addStreamObject(content, '', _markedContentBody.codeUnits)
    ..addObject(
      9,
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica '
      '/Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 >>',
    );
}
