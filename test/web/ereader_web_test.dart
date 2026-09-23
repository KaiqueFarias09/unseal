@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/unseal.dart';

// Calibre 9.4.0 eReader fixture from test/resources/books/format_expansion.
const _fixtureBase64 =
    'VW5zZWFsIGVSZWFkZXIgRml4dHVyZQAAAAAAAAAAAAAAAAAAarQK1Wq0CtUAAAAAAAAAAAAAAAAAAAAAUE5SZFBQcnMAAAAGAAAAAAAGAAAAgAAAAAAAAAEEAAAAAAAAAU4AAAAAAAABXgAAAAAAAAGEAAAAAAAAAYgAAAAAAAAACgAAAABiQAAAAAAAAwAAAAAAAAAAAAAAAQAAAAAAAAAECgAABAAEAAQABAADAAAABAAEAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB4nHPLLCouUUjOSCwoSS3i4opJBqGQjMxiBSBKzFPIL8pMz8xLzFEoSQWqK0gsSkwvSizI0IMpDU5Nzs9LQTfAUSENpAkAvroerHicU8jJzEvV4+ICAArUAgtVbnNlYWwgZVJlYWRlciBGaXh0dXJlAFVuc2VhbCBUZXN0AAAAAABdAF1NZVRhSW5GbwA=';

void main() {
  test('eReader zlib records parse and survive browser wire transport', () async {
    final bytes = Uint8List.fromList(base64Decode(_fixtureBase64));
    final book = await Unseal.read(bytes);
    expect(book.format, BookFormat.ereader);
    expect(book.metadata.title, 'Unseal eReader Fixture');
    expect(book.files.html.single.content, contains('A final line.'));

    final (wire, blobs) = encodeBookWire(book);
    final restored = decodeBookWire(wire, blobs);
    expect(restored.format, BookFormat.ereader);
    expect(restored.files.html.single.content, book.files.html.single.content);
  });
}
