import 'dart:io';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

/// A real writer's output (macOS cupsfilter, PDF 1.3): genuine
/// cross-reference, real Type1 fonts, realistic content streams —
/// the parser's proof against a PDF this package never generated.
void main() {
  late PdfBook book;

  setUpAll(() {
    book = parsePdfBook(File('test/resources/pdf/dickens-sample.pdf').readAsBytesSync());
  });

  test('reads the structure', () {
    expect(book.pageCount, 1);
    expect(book.format, BookFormat.pdf);
    expect(book.hasTextLayer, isTrue);
  });

  test('extracts the full text', () {
    final text = book.pageTexts.single.text;
    expect(text, startsWith('Chapter One'));
    expect(text, contains('It was the best of times'));
    expect(text, contains('the winter of despair.'));
    expect(text, contains('the paragraph gap statistics.'));
  });

  test('coalesces the wrapped lines into paragraphs', () {
    final html = book.files.html.single.content;

    // The source wraps mid-word without hyphens; the unwrap rule
    // pulls the continuations into one paragraph block.
    expect(RegExp('<p[ >]').allMatches(html), hasLength(2));
    expect(html, contains('of in\ncredulity'));
  });

  test('the canonical invariant holds against a real document', () {
    expect(DocumentTextScanner(book.files.html.single.content).scan(), book.pageTexts.single.text);
  });

  test('search reaches the reflowed text', () {
    expect(book.search('foolishness').matches.single.sectionIndex, 0);
  });
}
