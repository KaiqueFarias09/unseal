import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/lrx.dart' as lrx;
import 'package:unseal/unseal.dart';

void main() {
  final lrf = File('test/resources/books/lrf/original.lrf').readAsBytesSync();

  test('reads only the plaintext metadata exposed by an LRX2 BBeB box', () {
    final bytes = _wrapLrx2(lrf);
    expect(detectFormat(bytes), DetectedFormat.lrx);
    expect(lrx.readLrxMetadata(bytes).title, 'Unseal LRF Fixture');
    expect(Unseal.readMetadataSync(bytes).title, 'Unseal LRF Fixture');
    expect(Unseal.readMetadataSync(bytes).format, BookFormat.lrf);
    expect(() => Unseal.parse(bytes), throwsA(isA<DrmProtectedException>()));
  });

  test('rejects legacy LRX books as DRM protected', () {
    final bytes = Uint8List.fromList(<int>[0, 0, 0, 16, 0x4c, 0x52, 0x58, 0]);
    expect(detectFormat(bytes), DetectedFormat.lrx);
    expect(() => lrx.readLrxMetadata(bytes), throwsA(isA<DrmProtectedException>()));
    expect(() => Unseal.parse(bytes), throwsA(isA<DrmProtectedException>()));
  });

  test('rejects malformed LRX2 box sizes with a typed parse failure', () {
    final bytes = _wrapLrx2(lrf);
    bytes[0] = 0xff;
    expect(() => lrx.readLrxMetadata(bytes), throwsA(isA<InvalidBookException>()));
  });

  test('limits LRX2 outer box scanning', () {
    final bytes = <int>[
      ..._u32(12),
      0x66,
      0x74,
      0x79,
      0x70,
      0x4c,
      0x52,
      0x58,
      0x32,
      for (var index = 0; index < 1024; index++) ...<int>[..._u32(8), 0x66, 0x72, 0x65, 0x65],
      ..._u32(lrf.length + 8),
      0x62,
      0x62,
      0x65,
      0x62,
      ...lrf,
    ];
    expect(
      () => lrx.readLrxMetadata(Uint8List.fromList(bytes)),
      throwsA(isA<InvalidBookException>()),
    );
  });
}

Uint8List _wrapLrx2(final Uint8List lrf) {
  final bytes = <int>[
    ..._u32(12),
    0x66,
    0x74,
    0x79,
    0x70,
    0x4c,
    0x52,
    0x58,
    0x32,
    ..._u32(lrf.length + 8),
    0x62,
    0x62,
    0x65,
    0x62,
    ...lrf,
  ];
  return Uint8List.fromList(bytes);
}

List<int> _u32(final int value) => <int>[
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];
