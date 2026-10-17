import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Synthetic DjVu IFF structures for parser boundary tests.
///
/// The JPEG bytes come from the generated `tiny.jpg` fixture. These builders
/// exercise structure, not interoperability with a third-party encoder.
Uint8List djvuJpegPage(
  final Uint8List jpeg, {
  final String? text,
  final Uint8List? txtz,
  final int width = 8,
  final int height = 8,
}) {
  final chunks = <int>[
    ..._chunk('INFO', <int>[..._int16(width), ..._int16(height), 26, 0, 44, 1, 22, 1]),
    ..._chunk('BGjp', jpeg),
    if (text != null)
      ..._chunk('TXTa', <int>[..._int24(utf8.encode(text).length), ...utf8.encode(text), 1]),
    if (txtz != null) ..._chunk('TXTz', txtz),
  ];
  return Uint8List.fromList(<int>[...ascii.encode('AT&T'), ..._form('DJVU', chunks)]);
}

/// Extracts the data of the [nth] chunk with [id] anywhere in [bytes].
///
/// Corpus fixtures ship as whole documents; tests pull individual chunks
/// (TXTz, NAVM, Djbz) out of them to build focused synthetic documents.
Uint8List djvuCorpusChunk(final Uint8List bytes, final String id, [final int nth = 0]) {
  final chunks = djvuCorpusChunks(bytes, id);
  if (nth >= chunks.length) {
    throw StateError('Corpus fixture has no $id chunk #$nth.');
  }
  return chunks[nth];
}

/// All chunk payloads with [id], in document order.
List<Uint8List> djvuCorpusChunks(final Uint8List bytes, final String id) {
  final view = ByteData.sublistView(bytes);
  final result = <Uint8List>[];
  void visit(final int start, final int end) {
    var offset = start;
    while (offset + 8 <= end) {
      final chunkId = String.fromCharCodes(bytes, offset, offset + 4);
      final length = view.getUint32(offset + 4);
      final dataStart = offset + 8;
      final dataEnd = dataStart + length;
      final next = dataEnd == end ? dataEnd : dataEnd + (length & 1);
      if (chunkId == id) {
        result.add(Uint8List.sublistView(bytes, dataStart, dataEnd));
      }
      if (chunkId == 'FORM') visit(dataStart + 4, dataEnd);
      offset = next;
    }
  }

  visit(4, bytes.length);
  return result;
}

/// Builds a standalone page around arbitrary extra chunks (TXTz, INCL, Sjbz).
Uint8List djvuPageWithChunks(
  final Uint8List jpeg, {
  final List<(String, Uint8List)> chunks = const <(String, Uint8List)>[],
  final int width = 8,
  final int height = 8,
}) {
  final encoded = <int>[
    ..._chunk('INFO', <int>[..._int16(width), ..._int16(height), 26, 0, 44, 1, 22, 1]),
    ..._chunk('BGjp', jpeg),
    for (final (id, data) in chunks) ..._chunk(id, data),
  ];
  return Uint8List.fromList(<int>[...ascii.encode('AT&T'), ..._form('DJVU', encoded)]);
}

/// A bundled document whose DJVM carries a top-level outline chunk.
Uint8List djvuBundleWithOutline(final List<Uint8List> standalonePages, final Uint8List navm) {
  final components = <List<int>>[for (final page in standalonePages) page.sublist(4)];
  final dirmDataLength = 3 + components.length * 4;
  final directoryChunkLength = 8 + dirmDataLength + (dirmDataLength & 1);
  var offset = 4 + 8 + 4 + directoryChunkLength + 8 + navm.length + (navm.length & 1);
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
    ..._form('DJVM', <int>[
      ...directory,
      ..._chunk('NAVM', navm),
      for (final c in components) ...c,
    ]),
  ]);
}

/// Writes an indirect DjVu directory: [indexBytes] next to the named
/// component files inside [directory]. Returns the index file path.
String djvuWriteIndirect(
  final Directory directory,
  final Uint8List indexBytes,
  final Map<String, Uint8List> components,
) {
  for (final entry in components.entries) {
    File('${directory.path}${Platform.pathSeparator}${entry.key}').writeAsBytesSync(entry.value);
  }
  final indexPath = '${directory.path}${Platform.pathSeparator}index-${components.length}.djvu';
  File(indexPath).writeAsBytesSync(indexBytes);
  return indexPath;
}

