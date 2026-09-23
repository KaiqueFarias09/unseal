@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  test('Plucker zlib text opens in the browser', () async {
    final bytes = Uint8List.fromList(
      base64Decode(
        'UGx1Y2tlciBTYW1wbGUAAAAAAAAAAAAAAAAAAAAAAAAAAAAB5tm/PubZvz4AAAAAAAAAAAAAAAAAAAAARGF0YVBsa3IAAAAAAAAAAAADAAAAaAAAAAEAAAB2AAAAAgAAARAAAAAFAAAAAQACAAIAAAACAAQABQACAAUAlQEAABQAAwAuAAIALwACAA8AAwAVAAJ4nE2MMQ7CMBAEF1cUNPnBtWlc0yOokcwHDvsUWznsyDGC52NCw1a7o9Fi2GE0V336WSo5fiwqHcChZ8Ql1bXRwpWnykukV2qRqnDguwo1eTe7qU58yeFP5L6YcICB0eJZSVOesbcYfue3KHTOYesnLWvK01cRiyN9APTKKCAABQAAABAKAAACAAEAAQBqAAYAAubZvz4=',
      ),
    );
    final book = await Unseal.read(bytes);
    expect(book.format, BookFormat.plucker);
    expect(book.files.html.single.content, contains('Closing line.'));
    expect((await Unseal.readMetadata(bytes)).title, 'Plucker Sample');
  });

  test('Plucker packed grayscale and palette bitmaps parse in Chrome', () async {
    final bytes = Uint8List.fromList(
      base64Decode(
        'UGx1Y2tlciBCaXRtYXAgRm9ybWF0cwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAARGF0YVBsa3IAAAAAAAAAAAAFAAAAdgAAAAAAAAB8AAAAAAAAAJYAAAAAAAAAsgAAAAAAAADSAAAAAAABAAEAAAACAAEADgAAAA4AAEJpdG1hcCBmaXh0dXJlAAsAAAAUAgAABQACAAIAAAIBAAAA/wAAG0DkwAAMAAAAGAIAAAUAAgAEAAAEAQAAAP8AAAF48AD+gQAAAA0AAAAUAgAAAwABAAQAAAgBAAAA/wAA1tfYAA==',
      ),
    );
    final book = await Unseal.read(bytes);
    expect(book.files.images, hasLength(3));

    List<int> rows(final Uint8List png) {
      final idatLength = ByteData.sublistView(png).getUint32(33);
      return const ZLibDecoder().decodeBytes(png.sublist(41, 41 + idatLength));
    }

    expect(rows(book.files.images[0].content), <int>[
      0,
      255,
      170,
      85,
      0,
      170,
      0,
      0,
      85,
      170,
      255,
      0,
    ]);
    expect(rows(book.files.images[1].content), <int>[
      0,
      255,
      238,
      136,
      119,
      0,
      0,
      0,
      17,
      119,
      238,
      255,
    ]);
    expect(rows(book.files.images[2].content), <int>[0, 0, 51, 0, 0, 0, 0, 17, 17, 17]);
  });
}
