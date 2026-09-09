import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/src/features/comic7/exceptions/exceptions.dart';
import 'package:e_livre/src/features/comic7/parse_comic7_book.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:koni_archive/koni_archive.dart' as koni;
import 'package:test/test.dart';

void main() {
  test('reads CB7 image pages and ComicInfo.xml in natural order', () async {
    final book = await parseComic7Book(await _cb7Bytes());

    expect(book.format, BookFormat.cb7);
    expect(book.metadata.format, BookFormat.cb7);
    expect(book.metadata.title, 'CB7 title');
    expect(book.pages.map((final page) => page.path), ['001/page2.png', '001/page10.png']);
    expect(book.cover.path, '001/page2.png');
    expect(book.metadata.cover, isNotNull);
  });

  test('reads CBC comics.txt, resolves nested CB7 and CBZ files, and preserves order', () async {
    final first = await _cb7Bytes();
    final second = _cbzBytes();
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'comics.txt',
          0,
          utf8.encode('first.cb7:First title\nsecond.cbz:Second title\n'),
        ),
      )
      ..addFile(ArchiveFile('first.cb7', first.length, first))
      ..addFile(ArchiveFile('second.cbz', second.length, second));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);

    final book = await parseCbcBook(bytes);

    expect(book.format, BookFormat.cbc);
    expect(book.metadata.title, 'First title');
    expect(book.pages, hasLength(3));
    expect(book.pages.first.path, '001/page2.png');
    expect(book.pages.last.path, 'page1.png');
  });

  test('reports a missing CBC collection manifest', () async {
    final archive = Archive()..addFile(ArchiveFile('book.cb7', 1, [1]));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);

    expect(() => parseCbcBook(bytes), throwsA(isA<InvalidCbcCollectionException>()));
  });
}

Future<Uint8List> _cb7Bytes() async {
  final sink = koni.BytesBuilderSink();
  final writer = koni.Archive.create(sink, format: const koni.SevenZWriteFormat());
  await writer.addBytes(koni.ArchiveEntrySpec(path: '001/page10.png'), Uint8List.fromList(_png));
  await writer.addBytes(koni.ArchiveEntrySpec(path: '001/page2.png'), Uint8List.fromList(_png));
  final info = utf8.encode('<ComicInfo><Title>CB7 title</Title><Writer>Ada</Writer></ComicInfo>');
  await writer.addBytes(koni.ArchiveEntrySpec(path: 'ComicInfo.xml'), Uint8List.fromList(info));
  await writer.close();
  await sink.close();

  return sink.takeBytes();
}

Uint8List _cbzBytes() {
  final archive = Archive()..addFile(ArchiveFile('page1.png', _png.length, _png));

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
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
