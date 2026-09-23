import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  final fixture = File('test/resources/books/lrf/original.lrf').readAsBytesSync();

  test('reads a Calibre-generated LRF with ordered text pages', () {
    expect(
      sha256.convert(fixture).toString(),
      'cf5e5e973569e0c9c9d9dea159dfd8958b13160ed48be4b111f807f51caa7175',
    );
    expect(detectFormat(fixture), DetectedFormat.lrf);
    final book = Unseal.parse(fixture) as DocumentBook;
    expect(book.format, BookFormat.lrf);
    expect(book.metadata.title, 'Unseal LRF Fixture');
    expect(book.metadata.authors, <String>['Unseal Test Team']);
    expect(book.metadata.languages, <String>['en']);
    expect(book.files.html.length, 2);
    expect(book.readingOrder.map((final item) => item.name), <String>[
      'lrf/page-1.html',
      'lrf/page-2.html',
    ]);
    expect(book.files.html.first.plainText, contains('First chapter'));
    expect(book.files.html.first.plainText, contains('café'));
    expect(book.files.html.first.content, contains('<em> emphasis</em>'));
    expect(book.files.html.last.plainText, contains('The ending has a new line'));
    expect(book.navigation.navPoints.length, 2);
    expect(book.navigation.navPoints.map((final item) => item.label), <String>[
      'First chapter',
      'Second chapter',
    ]);
  });

  test('reads LRF metadata without opening page streams', () {
    final bytes = Uint8List.fromList(fixture);
    // Corrupt a page stream while preserving the metadata region.
    bytes[0x1a0] ^= 0xff;
    expect(readLrfMetadata(bytes).title, 'Unseal LRF Fixture');
    expect(Unseal.readMetadataSync(bytes).format, BookFormat.lrf);
  });

  test('keeps inline PNG image resources reachable from HTML', () {
    final bytes = File('test/resources/books/lrf/illustrated.lrf').readAsBytesSync();
    expect(
      sha256.convert(bytes).toString(),
      '4078e733625b5f4acb0b403ab05ac5fae766506dd2fe7a965cb997b2a26da2d9',
    );
    final book = parseLrfBook(bytes);
    expect(book.metadata.title, 'Illustrated Café Fixture');
    expect(book.files.images, hasLength(1));
    expect(book.files.images.single.type, 'png');
    expect(book.files.html.single.content, contains('src="${book.files.images.single.path}"'));
    expect(book.metadata.cover?.bytes, isNotEmpty);
  });

  test('rejects invalid object offsets and stream lengths with typed failures', () {
    final offset = Uint8List.fromList(fixture);
    final index = ByteData.sublistView(offset).getUint64(0x18, Endian.little);
    ByteData.sublistView(offset).setUint32(index + 4, offset.length + 1, Endian.little);
    expect(() => parseLrfBook(offset), throwsA(isA<InvalidBookException>()));

    final length = Uint8List.fromList(fixture);
    // Find a page object through the index and corrupt its stream-size tag.
    final count = ByteData.sublistView(length).getUint64(0x10, Endian.little);
    var streamSizeAt = -1;
    for (var entry = 0; entry < count; entry++) {
      final objectOffset = ByteData.sublistView(
        length,
      ).getUint32(index + entry * 16 + 4, Endian.little);
      if (ByteData.sublistView(length).getUint16(objectOffset + 6, Endian.little) != 2) {
        continue;
      }
      for (var at = objectOffset + 8; at < objectOffset + 48; at++) {
        if (length[at] == 4 && length[at + 1] == 0xf5) {
          streamSizeAt = at + 2;
          break;
        }
      }
      break;
    }
    expect(streamSizeAt, isNonNegative);
    ByteData.sublistView(length).setUint32(streamSizeAt, 0xffffffff, Endian.little);
    expect(() => parseLrfBook(length), throwsA(isA<InvalidBookException>()));
  });

  test('bounds metadata expansion and rejects legacy LRF versions explicitly', () {
    final oversized = Uint8List.fromList(fixture);
    ByteData.sublistView(oversized).setUint32(0x54, 0xffffffff, Endian.little);
    expect(() => readLrfMetadata(oversized), throwsA(isA<InvalidBookException>()));

    final old = Uint8List.fromList(fixture);
    ByteData.sublistView(old).setUint16(8, 800, Endian.little);
    expect(() => parseLrfBook(old), throwsA(isA<FormatNotSupportedException>()));
  });
}
