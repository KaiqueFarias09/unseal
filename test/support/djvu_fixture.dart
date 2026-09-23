import 'dart:convert';
import 'dart:typed_data';

/// Synthetic DjVu IFF structures for parser boundary tests.
///
/// The JPEG bytes come from the generated `tiny.jpg` fixture. These builders
/// exercise structure, not interoperability with a third-party encoder.
Uint8List djvuJpegPage(
  final Uint8List jpeg, {
  final String? text,
  final int width = 8,
  final int height = 8,
}) {
  final chunks = <int>[
    ..._chunk('INFO', <int>[..._int16(width), ..._int16(height), 26, 0, 44, 1, 22, 1]),
    ..._chunk('BGjp', jpeg),
    if (text != null)
      ..._chunk('TXTa', <int>[..._int24(utf8.encode(text).length), ...utf8.encode(text), 1]),
  ];
  return Uint8List.fromList(<int>[...ascii.encode('AT&T'), ..._form('DJVU', chunks)]);
}

Uint8List djvuUnsupportedPage() => Uint8List.fromList(<int>[
  ...ascii.encode('AT&T'),
  ..._form('DJVU', <int>[
    ..._chunk('INFO', <int>[0, 8, 0, 8, 26, 0, 44, 1, 22, 1]),
    ..._chunk('BG44', <int>[0, 1, 2]),
  ]),
]);

Uint8List djvuBundle(final List<Uint8List> standalonePages) {
  final components = <List<int>>[for (final page in standalonePages) page.sublist(4)];
  final directoryLength = 3 + components.length * 4;
  final directoryChunkLength = 8 + directoryLength + (directoryLength & 1);
  var offset = 4 + 8 + 4 + directoryChunkLength;
  final offsets = <int>[];
  for (final component in components) {
    offsets.add(offset);
    offset += component.length;
  }
  final directory = _chunk('DIRM', <int>[
    0x81,
    ..._int16(components.length),
    for (final value in offsets) ..._int32(value),
  ]);
  return Uint8List.fromList(<int>[
    ...ascii.encode('AT&T'),
    ..._form('DJVM', <int>[...directory, for (final component in components) ...component]),
  ]);
}

List<int> _form(final String type, final List<int> chunks) =>
    _chunk('FORM', <int>[...ascii.encode(type), ...chunks]);

List<int> _chunk(final String type, final List<int> bytes) => <int>[
  ...ascii.encode(type),
  ..._int32(bytes.length),
  ...bytes,
  if (bytes.length.isOdd) 0,
];

List<int> _int16(final int value) => <int>[value >> 8 & 255, value & 255];

List<int> _int24(final int value) => <int>[value >> 16 & 255, value >> 8 & 255, value & 255];

List<int> _int32(final int value) => <int>[
  value >> 24 & 255,
  value >> 16 & 255,
  value >> 8 & 255,
  value & 255,
];
