import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  for (final compression in <String>['', '-doc']) {
    final fixture = Uint8List.fromList(
      File(
        'test/resources/books/format_expansion/plucker-sample$compression.pdb',
      ).readAsBytesSync(),
    );

    test('Plucker $compression extracts PyPlucker text and metadata', () {
      expect(detectFormat(fixture), DetectedFormat.plucker);
      final book = parsePluckerBook(fixture);
      expect(book.format, BookFormat.plucker);
      expect(book.metadata.title, startsWith('Plucker Sample'));
      expect(book.files.html.single.content, contains('First paragraph with readable text.'));
      expect(book.files.html.single.content, contains('Second paragraph and a local link.'));
      expect(book.files.html.single.content, contains('The End'));
      expect(book.files.html.single.content, contains('Closing line.'));
      expect(book.readingOrder, hasLength(1));
      expect(Unseal.parse(fixture).format, BookFormat.plucker);
      expect(readPluckerMetadata(fixture).title, startsWith('Plucker Sample'));
    });

    test('Plucker $compression rejects malformed length and function', () {
      final badLength = Uint8List.fromList(fixture);
      final textOffset = ByteData.sublistView(badLength).getUint32(86);
      ByteData.sublistView(badLength).setUint16(textOffset + 4, 1);
      expect(() => parsePluckerBook(badLength), throwsA(isA<InvalidBookException>()));

      final badIndex = Uint8List.fromList(fixture);
      final indexOffset = ByteData.sublistView(badIndex).getUint32(78);
      ByteData.sublistView(badIndex).setUint16(indexOffset + 4, 0xffff);
      expect(() => parsePluckerBook(badIndex), throwsA(isA<InvalidBookException>()));
    });
  }
}
