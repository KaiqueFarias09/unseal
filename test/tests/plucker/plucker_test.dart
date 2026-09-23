import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  for (final compression in <String>['', '-doc']) {
    final fixture = Uint8List.fromList(
      File(
        'test/resources/books/format_expansion/plucker-sample$compression.pdb',
      ).readAsBytesSync(),
    );

    test('Plucker $compression extracts PyPlucker text and metadata', () {
      expect(detectFormat(fixture), DetectedFormat.plucker);
      final book = parsePluckerBook(fixture);
      expect(book.format, BookFormat.plucker);
      expect(book.metadata.title, startsWith('Plucker Sample'));
      expect(book.files.html.single.content, contains('First paragraph with readable text.'));
      expect(book.files.html.single.content, contains('Second paragraph and a '));
      expect(book.files.html.single.content, contains('>local link</a>.'));
      expect(book.files.html.single.content, contains('The End'));
      expect(book.files.html.single.content, contains('Closing line.'));
      expect(book.readingOrder, hasLength(1));
      expect(Unseal.parse(fixture).format, BookFormat.plucker);
      expect(readPluckerMetadata(fixture).title, startsWith('Plucker Sample'));
    });

    test('Plucker $compression rejects malformed length and function', () {
      final badLength = Uint8List.fromList(fixture);
      final textOffset = ByteData.sublistView(badLength).getUint32(86);
      ByteData.sublistView(badLength).setUint16(textOffset + 4, 1);
      expect(() => parsePluckerBook(badLength), throwsA(isA<InvalidBookException>()));

      final badIndex = Uint8List.fromList(fixture);
      final indexOffset = ByteData.sublistView(badIndex).getUint32(78);
      ByteData.sublistView(badIndex).setUint16(indexOffset + 4, 0xffff);
      expect(() => parsePluckerBook(badIndex), throwsA(isA<InvalidBookException>()));
    });
  }

  test('joins continued Plucker text and a split inline function', () {
    final book = parsePluckerBook(_continuedPlucker(<int>[65, 0], <int>[0x38, 66]));
    expect(book.files.html.single.content, contains('<p>A<br/>B</p>'));

    final word = parsePluckerBook(_continuedPlucker('Al'.codeUnits, 'pha'.codeUnits));
    expect(word.files.html.single.content, contains('<p>Alpha</p>'));
  });

  test('Plucker keeps inline styles, paragraph links, and monochrome images', () {
    final bytes = Uint8List.fromList(
      File('test/resources/books/format_expansion/plucker-rich.pdb').readAsBytesSync(),
    );
    final book = parsePluckerBook(bytes);
    final html = book.files.html.single.content;
    expect(html, contains('<strong>bold fragment</strong>'));
    expect(html, contains('<em>italic fragment</em>'));
    expect(html, contains('<a href="#r2-p5">the destination</a>'));
    expect(html, contains('<img src="images/11.png" alt=""/>'));
    expect(book.files.images, hasLength(1));
    expect(book.files.images.single.content.take(8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);
    final image = book.files.images.single.content;
    expect(ByteData.sublistView(image).getUint32(16), 2);
    expect(ByteData.sublistView(image).getUint32(20), 2);
  });

  test('Plucker rejects a malformed Palm bitmap before allocating pixels', () {
    final bytes = Uint8List.fromList(
      File('test/resources/books/format_expansion/plucker-rich.pdb').readAsBytesSync(),
    );
    final count = ByteData.sublistView(bytes).getUint16(76);
    for (var index = 1; index < count; index++) {
      final offset = ByteData.sublistView(bytes).getUint32(78 + index * 8);
      if (bytes[offset + 6] != 2) continue;
      ByteData.sublistView(bytes).setUint16(offset + 8, 65535);
      break;
    }
    expect(() => parsePluckerBook(bytes), throwsA(isA<InvalidBookException>()));
  });

  test('rejects a Plucker continuation without a matching next record', () {
    expect(
      () => parsePluckerBook(_continuedPlucker(<int>[65], <int>[], missingNext: true)),
      throwsA(isA<InvalidBookException>()),
    );
    expect(
      () => parsePluckerBook(_continuedPlucker(<int>[65], <int>[66], wrongType: true)),
      throwsA(isA<InvalidBookException>()),
    );
  });
}

Uint8List _continuedPlucker(
  final List<int> first,
  final List<int> second, {
  final bool missingNext = false,
  final bool wrongType = false,
}) {
  final records = <Uint8List>[
    Uint8List.fromList(<int>[0, 1, 0, 1, 0, 0]),
    _textRecord(2, first, flags: 1),
    if (!missingNext) _textRecord(3, second, type: wrongType ? 10 : 0),
  ];
  final header = Uint8List(78 + records.length * 8);
  header.setRange(0, 17, 'Continued Plucker'.codeUnits);
  header.setRange(60, 68, 'DataPlkr'.codeUnits);
  final view = ByteData.sublistView(header);
  view.setUint16(76, records.length);
  var offset = header.length;
  for (var index = 0; index < records.length; index++) {
    view.setUint32(78 + index * 8, offset);
    offset += records[index].length;
  }
  final output = BytesBuilder(copy: false)..add(header);
  for (final record in records) {
    output.add(record);
  }
  return output.takeBytes();
}

Uint8List _textRecord(
  final int id,
  final List<int> text, {
  final int type = 0,
  final int flags = 0,
}) => Uint8List.fromList(<int>[
  id >> 8,
  id & 0xff,
  0,
  1,
  text.length >> 8,
  text.length & 0xff,
  type,
  flags,
  text.length >> 8,
  text.length & 0xff,
  0,
  0,
  ...text,
]);
