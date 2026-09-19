import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/features/txt/parse_txt_book.dart';
import 'package:unseal/src/foundation/entities/entities.dart';
import 'package:unseal/src/foundation/exceptions/unseal_exception.dart';

void main() {
  group('TXT parser', () {
    test('decodes Calibre-style header and normalizes text into HTML paragraphs', () {
      final bytes = Uint8List.fromList(
        convert.utf8.encode(
          'A Small Book\n\n\nAda Lovelace\n'
          'First wrapped line\rSecond wrapped line\r\n\r\n'
          'A second paragraph with & and <markup>.\n\n\n\n\n',
        ),
      );

      final book = parseTxtBook(bytes, sourceName: 'ignored.txt');

      expect(book, isA<DocumentBook>());
      expect(book.format, BookFormat.txt);
      expect(book.metadata.title, 'A Small Book');
      expect(book.metadata.authors, ['Ada Lovelace']);
      expect(book.files.html.single.path, 'ignored.html');
      expect(
        book.files.html.single.content,
        contains('<p>Ada Lovelace First wrapped line Second wrapped line</p>'),
      );
      expect(
        book.files.html.single.content,
        contains('<p>A second paragraph with &amp; and &lt;markup&gt;.</p>'),
      );
      expect(book.navigation.navPoints.single.content, 'ignored.html');
      expect(book.archiveEntries, isEmpty);
    });

    test('decodes UTF-8 BOM and BOM-identified UTF-16 without throwing', () {
      final utf8 = Uint8List.fromList(<int>[
        0xEF,
        0xBB,
        0xBF,
        ...convert.utf8.encode('Título\n\n\nAutor'),
      ]);
      final utf16be = _utf16('Título\n\n\nAutor', littleEndian: false);

      expect(readTxtMetadata(utf8).title, 'Título');
      expect(readTxtMetadata(utf16be).title, 'Título');
      expect(parseTxtBook(utf16be).files.html.single.content, contains('Título'));
    });
  });

  group('TXTZ parser', () {
    test('uses OPF as metadata/manifest, extracts resources, and sorts text naturally', () {
      final bytes = _zip(<String, List<int>>{
        'chapter10.txt': convert.utf8.encode('# Ten\nlast'),
        'metadata.opf': convert.utf8.encode(_metadataOpf()),
        'images/cover.png': _png,
        'chapter2.txt': convert.utf8.encode('# Two\nsecond'),
        'chapter1.txt': convert.utf8.encode('# One\nfirst'),
        'styles.css': convert.utf8.encode('body { color: black; }'),
        'notes.bin': <int>[1, 2, 3],
      });

      final book = parseTxtzBook(bytes, sourceName: 'collection.txtz');

      expect(book.format, BookFormat.txtz);
      expect(book.metadata.title, 'TXTZ title');
      expect(book.metadata.authors, ['Author One', 'Author Two']);
      expect(book.metadata.series, 'Series');
      expect(book.metadata.seriesIndex, 2.5);
      expect(book.metadata.isbn, '9783161484100');
      expect(book.metadata.cover, isNotNull);
      expect(book.cover?.name, 'cover.png');
      expect(book.files.html.map((final file) => file.path), [
        'chapter1.html',
        'chapter2.html',
        'chapter10.html',
      ]);
      expect(book.files.css.single.path, 'styles.css');
      expect(book.files.others.single.path, 'notes.bin');
      expect(book.files.others.any((final file) => file.path.endsWith('.opf')), isFalse);
      expect(book.archiveEntries.map((final entry) => entry.path), contains('metadata.opf'));
      expect(book.navigation.navPoints.map((final point) => point.label), ['One', 'Two', 'Ten']);
      expect(book.readingOrder.map((final item) => item.name), [
        'chapter1.html',
        'chapter2.html',
        'chapter10.html',
      ]);
    });

    test('reads OPF metadata without rendering text', () {
      final bytes = _zip(<String, List<int>>{
        'metadata.opf': convert.utf8.encode(_metadataOpf()),
        'book.txt': convert.utf8.encode('ignored body'),
        'images/cover.png': _png,
      });

      final metadata = readTxtzMetadata(bytes);

      expect(metadata.format, BookFormat.txtz);
      expect(metadata.title, 'TXTZ title');
      expect(metadata.authors, ['Author One', 'Author Two']);
      expect(metadata.cover, isNull);
    });

    test('ignores impossible OPF calendar dates instead of normalizing them', () {
      final metadata = _metadataOpf().replaceFirst('2024-05-06', '2024-02-31');
      final bytes = _zip(<String, List<int>>{
        'metadata.opf': convert.utf8.encode(metadata),
        'book.txt': convert.utf8.encode('body'),
      });

      expect(readTxtzMetadata(bytes).publishedAt, isNull);
    });

    test('rejects archive path traversal before exposing entries', () {
      final bytes = _zip(<String, List<int>>{
        '../outside.txt': convert.utf8.encode('unsafe'),
        'book.txt': convert.utf8.encode('safe'),
      });

      expect(() => readTxtzMetadata(bytes), throwsA(isA<InvalidBookException>()));
    });

    test('requires at least one text member', () {
      final bytes = _zip(<String, List<int>>{'metadata.opf': convert.utf8.encode(_metadataOpf())});

      expect(() => parseTxtzBook(bytes), throwsA(isA<InvalidBookException>()));
    });
  });
}

Uint8List _zip(final Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _utf16(final String text, {required final bool littleEndian}) {
  final output = <int>[];
  if (littleEndian) {
    output.addAll(<int>[0xFF, 0xFE]);
  } else {
    output.addAll(<int>[0xFE, 0xFF]);
  }
  for (final unit in text.codeUnits) {
    if (littleEndian) {
      output.add(unit & 0xFF);
      output.add(unit >> 8);
    } else {
      output.add(unit >> 8);
      output.add(unit & 0xFF);
    }
  }

  return Uint8List.fromList(output);
}

String _metadataOpf() {
  return '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <metadata>
    <dc:title>TXTZ title</dc:title>
    <dc:creator>Author One</dc:creator>
    <dc:creator>Author Two</dc:creator>
    <dc:language>en</dc:language>
    <dc:subject>fiction</dc:subject>
    <dc:publisher>Publisher</dc:publisher>
    <dc:description>Description</dc:description>
    <dc:date>2024-05-06</dc:date>
    <dc:identifier>978-3-16-148410-0</dc:identifier>
    <meta name="calibre:series" content="Series"/>
    <meta name="calibre:series_index" content="2.5"/>
    <meta name="text-formatting" content="markdown"/>
    <text-formatting>markdown</text-formatting>
    <cover-relpath-from-base>images/cover.png</cover-relpath-from-base>
  </metadata>
  <manifest><item id="cover" href="images/cover.png" properties="cover-image"/></manifest>
</package>''';
}

const List<int> _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0xF0,
  0x1F,
  0x00,
  0x05,
  0x00,
  0x01,
  0xFF,
  0x89,
  0x99,
  0x3D,
  0x1D,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];