/// Builds an indirect DjVu index that lists [componentNames] by name.
///
/// The DIRM header flags the document indirect and omits offsets; the BZZ
/// name table is copied verbatim from [namesTable] (sizes, flags, and
/// NUL-terminated strings), so tests can splice real corpus name tables.
Uint8List djvuIndirectIndex(final Uint8List namesTable, final List<String> componentNames) =>
    Uint8List.fromList(<int>[
      ...ascii.encode('AT&T'),
      ..._form(
        'DJVM',
        _chunk('DIRM', <int>[0x01, ..._int16(componentNames.length), ...namesTable]),
      ),
    ]);

Uint8List djvuUnsupportedPage() => Uint8List.fromList(<int>[
  ...ascii.encode('AT&T'),
  ..._form('DJVU', <int>[
    ..._chunk('INFO', <int>[0, 8, 0, 8, 26, 0, 44, 1, 22, 1]),
    ..._chunk('Smmr', <int>[0]),
  ]),
]);

/// Wraps one externally sourced JB2 Sjbz stream in a minimal standalone page.
///
/// This removes co-located visual layers so tests can exercise the decoded
/// bilevel mask without implying that the other layers in the source page are
/// supported.
Uint8List djvuJb2Page(
  final Uint8List encoded, {
  required final int width,
  required final int height,
}) => Uint8List.fromList(<int>[
  ...ascii.encode('AT&T'),
  ..._form('DJVU', <int>[
    ..._chunk('INFO', <int>[..._int16(width), ..._int16(height), 26, 0, 44, 1, 22, 1]),
    ..._chunk('Sjbz', encoded),
  ]),
]);

/// A browser-safe page derived from the public-domain cable fixture.
///
/// Only the first page's Sjbz bytes are retained here; its IW44 layers are
/// omitted to exercise the JB2-only display path.
Uint8List licensedDjvuJb2Page() => djvuJb2Page(
  base64Decode(
    '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',
  ),
  width: 2550,
  height: 3301,
);

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

// TXTz payload of cyrillic.djvu page 1 and the NAVM chunk of links.djvu,
// verbatim from the tracked public-domain corpus (PROVENANCE.md); browser
// tests cannot read the filesystem, so the compressed chunks travel inline.
const String cyrillicTxtzBase64 =
    '//xAiIkuSX+i3aQsx9NLMnbiQRpS0zSEnk7lQBOG50s+DRRH1PhDRCNqQZCSzv2RLCsfLIIzyF+17MKahDSTVO5lkQiGi2YqJGEu3jp/A3ObuElIqj92qUFlCsGFEbON2JTRrBc23Gb0YF+lMUgaQZXJZd+qPyGucDq89j58NcODabeTx/emlHRD+kOoSB4w9A3XuCxeJt8EAOp9l3VKoJVymzzkf9nRn05yea4529KuJ2bO7WwuIpfr5ZY4yOKCXPfFwWc6kOITia3qm+FUAsYfBietHiV5rAOFTXjtKAsZ+rvl8nwsY1wVuAdvZou9s+//Z/tgAeFVbbFvbzStqQgpIDjnnTIvbJAuSyhJHHRcI4O2YpttBhwUrrtOuxJspS56HjbTiyDyvOP3gLfCs7hfXEorG4L/qzONXXdpKvspkiPYYagOfXkRb32pIbLV97AMJ8U4SoYJANfPwEdNjT9ODq/uVn+VSnlQJwRzxVdGZfKvSDoftvlDfqYtMrtxOFHLujHCTwGdco6qmlaT7s8kfnuyxOsDV/8HclD7bYabOre19b6bjbQF2tICcr9EOLlFZxxVR4voOPdsg4tgS9HwCP5640mQFQZeRUPswUSLTMAyi6IyhMrN+fYb96ElH2oQLJZp3Swr';

// Generated by tool/fuzz/image_bits.dart; also stored as the tiny.jpg fixture.
final Uint8List tinyJpeg = Uint8List.fromList(
  base64Decode(
    '/9j/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAALCAAIAAgBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP//Z',
  ),
);
