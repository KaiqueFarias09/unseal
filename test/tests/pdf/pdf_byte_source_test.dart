import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/pdf/reader/pdf_byte_source.dart';
import 'package:unseal/src/platform/io/pdf_byte_source_io.dart';

void main() {
  group('MemoryPdfByteSource', () {
    test('reports the wrapped length', () {
      final source = MemoryPdfByteSource(Uint8List.fromList([1, 2, 3, 4, 5]));

      expect(source.length, 5);
    });

    test('reads are zero-copy views over the wrapped bytes', () {
      final bytes = Uint8List.fromList([10, 20, 30, 40]);
      final source = MemoryPdfByteSource(bytes);

      final slice = source.read(1, 2);
      expect(slice, [20, 30]);
      // Writing through the view mutates the wrapped buffer: no copy.
      slice[0] = 99;
      expect(bytes[1], 99);

      // A full read hands out the original list itself.
      expect(identical(source.read(0, bytes.length), bytes), isTrue);
    });

    test('rejects out-of-bounds reads with RangeError', () {
      final source = MemoryPdfByteSource(Uint8List.fromList([1, 2, 3]));

      expect(() => source.read(-1, 2), throwsRangeError);
      expect(() => source.read(0, 4), throwsRangeError);
      expect(() => source.read(3, 1), throwsRangeError);
      expect(() => source.read(4, 0), throwsRangeError);
    });

    test('close is idempotent', () {
      final source = MemoryPdfByteSource(Uint8List.fromList([1]));

      source.close();
      source.close();
    });
  });

  group('FilePdfByteSource', () {
    late Directory tempDir;
    late File file;
    late Uint8List bytes;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('unseal-pdf-source-');
      bytes = Uint8List.fromList(List<int>.generate(70000, (final i) => i % 251));
      file = File('${tempDir.path}/doc.pdf')..writeAsBytesSync(bytes);
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('reads match the file bytes across window-sized ranges', () {
      final source = FilePdfByteSource.open(file.path);
      try {
        expect(source.length, bytes.length);
        expect(source.read(0, 16), bytes.sublist(0, 16));
        expect(source.read(65530, 100), bytes.sublist(65530, 65630));
        expect(source.read(bytes.length - 7, 7), bytes.sublist(bytes.length - 7));
        expect(source.read(0, bytes.length), bytes);
      } finally {
        source.close();
      }
    });

    test('rejects out-of-bounds reads with RangeError', () {
      final source = FilePdfByteSource.open(file.path);
      try {
        expect(() => source.read(-1, 2), throwsRangeError);
        expect(() => source.read(0, bytes.length + 1), throwsRangeError);
        expect(() => source.read(bytes.length, 1), throwsRangeError);
      } finally {
        source.close();
      }
    });

    test('close is idempotent', () {
      final source = FilePdfByteSource.open(file.path);

      source.close();
      source.close();
    });

    test('open names the missing file', () {
      expect(
        () => FilePdfByteSource.open('${tempDir.path}/absent.pdf'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
