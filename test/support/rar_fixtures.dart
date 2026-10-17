import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';

// Byte-packing builders read best as sequential field writes.
// ignore_for_file: cascade_invocations

/// The page payload the generated RAR fixtures carry when no explicit
/// content is given: a valid JPEG magic plus a few filler bytes.
final Uint8List tinyJpegPage = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 1, 2, 3, 0xFF, 0xD9]);

/// A minimal ComicInfo document for metadata-parity fixtures.
const String comicInfoXml =
    '<ComicInfo><Series>Session Parity</Series><Title>Session Parity 1</Title>'
    '<Writer>Author A</Writer><Manga>YesAndRightToLeft</Manga></ComicInfo>';

/// Builds a RAR 4 archive with one stored entry per name.
Uint8List buildRar4(
  final List<String> names, {
  final int flags = 0x8000,
  final bool withHighSizes = false,
  final bool withSalt = false,
  final int nameSizeOvershoot = 0,
  final int method = 0x30,
  final int unpackVersion = 29,
}) {
  return buildRar4Files(
    {for (final name in names) name: tinyJpegPage},
    flags: flags,
    withHighSizes: withHighSizes,
    withSalt: withSalt,
    nameSizeOvershoot: nameSizeOvershoot,
    method: method,
    unpackVersion: unpackVersion,
  );
}

