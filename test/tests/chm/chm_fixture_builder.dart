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

/// A generated legacy-codepage CHM with a non-ASCII filename, title, topic,
/// and contents label.
Uint8List chmLegacyCodePageFixture({required final int codePage}) {
  final lcid = switch (codePage) {
    1251 => 0x0419,
    1252 => 0x0409,
    1256 => 0x0401,
    _ => throw UnsupportedError('Unsupported generated CHM codepage.'),
  };
  final topicPath = switch (codePage) {
    1251 => 'chapter-глава.html',
    1252 => 'chapter-café.html',
    1256 => 'chapter-سلام.html',
    _ => throw UnsupportedError('Unsupported generated CHM codepage.'),
  };
  final title = switch (codePage) {
    1251 => 'Русский CHM',
    1252 => 'Café CHM',
    1256 => 'دليل CHM',
    _ => throw UnsupportedError('Unsupported generated CHM codepage.'),
  };
  final tocLabel = switch (codePage) {
    1251 => 'Главная',
    1252 => 'Été',
    1256 => 'الرئيسية',
    _ => throw UnsupportedError('Unsupported generated CHM codepage.'),
  };
  final body = switch (codePage) {
    1251 => 'Привет мир',
    1252 => 'Très bien café',
    1256 => 'سلام عليكم',
    _ => throw UnsupportedError('Unsupported generated CHM codepage.'),
  };

  final system = BytesBuilder()..add(const <int>[3, 0, 0, 0]);
  void field(final int type, final List<int> value) {
    system.add(<int>[type & 0xff, type >> 8, value.length & 0xff, value.length >> 8]);
    system.add(value);
  }

  field(2, _legacyBytes(topicPath, codePage));
  field(3, _legacyBytes(title, codePage));
  field(4, <int>[lcid & 0xff, (lcid >> 8) & 0xff, (lcid >> 16) & 0xff, lcid >> 24]);
  field(0, ascii.encode('contents.hhc'));

  final files = <(String, Uint8List)>[
    ('/#SYSTEM', system.toBytes()),
    ('/$topicPath', Uint8List.fromList(_legacyBytes('<html><body>$body</body></html>', codePage))),
    (
      '/contents.hhc',
      Uint8List.fromList(
        _legacyBytes(
          '<ul><li><object><param name="Name" value="$tocLabel">'
          '<param name="Local" value="$topicPath"></object></li></ul>',
          codePage,
        ),
      ),
    ),
  ];
  final data = BytesBuilder();
  final listing = BytesBuilder();
  for (final file in files) {
    final name = _legacyBytes(file.$1, codePage);
    listing.add(_enc(name.length));
    listing.add(name);
    listing.add(_enc(0));
    listing.add(_enc(data.length));
    listing.add(_enc(file.$2.length));
    data.add(file.$2);
  }

  const chunkSize = 4096;
  final chunk = Uint8List(chunkSize);
  final chunkView = ByteData.sublistView(chunk);
  chunk.setRange(0, 4, ascii.encode('PMGL'));
  chunkView.setUint32(4, chunkSize - 20 - listing.length, Endian.little);
  chunkView.setInt32(12, -1, Endian.little);
  chunkView.setInt32(16, -1, Endian.little);
  chunk.setRange(20, 20 + listing.length, listing.toBytes());

  final header = Uint8List(96 + 84);
  final view = ByteData.sublistView(header);
  header.setRange(0, 4, ascii.encode('ITSF'));
  view.setUint32(4, 3, Endian.little);
  view.setUint32(8, 96, Endian.little);
  view.setUint32(0x48, 96, Endian.little);
  view.setUint32(0x50, 84 + chunkSize, Endian.little);
  view.setUint32(0x58, 96 + 84 + chunkSize, Endian.little);
  header.setRange(96, 100, ascii.encode('ITSP'));
  view.setUint32(96 + 8, 84, Endian.little);
  view.setUint32(96 + 16, chunkSize, Endian.little);
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
  return lzxRawFrameBytes(text.codeUnits);
}

/// LZX uncompressed block for direct decoder regression tests.
Uint8List lzxRawFrameBytes(
  final List<int> data, {
  final int? intelFileSize,
  final bool includeIntelHeader = true,
}) {
  final length = data.length;
  var bits = includeIntelHeader ? (intelFileSize == null ? '0' : '1') : '';
  if (includeIntelHeader && intelFileSize != null) {
    bits += (intelFileSize >> 16).toRadixString(2).padLeft(16, '0');
    bits += (intelFileSize & 0xffff).toRadixString(2).padLeft(16, '0');
  }
  bits +=
      '011'
      '${(length >> 8).toRadixString(2).padLeft(16, '0')}'
      '${(length & 0xff).toRadixString(2).padLeft(8, '0')}';
  bits = bits.padRight((bits.length + 15) ~/ 16 * 16, '0');
  final source = <int>[];
  for (var index = 0; index < bits.length; index += 16) {
    final word = int.parse(bits.substring(index, index + 16), radix: 2);
    source.add(word & 0xff);
    source.add(word >> 8);
  }
  source.addAll(<int>[1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, ...data]);
  return Uint8List.fromList(source);
}

List<int> _legacyBytes(final String text, final int codePage) {
  final bytes = <int>[];
  for (final rune in text.runes) {
    if (rune < 0x80) {
      bytes.add(rune);
    } else if (codePage == 1251) {
      bytes.add(switch (rune) {
        >= 0x0410 && <= 0x042f => rune - 0x0410 + 0xc0,
        >= 0x0430 && <= 0x044f => rune - 0x0430 + 0xe0,
        0x0401 => 0xa8,
        0x0451 => 0xb8,
        _ => throw UnsupportedError('Fixture contains an unmapped CP1251 character.'),
      });
    } else if (codePage == 1256) {
      final byte = _cp1256[rune];
      if (byte == null) throw UnsupportedError('Fixture contains an unmapped CP1256 character.');
      bytes.add(byte);
    } else if (codePage == 1252) {
      bytes.add(switch (rune) {
        0x00c9 => 0xc9,
        0x00e8 => 0xe8,
        0x00e9 => 0xe9,
        _ => throw UnsupportedError('Fixture contains an unmapped CP1252 character.'),
      });
    } else {
      throw UnsupportedError('Unsupported generated CHM codepage.');
    }
  }
  return bytes;
}

const _cp1256 = <int, int>{
  0x0626: 0xc6,
  0x0627: 0xc7,
  0x0629: 0xc9,
  0x062f: 0xcf,
  0x0631: 0xd1,
  0x0633: 0xd3,
  0x0639: 0xda,
  0x0643: 0xdf,
  0x0644: 0xe1,
  0x0645: 0xe3,
  0x0646: 0xe2,
  0x064a: 0xed,
};
