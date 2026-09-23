import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  group('Unseal.inspect', () {
    test('returns the parsed book and its concrete format on success', () async {
      final bytes = Uint8List.fromList('A plain text book\n'.codeUnits);
      final result = await Unseal.inspect(bytes);

      expect(result.canOpen, isTrue);
      expect(result.book, isNotNull);
      expect(result.book!.format, BookFormat.txt);
      expect(result.format, BookFormat.txt);
      expect(result.detectedFormat, DetectedFormat.txt);
      expect(result.error, isNull);
    });

    test('opens async comic archives through the same path as read', () async {
      final bytes = File('test/resources/books/comic/synthetic-pages.cb7').readAsBytesSync();
      final result = await Unseal.inspect(bytes);

      expect(result.canOpen, isTrue);
      expect(result.format, BookFormat.cb7);
      expect(result.detectedFormat, DetectedFormat.comic7);
      expect(result.book, isNotNull);
    });

    test('keeps the typed parse failure for a recognized but invalid PDF', () async {
      final bytes = Uint8List.fromList('%PDF-1.7\n'.codeUnits);
      final result = await Unseal.inspect(bytes);

      expect(result.canOpen, isFalse);
      expect(result.book, isNull);
      expect(result.format, isNull);
      expect(result.detectedFormat, DetectedFormat.pdf);
      expect(result.error, isA<PdfException>());
    });

    test('reports unsupported formats without claiming a concrete book format', () async {
      final result = await Unseal.inspect(Uint8List.fromList('TPZ'.codeUnits));

      expect(result.canOpen, isFalse);
      expect(result.book, isNull);
      expect(result.format, isNull);
      expect(result.detectedFormat, isNull);
      expect(result.error, isA<FormatNotSupportedException>());
    });

    test('preserves the public empty-input failure', () async {
      final result = await Unseal.inspect(Uint8List(0));

      expect(result.canOpen, isFalse);
      expect(result.detectedFormat, isNull);
      expect(result.error, isA<EmptyBytesException>());
    });
  });
}
