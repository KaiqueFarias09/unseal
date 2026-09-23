import 'dart:io';

import 'package:test/test.dart';
import 'package:unseal/lrf.dart';

void main() {
  test('LRF entry point exposes a usable public parser and result type', () {
    final bytes = File('test/resources/books/lrf/original.lrf').readAsBytesSync();
    final DocumentBook book = parseLrfBook(bytes);
    final BookMetadata metadata = readLrfMetadata(bytes);
    expect(book.format, BookFormat.lrf);
    expect(metadata.title, book.metadata.title);
  });
}
