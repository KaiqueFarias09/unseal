import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/features/comic/archive/rar_reader.dart';
import 'package:test/test.dart';

void main() {
  group('CBZ', () {
    final cbz = _buildCbz();

    test('parses pages in natural order', () {
      final book = parseComicBook(cbz);
      expect(book, isA<ComicBook>());
      expect(book.format, BookFormat.cbz);
      expect(book.pageCount, 3);
      // page2 sorts before page10 (natural order).
      expect(book.pages.map((final page) => page.name).toList(), [
        'page1.png',
        'page2.png',
        'page10.png',
      ]);
    });

    test('orders mixed-depth pages by basename with a path tie-breaker', () {
      final png = _png();
      final archive = Archive()
        ..addFile(ArchiveFile('02.png', png.length, png))
        ..addFile(ArchiveFile('volume/01.png', png.length, png))
        ..addFile(ArchiveFile('archive/01.png', png.length, png));

      final book = parseComicBook(Uint8List.fromList(ZipEncoder().encode(archive)!));

      expect(book.pages.map((final page) => page.path).toList(), [
        'archive/01.png',
        'volume/01.png',
        '02.png',
      ]);
    });

    test('reads ComicInfo.xml metadata', () {
      final book = parseComicBook(cbz);
      expect(book.metadata.title, 'Test Comic');
      expect(book.metadata.series, 'Test Series');
      expect(book.metadata.seriesIndex, 3);
      expect(book.metadata.authors, ['Ana Silva', 'Beto Lima']);
      expect(book.metadata.publisher, 'Editora X');
      expect(book.metadata.subjects, contains('manga'));
      expect(book.metadata.languages, ['pt']);
    });

    test('first page is the cover with dimensions', () {
      final book = parseComicBook(cbz);
      expect(book.cover.name, 'page1.png');
      expect(book.metadata.cover, isNotNull);
      expect(book.metadata.cover!.width, 1);
    });

    test('metadata fast path reads without pages', () {
      final metadata = readComicMetadata(cbz);
      expect(metadata.format, BookFormat.cbz);
      expect(metadata.title, 'Test Comic');
    });

    test('works through the BookReader dispatcher', () {
      // Handled async below in e_book_test too; check sync dispatch.
      final book = BookReader.parseBook(cbz);
      expect(book, isA<ComicBook>());
    });
  });

  group('CBR (stored RAR 4)', () {
    final cbr = _buildCbr();

    test('parses stored entries in natural order', () {
      final book = parseComicBook(cbr);
      expect(book.format, BookFormat.cbr);
      expect(book.pageCount, 2);
      expect(book.pages.map((final page) => page.name).toList(), ['001.jpg', '002.jpg']);
    });

    test('detects the RAR signature', () {
      expect(detectFormat(cbr), DetectedFormat.comic);
    });

    test('compressed entries are rejected with a clear error', () {
      final compressed = _buildCbr(method: 0x31);
      expect(() => parseComicBook(compressed), throwsA(isA<ComicException>()));
    });

    test('rar reader lists stored and compressed entries', () {
      final entries = readRarEntries(_buildCbr(method: 0x31));
      expect(entries.length, 2);
      expect(entries.every((final entry) => !entry.isStored), isTrue);
    });
  });

  test('archives without pages throw', () {
    final archive = Archive()..addFile(ArchiveFile('note.txt', 3, 'abc'.codeUnits));
    expect(
      () => parseComicBook(Uint8List.fromList(ZipEncoder().encode(archive)!)),
      throwsA(isA<ComicException>()),
    );
  });
}

Uint8List _png() => base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

Uint8List _buildCbz() {
  const comicInfo = '''
<?xml version="1.0"?>
<ComicInfo>
  <Title>Test Comic</Title>
  <Series>Test Series</Series>
  <Number>3</Number>
  <Writer>Ana Silva, Beto Lima</Writer>
  <Publisher>Editora X</Publisher>
  <Genre>manga; fiction</Genre>
  <LanguageISO>pt</LanguageISO>
  <Summary>Um quadrinho de teste.</Summary>
</ComicInfo>
''';
  final png = _png();
  final archive = Archive()
    ..addFile(ArchiveFile('page2.png', png.length, png))
    ..addFile(ArchiveFile('page10.png', png.length, png))
    ..addFile(ArchiveFile('page1.png', png.length, png))
    ..addFile(ArchiveFile('ComicInfo.xml', comicInfo.codeUnits.length, comicInfo.codeUnits));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// Builds a minimal RAR 4 archive with stored entries.
Uint8List _buildCbr({final int method = 0x30}) {
  final builder = BytesBuilder(copy: false);
  builder.add([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);

  void addFile(final String name, final List<int> data) {
    final nameBytes = name.codeUnits;
    final headSize = 32 + nameBytes.length;
    final header = ByteData(headSize);
    var f = 0;
    header.setUint16(f, 0, Endian.little);
    f += 2; // crc (unchecked)
    header.setUint8(f, 0x74);
    f += 1; // file header
    header.setUint16(f, 0x8000, Endian.little);
    f += 2; // long block
    header.setUint16(f, headSize, Endian.little);
    f += 2;
    header.setUint32(f, data.length, Endian.little);
    f += 4; // packed
    header.setUint32(f, data.length, Endian.little);
    f += 4; // unpacked
    header.setUint8(f, 0);
    f += 1; // host OS
    header.setUint32(f, 0, Endian.little);
    f += 4; // file crc
    header.setUint32(f, 0, Endian.little);
    f += 4; // file time
    header.setUint8(f, 29);
    f += 1; // unpack version
    header.setUint8(f, method);
    f += 1; // method
    header.setUint16(f, nameBytes.length, Endian.little);
    f += 2;
    header.setUint32(f, 0x20, Endian.little);
    f += 4; // attributes
    final headerBytes = header.buffer.asUint8List();
    headerBytes.setRange(f, f + nameBytes.length, nameBytes);
    builder.add(headerBytes);
    builder.add(data);
  }

  // Minimal JPEG stubs (magic bytes are enough for the sniffer).
  final jpegA = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);
  final jpegB = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 4, 5, 6]);
  addFile('002.jpg', jpegB);
  addFile('001.jpg', jpegA);

  // End of archive block.
  final end = ByteData(7);
  end.setUint8(2, 0x7B);
  end.setUint16(3, 0x4000, Endian.little);
  end.setUint16(5, 7, Endian.little);
  builder.add(end.buffer.asUint8List());

  return builder.takeBytes();
}
