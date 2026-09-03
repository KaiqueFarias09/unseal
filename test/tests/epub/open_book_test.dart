import 'dart:io';

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

void main() {
  group('Reader', () {
    test('should throw exception when path is empty', () async {
      const path = '';
      expect(BookReader.openFromPath(path), throwsA(isA<ArgumentError>()));
    });

    test('should throw exception when file does not exist', () async {
      const path = '/path/to/nonexistent/file.epub';
      expect(
        BookReader.openFromPath(path),
        throwsA(isA<FileSystemException>()),
      );
    });

    final directory = Directory('test/resources/epub');
    final files = directory.listSync();
    final books = files.where((final book) {
      return book.path.endsWith('.epub');
    }).toList();

    for (final book in books) {
      test('should succeed', () async {
        final bookEntity = await BookReader.openFromPath(book.path);
        expect(bookEntity, isA<EpubBook>());
      });
    }
  });
}
