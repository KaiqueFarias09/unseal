@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/unseal.dart';

void main() {
  test('LRF text parses and survives browser wire serialization', () {
    final bytes = _buildLrf();
    expect(detectFormat(bytes), DetectedFormat.lrf);
    final book = Unseal.parse(bytes) as DocumentBook;
    expect(book.metadata.title, 'Web LRF');
    expect(book.files.html.single.plainText, 'Hello browser');

    final encoded = encodeBookWire(book);
    final decoded = decodeBookWire(encoded.$1, encoded.$2) as DocumentBook;
    expect(decoded.format, BookFormat.lrf);
    expect(decoded.files.html.single.plainText, 'Hello browser');
  });

  test('LRF legacy headers and LRX2 metadata work in the browser', () {
    final legacy = _asLegacyLrf(_buildLrf(), 800);
    expect(Unseal.parse(legacy).metadata.title, 'Web LRF');

    final lrx = _wrapLrx2(_buildLrf());
    expect(Unseal.readMetadataSync(lrx).title, 'Web LRF');
    expect(() => Unseal.parse(lrx), throwsA(isA<DrmProtectedException>()));
  });
}

Uint8List _buildLrf() {
  final bytes = List<int>.filled(0x58, 0, growable: true);
  const signature = <int>[0x4c, 0, 0x52, 0, 0x46, 0, 0, 0];
  bytes.setRange(0, signature.length, signature);
  _set16(bytes, 8, 1000);
  _set32(bytes, 0x0c, 1);
  _set64(bytes, 0x10, 5);
  const xml =
      '<BookInformation><Info><BookInfo><Title>Web LRF</Title>'
      '</BookInfo></Info></BookInformation>';
  final info = utf8.encode(xml);
  final compressed = ZLibEncoder().encode(info);
  _set16(bytes, 0x4c, compressed.length + 4);
  _set32(bytes, 0x54, info.length);
  bytes.addAll(compressed);

  final objects = <(int, int, List<int>)>[
    (1, 0x1c, <int>[0x7b, 0xf5, ..._u32(2)]),
    (2, 1, <int>[0x5c, 0xf5, 1, 0, ..._u32(3)]),
    (3, 2, _streamObject(<int>[3, 0xf5, ..._u32(4)])),
    (4, 6, _streamObject(<int>[3, 0xf5, ..._u32(5)])),
    (
      5,
      10,
      _streamObject(<int>[
        0xa1,
        0xf5,
        0,
        0,
        0,
        0,
        0xcc,
        0xf5,
        ..._u16('Hello browser'.length * 2),
        ..._utf16('Hello browser'),
        0xa2,
        0xf5,
      ]),
    ),
  ];
  final index = <int>[];
  for (final (id, type, body) in objects) {
    final offset = bytes.length;
    bytes.addAll(<int>[0, 0xf5, ..._u32(id), ..._u16(type), ...body, 1, 0xf5]);
    index.addAll(<int>[..._u32(id), ..._u32(offset), ..._u32(bytes.length - offset), ..._u32(0)]);
  }
  _set64(bytes, 0x18, bytes.length);
  bytes.addAll(index);
  return Uint8List.fromList(bytes);
}

Uint8List _asLegacyLrf(final Uint8List source, final int version) {
  const legacyMetadataStart = 0x53;
  const removedHeaderTail = 5;
  final sourceData = ByteData.sublistView(source);
  final objectCount = sourceData.getUint32(0x10, Endian.little);
  final sourceIndex = sourceData.getUint32(0x18, Endian.little);
  final bytes = Uint8List(source.length - removedHeaderTail);
  bytes.setRange(0, legacyMetadataStart, source);
  bytes.setRange(
    legacyMetadataStart,
    bytes.length,
    source,
    legacyMetadataStart + removedHeaderTail,
  );

  final data = ByteData.sublistView(bytes);
  data.setUint16(8, version, Endian.little);
  final indexOffset = sourceIndex - removedHeaderTail;
  _set64(bytes, 0x18, indexOffset);
  for (var entry = 0; entry < objectCount; entry++) {
    final oldEntry = sourceIndex + entry * 16;
    final newEntry = indexOffset + entry * 16;
    final oldObjectOffset = sourceData.getUint32(oldEntry + 4, Endian.little);
    data.setUint32(newEntry + 4, oldObjectOffset - removedHeaderTail, Endian.little);
  }
  return bytes;
}

Uint8List _wrapLrx2(final Uint8List lrf) {
  final bytes = <int>[
    ..._be32(12),
    0x66,
    0x74,
    0x79,
    0x70,
    0x4c,
    0x52,
    0x58,
    0x32,
    ..._be32(lrf.length + 8),
    0x62,
    0x62,
    0x65,
    0x62,
    ...lrf,
  ];
  return Uint8List.fromList(bytes);
}

List<int> _streamObject(final List<int> stream) => <int>[
  0x54,
  0xf5,
  0,
  0,
  4,
  0xf5,
  ..._u32(stream.length),
  5,
  0xf5,
  ...stream,
  6,
  0xf5,
];

List<int> _utf16(final String text) => <int>[for (final unit in text.codeUnits) ..._u16(unit)];

List<int> _u16(final int value) => <int>[value & 255, (value >> 8) & 255];

List<int> _u32(final int value) => <int>[
  value & 255,
  (value >> 8) & 255,
  (value >> 16) & 255,
  (value >> 24) & 255,
];

List<int> _be32(final int value) => <int>[
  (value >> 24) & 255,
  (value >> 16) & 255,
  (value >> 8) & 255,
  value & 255,
];

void _set16(final List<int> bytes, final int offset, final int value) =>
    bytes.setRange(offset, offset + 2, _u16(value));

void _set32(final List<int> bytes, final int offset, final int value) =>
    bytes.setRange(offset, offset + 4, _u32(value));

void _set64(final List<int> bytes, final int offset, final int value) {
  _set32(bytes, offset, value);
  _set32(bytes, offset + 4, 0);
}
