import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _fixturePath = 'test/resources/books/format_expansion/plucker-bitmap-variants.pdb';
const _colorFixturePath = 'test/resources/books/format_expansion/plucker-bitmap-color-variants.pdb';

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

  final colorRecords = <Uint8List>[
    Uint8List.fromList(<int>[0, 1, 0, 1, 0, 0]),
    _textRecord(2, 'Palm color bitmap fixture'.codeUnits),
    _imageRecord(
      21,
      _customColorBitmap(4, const <List<int>>[
        <int>[0, 2, 5],
        <int>[15, 7, 3],
      ]),
    ),
    _imageRecord(
      22,
      _customColorBitmap(8, const <List<int>>[
        <int>[0, 128, 255],
      ]),
    ),
    _imageRecord(
      23,
      _directColorBitmap(const <List<int>>[
        <int>[0xf800, 0x07e0, 0x001f],
        <int>[0xffff, 0x0000, 0x8410],
      ]),
    ),
  ];
  final colorBytes = _pdb(colorRecords, title: 'Plucker Palm Color Formats');
  final colorFixture = File(_colorFixturePath)..createSync(recursive: true);
  colorFixture.writeAsBytesSync(colorBytes, flush: true);
  stdout.writeln('Wrote ${colorFixture.path} (${colorBytes.length} bytes).');
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

Uint8List _customColorBitmap(final int depth, final List<List<int>> rows) {
  final width = rows.first.length;
  final height = rows.length;
  final entries = List<(int, int, int)>.generate(
    1 << depth,
    (final index) => (index, (index * 73) & 0xff, (index * 151) & 0xff),
  ).reversed.toList();
  final rowBytes = ((width * depth + 15) ~/ 16) * 2;
  final pixelOffset = 18 + entries.length * 4;
  final bitmap = Uint8List(pixelOffset + rowBytes * height);
  ByteData.sublistView(bitmap)
    ..setUint16(0, width, Endian.big)
    ..setUint16(2, height, Endian.big)
    ..setUint16(4, rowBytes, Endian.big)
    ..setUint16(6, 0x4000, Endian.big)
    ..setUint8(8, depth)
    ..setUint8(9, 1)
    ..setUint8(13, 0xff)
    ..setUint16(16, entries.length, Endian.big);
  for (var index = 0; index < entries.length; index++) {
    final (paletteIndex, red, green) = entries[index];
    final blue = 255 - paletteIndex;
    final offset = 18 + index * 4;
    bitmap
      ..[offset] = paletteIndex
      ..[offset + 1] = red
      ..[offset + 2] = green
      ..[offset + 3] = blue;
  }
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = rows[y][x];
      final bitOffset = x * depth;
      bitmap[pixelOffset + y * rowBytes + bitOffset ~/ 8] |= index << (8 - depth - bitOffset % 8);
    }
  }
  return bitmap;
}

Uint8List _directColorBitmap(final List<List<int>> rows) {
  final width = rows.first.length;
  final height = rows.length;
  final rowBytes = ((width * 16 + 15) ~/ 16) * 2;
  final bitmap = Uint8List(24 + rowBytes * height);
  ByteData.sublistView(bitmap)
    ..setUint16(0, width, Endian.big)
    ..setUint16(2, height, Endian.big)
    ..setUint16(4, rowBytes, Endian.big)
    ..setUint16(6, 0x0400, Endian.big)
    ..setUint8(8, 16)
    ..setUint8(9, 1)
    ..setUint8(13, 0xff)
    ..setUint8(16, 5)
    ..setUint8(17, 6)
    ..setUint8(18, 5);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      ByteData.sublistView(bitmap).setUint16(24 + y * rowBytes + x * 2, rows[y][x], Endian.big);
    }
  }
  return bitmap;
}

Uint8List _pdb(final List<Uint8List> records, {final String title = 'Plucker Bitmap Formats'}) {
  final headerLength = 78 + records.length * 8;
  final header = Uint8List(headerLength);
  header.setRange(0, title.length, ascii.encode(title));
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
