import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/pdf/header/pdf_document.dart';
import 'package:unseal/src/features/pdf/header/pdf_object.dart';
import 'package:unseal/src/features/pdf/reader/pdf_byte_source.dart';
import 'package:unseal/src/features/pdf/reader/pdf_metadata.dart';
import 'package:unseal/src/features/pdf/reader/pdf_outline.dart';
import 'package:unseal/src/features/pdf/reader/pdf_page_tree.dart';
import 'package:unseal/src/platform/io/pdf_byte_source_io.dart';
import 'package:unseal/unseal.dart';

/// The §3.3 invariant: the document parser is source-agnostic.
/// Parsing the same bytes through [MemoryPdfByteSource] and through
/// a seek-and-slice [FilePdfByteSource] must produce identical
/// structure — every object, the page tree, metadata and outline.
void main() {
  final fixtures = [
    'test/resources/pdf/dickens-sample.pdf',
    'test/resources/pdf/gutenberg/pg11-generated.pdf',
  ];

  for (final path in fixtures) {
    group('memory vs file source — ${path.split('/').last}', () {
      late Uint8List bytes;
      late File file;
      late PdfDocument memoryDocument;
      late PdfDocument fileDocument;

      setUpAll(() {
        bytes = File(path).readAsBytesSync();
        final tempDir = Directory.systemTemp.createTempSync('unseal-pdf-parity-');
        file = File('${tempDir.path}/${path.split('/').last}')..writeAsBytesSync(bytes);
        memoryDocument = PdfDocument.parse(MemoryPdfByteSource(bytes));
        fileDocument = PdfDocument.parse(FilePdfByteSource.open(file.path));
      });

      test('the sources agree on the document length', () {
        expect(fileDocument.byteLength, memoryDocument.byteLength);
        expect(fileDocument.byteLength, bytes.length);
      });

      test('every indirect object parses identically', () {
        final size = _intValue(memoryDocument.trailer['Size']);
        expect(size, isNotNull);
        expect(_intValue(fileDocument.trailer['Size']), size);

        for (var number = 1; number <= size!; number++) {
          expect(
            _describe(memoryDocument.object(number)),
            _describe(fileDocument.object(number)),
            reason: 'object $number diverged between the memory and file sources',
          );
        }
        expect(_describe(memoryDocument.trailer), _describe(fileDocument.trailer));
      });

      test('the page tree parses identically', () {
        final memoryPages = PdfPageTree.parse(memoryDocument);
        final filePages = PdfPageTree.parse(fileDocument);

        expect(filePages.length, memoryPages.length);
        for (var i = 0; i < memoryPages.length; i++) {
          expect(filePages[i].mediaBox, memoryPages[i].mediaBox, reason: 'page ${i + 1} mediaBox');
          expect(filePages[i].cropBox, memoryPages[i].cropBox, reason: 'page ${i + 1} cropBox');
          expect(filePages[i].rotate, memoryPages[i].rotate, reason: 'page ${i + 1} rotate');
          expect(filePages[i].width, memoryPages[i].width, reason: 'page ${i + 1} width');
          expect(filePages[i].height, memoryPages[i].height, reason: 'page ${i + 1} height');
        }
      });

      test('metadata and outline parse identically', () {
        final memoryPages = PdfPageTree.parse(memoryDocument);
        final filePages = PdfPageTree.parse(fileDocument);

        final memoryMetadata = PdfMetadataReader.read(memoryDocument);
        final fileMetadata = PdfMetadataReader.read(fileDocument);
        expect(fileMetadata.title, memoryMetadata.title);
        expect(fileMetadata.authors, memoryMetadata.authors);
        expect(fileMetadata.bookProducer, memoryMetadata.bookProducer);
        expect(fileMetadata.publishedAt, memoryMetadata.publishedAt);

        final memoryNavigation = PdfOutlineReader.read(memoryDocument, memoryPages);
        final fileNavigation = PdfOutlineReader.read(fileDocument, filePages);
        expect(_navLabels(fileNavigation.navPoints), _navLabels(memoryNavigation.navPoints));
      });
    });
  }
}

int? _intValue(final PdfObject? object) => object is PdfNumber ? object.intValue : null;

/// A deterministic structural rendering of a parsed object; streams
/// carry their raw body so a mis-sliced window read cannot hide.
String _describe(final PdfObject? object) {
  if (object == null) return 'null';
  if (object is PdfNull) return 'null';
  if (object is PdfBool) return 'bool:${object.value}';
  if (object is PdfNumber) return 'number:${object.value}';
  if (object is PdfName) return 'name:${object.value}';
  if (object is PdfString) return 'string:${object.bytes}';
  if (object is PdfArray) return '[${object.items.map(_describe).join(',')}]';
  if (object is PdfDictionary) {
    final keys = object.entries.keys.toList()..sort();

    return '{${keys.map((final key) => '$key:${_describe(object[key])}').join(',')}}';
  }
  if (object is PdfStream) {
    return 'stream${_describe(object.dictionary)}body:${object.bytes}';
  }

  return object.toString();
}

List<String> _navLabels(final List<NavPoint> points) => [
  for (final point in points) _navLabel(point),
];

String _navLabel(final NavPoint point) =>
    '${point.label}@${point.subNavPoints.map(_navLabel).join('|')}';
