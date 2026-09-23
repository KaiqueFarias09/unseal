import 'dart:convert';
import 'dart:typed_data';

/// Small uncompressed ITSF v3 file for browser and corrupt-input tests.
Uint8List chmFixture({final bool withContents = true}) {
  final system = BytesBuilder()..add(const <int>[3, 0, 0, 0]);
  void field(final int type, final String value) {
    final bytes = <int>[...utf8.encode(value), 0];
    system.add(<int>[type, 0, bytes.length, 0, ...bytes]);
  }

  field(2, 'index.html');
  field(3, 'Small CHM');
  if (withContents) field(0, 'contents.hhc');

  final files = <String, Uint8List>{
    '/#SYSTEM': system.toBytes(),
    '/index.html': Uint8List.fromList(utf8.encode('<html><body><h1>Welcome</h1></body></html>')),
    '/chapter.html': Uint8List.fromList(utf8.encode('<html><body>Second chapter</body></html>')),
    '/style.css': Uint8List.fromList(utf8.encode('body { color: navy; }')),
    if (withContents)
      '/contents.hhc': Uint8List.fromList(
        utf8.encode(
          '<ul><li><object><param name="Name" value="Start">'
          '<param name="Local" value="index.html"></object>'
          '<ul><li><object><param name="Name" value="Next">'
          '<param name="Local" value="chapter.html#section"></object></li></ul></li></ul>',
        ),
      ),
  };
  final data = BytesBuilder();
  final listing = BytesBuilder();
  for (final source in files.entries) {
    final name = utf8.encode(source.key);
    listing.add(_enc(name.length));
    listing.add(name);
    listing.add(_enc(0));
    listing.add(_enc(data.length));
    listing.add(_enc(source.value.length));
    data.add(source.value);
  }
  final chunk = Uint8List(4096);
  final chunkView = ByteData.sublistView(chunk);
  chunk.setRange(0, 4, ascii.encode('PMGL'));
  chunkView.setUint32(4, 4096 - 20 - listing.length, Endian.little);
  chunkView.setInt32(12, -1, Endian.little);
  chunkView.setInt32(16, -1, Endian.little);
  chunk.setRange(20, 20 + listing.length, listing.toBytes());

  final header = Uint8List(96 + 84);
  final view = ByteData.sublistView(header);
  header.setRange(0, 4, ascii.encode('ITSF'));
  view.setUint32(4, 3, Endian.little);
  view.setUint32(8, 96, Endian.little);
  view.setUint32(0x48, 96, Endian.little);
  view.setUint32(0x50, 84 + 4096, Endian.little);
  view.setUint32(0x58, 96 + 84 + 4096, Endian.little);
  header.setRange(96, 100, ascii.encode('ITSP'));
  view.setUint32(96 + 8, 84, Endian.little);
  view.setUint32(96 + 16, 4096, Endian.little);
  view.setUint32(96 + 32, 0, Endian.little);
  view.setUint32(96 + 36, 0, Endian.little);
  view.setUint32(96 + 44, 1, Endian.little);
  return (BytesBuilder()
        ..add(header)
        ..add(chunk)
        ..add(data.toBytes()))
      .toBytes();
}

List<int> _enc(final int value) {
  if (value < 128) return <int>[value];
  final parts = <int>[];
  var number = value;
  do {
    parts.insert(0, number & 0x7f);
    number >>= 7;
  } while (number != 0);
  for (var i = 0; i < parts.length - 1; i++) {
    parts[i] |= 0x80;
  }
  return parts;
}

/// LZX stream containing one uncompressed block for decoder portability tests.
Uint8List lzxRawFrame(final String text) {
  final length = text.length;
  final bits =
      '0'
      '011'
      '${(length >> 8).toRadixString(2).padLeft(16, '0')}'
      '${(length & 0xff).toRadixString(2).padLeft(8, '0')}'
      '0000';
  final source = <int>[];
  for (var index = 0; index < bits.length; index += 16) {
    final word = int.parse(bits.substring(index, index + 16), radix: 2);
    source.add(word & 0xff);
    source.add(word >> 8);
  }
  source.addAll(<int>[1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, ...text.codeUnits]);
  return Uint8List.fromList(source);
}
