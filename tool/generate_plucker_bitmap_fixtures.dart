import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _fixturePath = 'test/resources/books/format_expansion/plucker-bitmap-variants.pdb';

Future<void> main() async {
  const grayscale2 = <List<int>>[
    <int>[0, 1, 2, 3, 1],
    <int>[3, 2, 1, 0, 3],
  ];
  const grayscale4 = <List<int>>[
    <int>[0, 1, 7, 8, 15],
    <int>[15, 14, 8, 1, 0],
  ];
  final records = <Uint8List>[
    Uint8List.fromList(<int>[0, 1, 0, 1, 0, 0]),
    _textRecord(2, 'Bitmap fixture'.codeUnits),
    _imageRecord(11, _bitmap(2, grayscale2)),
    _imageRecord(12, _bitmap(4, grayscale4)),
    _imageRecord(
      13,
      _bitmap(8, const <List<int>>[
        <int>[214, 215, 216],
      ]),
    ),
  ];
  final bytes = _pdb(records);
  final fixture = File(_fixturePath)..createSync(recursive: true);
  fixture.writeAsBytesSync(bytes, flush: true);
  stdout.writeln('Wrote ${fixture.path} (${bytes.length} bytes).');
}

Uint8List _bitmap(final int depth, final List<List<int>> rows) {
  final width = rows.first.length;
  final height = rows.length;
  final bitsPerRow = width * depth;
  final rowBytes = ((bitsPerRow + 15) ~/ 16) * 2;
  final bitmap = Uint8List(16 + rowBytes * height);
  ByteData.sublistView(bitmap)
    ..setUint16(0, width, Endian.big)
    ..setUint16(2, height, Endian.big)
    ..setUint16(4, rowBytes, Endian.big)
    ..setUint16(6, 0, Endian.big)
    ..setUint8(8, depth)
    ..setUint8(9, depth == 1 ? 0 : 1)
    ..setUint16(10, 0, Endian.big)
    ..setUint8(12, 0)
    ..setUint8(13, 0xff)
    ..setUint16(14, 0, Endian.big);
  for (var y = 0; y < height; y++) {
    if (rows[y].length != width) {
      throw StateError('Bitmap fixture rows must have equal widths.');
    }
    for (var x = 0; x < width; x++) {
      final index = rows[y][x];
      if (index < 0 || index >= (1 << depth)) {
        throw StateError('Pixel index $index does not fit $depth bits.');
      }
      final bitOffset = x * depth;
      bitmap[16 + y * rowBytes + bitOffset ~/ 8] |= index << (8 - depth - bitOffset % 8);
    }
  }
  return bitmap;
}

Uint8List _imageRecord(final int uid, final Uint8List bitmap) {
  final record = Uint8List(8 + bitmap.length);
  ByteData.sublistView(record)
    ..setUint16(0, uid, Endian.big)
    ..setUint16(2, 0, Endian.big)
    ..setUint16(4, bitmap.length, Endian.big)
    ..setUint8(6, 2)
    ..setUint8(7, 0);
  record.setRange(8, record.length, bitmap);
  return record;
}

Uint8List _textRecord(final int uid, final List<int> text) => Uint8List.fromList(<int>[
  uid >> 8,
  uid & 0xff,
  0,
  1,
  text.length >> 8,
  text.length & 0xff,
  0,
  0,
  text.length >> 8,
  text.length & 0xff,
  0,
  0,
  ...text,
]);

Uint8List _pdb(final List<Uint8List> records) {
  final headerLength = 78 + records.length * 8;
  final header = Uint8List(headerLength);
  header.setRange(0, 'Plucker Bitmap Formats'.length, ascii.encode('Plucker Bitmap Formats'));
  header.setRange(60, 68, ascii.encode('DataPlkr'));
  final table = ByteData.sublistView(header);
  table.setUint16(76, records.length, Endian.big);
  var offset = headerLength;
  for (var index = 0; index < records.length; index++) {
    table.setUint32(78 + index * 8, offset, Endian.big);
    offset += records[index].length;
  }
  final output = BytesBuilder(copy: false)..add(header);
  for (final record in records) {
    output.add(record);
  }
  return output.takeBytes();
}
