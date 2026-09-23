@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/unseal.dart';

void main() {
  test('ComicInfo direction and page roles cross the browser wire', () {
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
      'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    const info =
        '<ComicInfo><Manga>YesAndRightToLeft</Manga><Pages>'
        '<Page Image="0" Type="FrontCover" DoublePage="true"/>'
        '</Pages></ComicInfo>';
    final archive = Archive()
      ..addFile(ArchiveFile('page.png', image.length, image))
      ..addFile(ArchiveFile('ComicInfo.xml', info.length, utf8.encode(info)));
    final book = parseComicBook(Uint8List.fromList(ZipEncoder().encode(archive)));
    final (json, blobs) = encodeBookWire(book);
    final restored = decodeBookWire(decodeJson(encodeJson(json)), blobs) as ComicBook;

    expect(restored.readingDirection, ComicReadingDirection.rightToLeft);
    expect(restored.pageInfo.single.type, ComicPageType.frontCover);
    expect(restored.pageInfo.single.doublePage, isTrue);
  });

  test('PDF extraction diagnosis crosses the browser wire', () {
    final book = PdfBook(
      bytes: Uint8List(0),
      metadata: BookMetadata(format: BookFormat.pdf),
      pages: [
        PdfPage(objectNumber: 1, mediaBox: [0, 0, 100, 100]),
        PdfPage(objectNumber: 2, mediaBox: [0, 0, 100, 100]),
      ],
      navigation: Navigation(title: '', navPoints: []),
      pageTexts: const [
        PdfPageText(
          lines: [],
          contentStreamCount: 2,
          skippedContentStreams: 1,
          columnOrderApplied: true,
        ),
        PdfPageText(
          lines: [],
          images: [PdfImageBox(name: 'Im0', x: 0, y: 0, width: 100, height: 100)],
          contentStreamCount: 1,
        ),
      ],
    );
    final (json, blobs) = encodeBookWire(book);
    final restored = decodeBookWire(decodeJson(encodeJson(json)), blobs) as PdfBook;

    expect(restored.pageTexts.first.quality, PdfTextQuality.partial);
    expect(restored.pageTexts.first.contentStreamCount, 2);
    expect(restored.pageTexts.first.skippedContentStreams, 1);
    expect(restored.pageTexts.first.columnOrderApplied, isTrue);
    expect(restored.pageTexts.last.quality, PdfTextQuality.imageWithoutText);
    expect(restored.pageTexts.last.images.single.name, 'Im0');
  });
}
