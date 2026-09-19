import 'dart:io';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  test('EPUB reading order follows the spine', () {
    final book = parseEpubBook(File('test/resources/epub/linear-algebra.epub').readAsBytesSync());
    final order = book.readingOrder;
    expect(order, isNotEmpty);
    expect(order.length, lessThanOrEqualTo(book.files.html.length));
    // Every entry resolves to an extracted html file.
    final paths = book.files.html.map((final f) => f.path).toSet();
    for (final item in order) {
      expect(item.isHtml, isTrue);
      expect(paths, contains(item.name));
    }
    // The spine resolves at least the extraction order for most books.
    expect(order.length, greaterThan(1));
  });

  test('MOBI reading order is index.html followed by the parts', () {
    final book = parseMobiBook(File('test/resources/mobi/alice-kf8.azw3').readAsBytesSync());
    final order = book.readingOrder;
    expect(order.first.name, 'index.html');
    expect(order.length, book.files.html.length);
    expect(order.skip(1).map((final item) => item.name).toList(), contains('part0001.html'));
  });

  test('FB2 reading order is the body files', () {
    final book = parseFb2Book(File('test/resources/fb2/alice.fb2').readAsBytesSync());
    expect(book.readingOrder.first.name, 'index.html');
    expect(book.readingOrder.length, book.files.html.length);
  });

  test('comic reading order lists pages as non-html', () {
    final book = Unseal.parse(File('test/resources/comic/sample.cbz').readAsBytesSync());
    final order = book.readingOrder;
    expect(order.length, 3);
    expect(order.every((final item) => !item.isHtml), isTrue);
    expect(order.first.name, 'page1.png');
  });
}
