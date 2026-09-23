@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

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
}
