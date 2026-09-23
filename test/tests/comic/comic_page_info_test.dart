import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/comic.dart';
import 'package:unseal/src/platform/web/book_wire.dart';

void main() {
  test('ComicInfo page indices follow natural order and select a declared cover', () {
    final book = parseComicBook(
      _comic('''<ComicInfo><Manga>YesAndRightToLeft</Manga><Pages>
          <Page Image="2" Type="FrontCover" ImageWidth="800" ImageHeight="1200"/>
          <Page Image="1" Type="Story" DoublePage="true" Bookmark="Center"/>
          <Page Image="0" Type="Delete"/>
          <Page Image="99" Type="BackCover"/>
        </Pages></ComicInfo>'''),
    );

    expect(book.pages.map((final page) => page.path), ['page1.png', 'page2.png', 'page10.png']);
    expect(book.readingDirection, ComicReadingDirection.rightToLeft);
    expect(book.pageInfo, hasLength(3));
    expect(book.pageInfo[0].type, ComicPageType.delete);
    expect(book.pageInfo[1].doublePage, isTrue);
    expect(book.pageInfo[1].bookmark, 'Center');
    expect(book.pageInfo[2].type, ComicPageType.frontCover);
    expect(book.pageInfo[2].imageWidth, 800);
    expect(book.pageInfo[2].imageHeight, 1200);
    expect(book.cover.path, 'page10.png');
    expect(book.metadata.cover?.bytes, book.cover.content);
  });

  test('unknown page roles survive and malformed declarations do not shift pages', () {
    final book = parseComicBook(
      _comic('''<ComicInfo><Manga>Yes</Manga><Pages>
          <Page Image="bogus" Type="FrontCover"/>
          <Page Image="1" Type="Gallery" DoublePage="1" ImageWidth="-1"/>
          <Page Image="1" Type="BackCover"/>
        </Pages></ComicInfo>'''),
    );

    expect(book.readingDirection, ComicReadingDirection.unspecified);
    expect(book.pageInfo[0].type, ComicPageType.story);
    expect(book.pageInfo[1].type, ComicPageType.unknown);
    expect(book.pageInfo[1].rawType, 'Gallery');
    expect(book.pageInfo[1].doublePage, isTrue);
    expect(book.pageInfo[1].imageWidth, isNull);
    expect(book.pageInfo[2].type, ComicPageType.story);
    expect(book.cover.path, 'page1.png');
  });

  test('worker wire keeps comic direction and page declarations', () {
    final original = parseComicBook(
      _comic(
        '<ComicInfo><Manga>YesAndRightToLeft</Manga><Pages>'
        '<Page Image="0" Type="InnerCover" DoublePage="true"/>'
        '</Pages></ComicInfo>',
      ),
    );
    final (json, blobs) = encodeBookWire(original);
    final restored = decodeBookWire(json, blobs) as ComicBook;

    expect(restored.readingDirection, ComicReadingDirection.rightToLeft);
    expect(restored.pageInfo.first.type, ComicPageType.innerCover);
    expect(restored.pageInfo.first.doublePage, isTrue);
    expect(
      restored.pages.map((final page) => page.path),
      original.pages.map((final page) => page.path),
    );
  });
}

Uint8List _comic(final String info) {
  final image = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );
  final archive = Archive()
    ..addFile(ArchiveFile('page10.png', image.length, image))
    ..addFile(ArchiveFile('page2.png', image.length, image))
    ..addFile(ArchiveFile('page1.png', image.length, image))
    ..addFile(ArchiveFile('ComicInfo.xml', utf8.encode(info).length, utf8.encode(info)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