/// Builds a RAR 4 archive with explicit per-entry content.
///
/// The field overrides exist to exercise hostile headers: [method] and
/// [unpackVersion] steer the payload grammar (defaults are the stored
/// 2.9 stream), [declaredPackedSize]/[declaredUnpackedSize] forge the
/// declared sizes the bomb guards read, and [fileCrc] declares a
/// payload CRC the session verifies (the eager reader ignores it).
Uint8List buildRar4Files(
  final Map<String, List<int>> files, {
  final int flags = 0x8000,
  final bool withHighSizes = false,
  final bool withSalt = false,
  final int nameSizeOvershoot = 0,
  final int method = 0x30,
  final int unpackVersion = 29,
  final int? declaredPackedSize,
  final int? declaredUnpackedSize,
  final int? fileCrc,
}) {
  final builder = BytesBuilder(copy: false);
  builder.add([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);

  for (final entry in files.entries) {
    final name = entry.key;
    final content = entry.value;
    final nameBytes = name.codeUnits;
    final extras = (withHighSizes ? 8 : 0) + (withSalt ? 8 : 0);
    final header = ByteData(32 + nameBytes.length + extras);
    var f = 0;
    header.setUint16(f, 0, Endian.little);
    f += 2; // crc (unchecked)
    header.setUint8(f, 0x74);
    f += 1; // file header
    header.setUint16(f, flags, Endian.little);
    f += 2;
    header.setUint16(f, header.lengthInBytes, Endian.little);
    f += 2;
    header.setUint32(f, declaredPackedSize ?? content.length, Endian.little);
    f += 4; // packed
    header.setUint32(f, declaredUnpackedSize ?? content.length, Endian.little);
    f += 4; // unpacked
    header.setUint8(f, 0);
    f += 1; // host OS
    header.setUint32(f, fileCrc ?? 0, Endian.little);
    f += 4; // file crc
    header.setUint32(f, 0, Endian.little);
    f += 4; // file time
    header.setUint8(f, unpackVersion);
    f += 1; // unpack version
    header.setUint8(f, method);
    f += 1; // method
    header.setUint16(f, nameBytes.length + nameSizeOvershoot, Endian.little);
    f += 2;
    header.setUint32(f, 0x20, Endian.little);
    f += 4; // attributes
    f += extras; // high sizes / salt live between attributes and name
    header.buffer.asUint8List().setRange(f, f + nameBytes.length, nameBytes);
    builder.add(header.buffer.asUint8List());
    if (nameSizeOvershoot == 0) {
      builder.add(content);
    }
  }

  if (nameSizeOvershoot == 0) {
    final end = ByteData(7);
    end.setUint8(2, 0x7B);
    end.setUint16(3, 0x4000, Endian.little);
    end.setUint16(5, 7, Endian.little);
    builder.add(end.buffer.asUint8List());
  }

  // With an overshooting name size the declared name end already
  // sits past the buffer; no data block is needed.
  return builder.takeBytes();
}

/// Builds a RAR 5 archive: signature, main header, one stored entry
/// per name and the end-of-archive block — the layout real archivers
/// produce.
Uint8List buildRar5(
  final List<String> names, {
  final int method = 0,
  final int fileFlags = 0,
  final bool trailingGarbage = false,
  final bool withExtraArea = false,
  final int archiveFlags = 0,
  final int dictExp = 0,
  final int version = 0,
  final bool solid = false,
  final int splitBlockFlags = 0,
  final List<int>? extraRecord,
  final int? headerCrcOverride,
  final bool withEndBlock = true,
  final List<int>? serviceData,
}) {
  return buildRar5Files(
    {for (final name in names) name: tinyJpegPage},
    method: method,
    fileFlags: fileFlags,
    trailingGarbage: trailingGarbage,
    withExtraArea: withExtraArea,
    archiveFlags: archiveFlags,
    dictExp: dictExp,
    version: version,
    solid: solid,
    splitBlockFlags: splitBlockFlags,
    extraRecord: extraRecord,
    headerCrcOverride: headerCrcOverride,
    withEndBlock: withEndBlock,
    serviceData: serviceData,
  );
}

/// Builds a RAR 5 archive with explicit per-entry content.
///
/// The knobs exist to exercise the header contract and hostile input:
/// [method]/[dictExp]/[version]/[solid] steer the compression-info
/// vint, [dataCrc] declares a payload CRC (setting the file flag that
/// carries it) the session verifies, [archiveFlags] feeds the main
/// header (volume/solid bits), [splitBlockFlags] sets the not-first/
/// not-last block flags, [extraRecord] appends a raw extra-area record
/// (size, type, payload) such as encryption or hash, and
/// [headerCrcOverride] forges the header CRC the walk must reject.
Uint8List buildRar5Files(
  final Map<String, List<int>> files, {
  final int method = 0,
  final int fileFlags = 0,
  final bool trailingGarbage = false,
  final bool withExtraArea = false,
  final int? dataCrc,
  final int archiveFlags = 0,
  final int dictExp = 0,
  final int version = 0,
  final bool solid = false,
  final int splitBlockFlags = 0,
  final List<int>? extraRecord,
  final int? headerCrcOverride,
  final bool withEndBlock = true,
  final List<int>? serviceData,
}) {
  final builder = BytesBuilder(copy: false);
  builder.add([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]);

  _addRar5Block(
    builder,
    type: 1,
    headerFlags: 0,
    write: (final body) {
      body.vint(archiveFlags);
      if (archiveFlags & 0x0002 != 0) {
        body.vint(0); // volume number
      }
    },
    headerCrcOverride: headerCrcOverride,
  );
  var index = 0;
  for (final entry in files.entries) {
    final name = entry.key;
    final content = Uint8List.fromList(entry.value);
    final nameBytes = convert.utf8.encode(name);
    final includeExtraArea = (withExtraArea && index == 0) || extraRecord != null;
    final extraArea = extraRecord ?? (includeExtraArea ? [6, 3, 1, 0, 0, 0, 0] : null);
    final crcFlag = dataCrc == null ? 0 : 0x0004;
    _addRar5Block(
      builder,
      type: 2,
      headerFlags: 0x0002 | (includeExtraArea ? 0x0001 : 0) | crcFlag | splitBlockFlags,
      data: content,
      extraArea: extraArea,
      headerCrcOverride: headerCrcOverride,
      write: (final body) {
        body.vint(fileFlags | crcFlag);
        body.vint(content.length); // unpacked size
        body.vint(0x20); // attributes
        if (fileFlags & 0x0002 != 0) {
          body.uint32(0x5F000000); // mtime
        }
        if (crcFlag != 0) {
          body.uint32(dataCrc!);
        } else if (fileFlags & 0x0004 != 0) {
          body.uint32(0); // data crc (default fixtures leave it at 0)
        }
        body.vint(
          (method << 7) | (dictExp << 10) | (solid ? 0x40 : 0) | version,
        ); // compression info
        body.addByte(0); // host OS
        body.vint(nameBytes.length);
        body.add(nameBytes);
      },
    );
    index++;
  }
  if (serviceData != null) {
    final nameBytes = convert.utf8.encode('CMT');
    _addRar5Block(
      builder,
      type: 3,
      headerFlags: 0x0002,
      data: Uint8List.fromList(serviceData),
      headerCrcOverride: headerCrcOverride,
      write: (final body) {
        body.vint(0); // file flags
        body.vint(serviceData.length); // unpacked size
        body.vint(0); // attributes
        body.vint(0); // compression info: stored
        body.addByte(0); // host OS
        body.vint(nameBytes.length);
        body.add(nameBytes);
      },
    );
  }
  if (withEndBlock) {
    _addRar5Block(
      builder,
      type: 5,
      headerFlags: 0,
      headerCrcOverride: headerCrcOverride,
      write: (final body) {
        body.vint(0); // end-of-archive flags
      },
    );
  }

  final archive = builder.takeBytes();
  return trailingGarbage ? Uint8List.fromList([...archive, 0xDE, 0xAD, 0xBE, 0xEF]) : archive;
}

void _addRar5Block(
  final BytesBuilder archive, {
  required final int type,
  required final int headerFlags,
  final Uint8List? data,
  final List<int>? extraArea,
  final void Function(_Rar5Header body)? write,
  final int? headerCrcOverride,
}) {
  final body = _Rar5Header();
  body.vint(type);
  body.vint(headerFlags);
  if (headerFlags & 0x0001 != 0) {
    body.vint(extraArea?.length ?? 0);
  }
  if (headerFlags & 0x0002 != 0) {
    body.vint(data?.length ?? 0);
  }
  write?.call(body);
  if (extraArea != null) {
    body.add(extraArea);
  }
  final bodyBytes = body.takeBytes();
  final sizeBytes = _vintBytes(bodyBytes.length);

  final crc = headerCrcOverride ?? getCrc32(Uint8List.fromList([...sizeBytes, ...bodyBytes]));
  final block = BytesBuilder(copy: false)
    ..add((ByteData(4)..setUint32(0, crc, Endian.little)).buffer.asUint8List())
    ..add(sizeBytes)
    ..add(bodyBytes);
  if (data != null) {
    block.add(data);
  }
  archive.add(block.takeBytes());
}

List<int> _vintBytes(int value) {
  final bytes = <int>[];
  while (true) {
    var byte = value & 0x7F;
    value >>= 7;
    if (value > 0) {
      byte |= 0x80;
    }
    bytes.add(byte);
    if (value == 0) {
      return bytes;
    }
  }
}

/// The type-specific part of a RAR 5 header, between the header flags
/// and the end of the header.
final class _Rar5Header {
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  void vint(final int value) => _buffer.add(_vintBytes(value));

  void uint32(final int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    _buffer.add(data.buffer.asUint8List());
  }

  void addByte(final int byte) => _buffer.addByte(byte);

  void add(final List<int> bytes) => _buffer.add(bytes);

  Uint8List takeBytes() => _buffer.takeBytes();
}

/// Builds a RAR 5 archive whose first compressed entry declares a
/// dictionary above the subset limit and whose second entry carries the
/// solid bit — the second header is a typed rejection naming the broken
/// dependency even though its own header is fine.
Uint8List buildRar5SolidChainWithBrokenPredecessor() {
  final builder = BytesBuilder(copy: false);
  builder.add([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]);
  _addRar5Block(
    builder,
    type: 1,
    headerFlags: 0,
    write: (final body) {
      body.vint(0x0004); // archive solid flag
    },
  );
  void file(final String name, {required final int dictExp, required final bool solid}) {
    final nameBytes = convert.utf8.encode(name);
    _addRar5Block(
      builder,
      type: 2,
      headerFlags: 0x0002,
      data: Uint8List.fromList(tinyJpegPage),
      write: (final body) {
        body.vint(0x0004); // file flags: has CRC
        body.vint(tinyJpegPage.length); // unpacked size
        body.vint(0x20); // attributes
        body.uint32(0); // data CRC
        body.vint((3 << 7) | (dictExp << 10) | (solid ? 0x40 : 0)); // comp info
        body.addByte(0); // host OS
        body.vint(nameBytes.length);
        body.add(nameBytes);
      },
    );
  }

  file('001.jpg', dictExp: 10, solid: true); // above the subset limit
  file('002.jpg', dictExp: 0, solid: true); // continues the broken chain
  _addRar5Block(
    builder,
    type: 5,
    headerFlags: 0,
    write: (final body) {
      body.vint(0);
    },
  );

  return builder.takeBytes();
}

/// A stored page of [length] bytes with a JPEG magic at the front —
/// big enough to push the session LRU over a small budget.
Uint8List fatJpegPage(final int length) {
  final page = Uint8List(length);
  page[0] = 0xFF;
  page[1] = 0xD8;
  page[2] = 0xFF;
  page[3] = 0xE0;
  page[length - 2] = 0xFF;
  page[length - 1] = 0xD9;

  return page;
}

/// Appends four bytes to [data] so the CRC-32 of the result is exactly
/// zero — proving a declared zero checksum is a real checksum, not a
/// "no checksum" sentinel.
///
/// CRC-32 is affine over GF(2): each appended bit flips the result by a
/// fixed column vector, so the four solution bytes come from Gaussian
/// elimination over the 32 column vectors.
Uint8List withZeroCrc32(final List<int> data) {
  final base = Uint8List.fromList([...data, 0, 0, 0, 0]);
  final columns = List<int>.generate(32, (final i) {
    final probe = Uint8List.fromList(base);
    probe[data.length + i ~/ 8] = 1 << (i % 8);

    return getCrc32(probe) ^ getCrc32(base);
  });

  // Reduce the columns to row echelon form, carrying the combination of
  // original columns each reduced row represents.
  final rows = <(int, int)>[]; // (vector, combination)
  for (var i = 0; i < 32; i++) {
    var vector = columns[i];
    var combination = 1 << i;
    for (final row in rows) {
      if (vector & _highestBit(row.$1) != 0) {
        vector ^= row.$1;
        combination ^= row.$2;
      }
    }
    if (vector != 0) rows.add((vector, combination));
  }

  // Express the base value as a combination of the rows; the resulting
  // bit combination cancels it to zero.
  var remainder = getCrc32(base);
  var combination = 0;
  while (remainder != 0) {
    final pivot = _highestBit(remainder);
    final row = rows.firstWhere(
      (final row) => _highestBit(row.$1) == pivot,
      orElse: () => throw StateError('CRC-32 zero patch has no solution.'),
    );
    remainder ^= row.$1;
    combination ^= row.$2;
  }

  final result = Uint8List.fromList(base);
  for (var i = 0; i < 32; i++) {
    if (combination & (1 << i) != 0) {
      result[data.length + i ~/ 8] |= 1 << (i % 8);
    }
  }
  assert(getCrc32(result) == 0);

  return result;
}

int _highestBit(final int value) {
  for (var bit = 31; bit >= 0; bit--) {
    if (value & (1 << bit) != 0) return 1 << bit;
  }

  return 0;
}
