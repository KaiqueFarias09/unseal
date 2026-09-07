import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/features/comic/utils/rar_reader.dart';
import 'package:test/test.dart';

// Byte-packing builders read best as sequential field writes.
// ignore_for_file: cascade_invocations

void main() {
  group('RAR 4 optional header fields', () {
    test('skips the 64-bit size fields (flag 0x0100)', () {
      final archive = buildRar4(['high.jpg'], flags: 0x8000 | 0x0100, withHighSizes: true);
      final entries = readRarEntries(archive);
      expect(entries.single.name, 'high.jpg');
      expect(entries.single.data, tinyJpegPage);
    });

    test('skips the encryption salt (flag 0x0400)', () {
      final archive = buildRar4(['salt.jpg'], flags: 0x8000 | 0x0400, withSalt: true);
      final entries = readRarEntries(archive);
      expect(entries.single.name, 'salt.jpg');
      expect(entries.single.isStored, isTrue);
    });

    test('decodes the real RAR 4 method-29 CBR pages', () {
      final bytes = File(
        'test/resources/books/comic/american-beauty-trading-cards-1909.cbr',
      ).readAsBytesSync();
      final pages = readRarEntries(bytes).where((final entry) => !entry.isDirectory).toList();

      expect(pages, hasLength(24));
      expect(pages.every((final page) => sniffImageType(page.data) == ImageType.jpeg), isTrue);
    });

    test('stops when a file name runs past the buffer', () {
      final archive = buildRar4(['gone.jpg'], nameSizeOvershoot: 2);
      expect(readRarEntries(archive), isEmpty);
    });
  });

  group('RAR 5', () {
    test('reads stored entries behind a main header', () {
      final archive = buildRar5(['002.jpg', '001.jpg']);
      final entries = readRarEntries(archive);
      expect(entries.map((final entry) => entry.name).toList(), ['002.jpg', '001.jpg']);
      expect(entries.every((final entry) => entry.isStored), isTrue);
      expect(entries.first.data, tinyJpegPage);
    });

    test('reads stored entries with an extra metadata area', () {
      final entries = readRarEntries(buildRar5(['001.jpg', '002.jpg'], withExtraArea: true));

      expect(entries, hasLength(2));
      expect(entries.map((final entry) => entry.name).toList(), ['001.jpg', '002.jpg']);
      expect(entries.every((final entry) => entry.isStored), isTrue);
      expect(entries.first.data, tinyJpegPage);
      expect(entries.last.data, tinyJpegPage);
    });

    test('reports compressed entries as not stored', () {
      final entries = readRarEntries(buildRar5(['001.jpg'], method: 3));
      expect(entries.single.isStored, isFalse);
      expect(entries.single.data, isEmpty);
    });

    test('parses headers carrying mtime and data crc', () {
      final entries = readRarEntries(buildRar5(['001.jpg'], fileFlags: 0x0006));
      expect(entries.single.name, '001.jpg');
      expect(entries.single.data, tinyJpegPage);
    });

    test('marks directory entries', () {
      final entries = readRarEntries(buildRar5(['chapter1/'], fileFlags: 0x0001));
      expect(entries.single.isDirectory, isTrue);
      expect(entries.single.data, isEmpty);
    });

    test('stops at the end-of-archive block', () {
      final entries = readRarEntries(buildRar5(['001.jpg'], trailingGarbage: true));
      expect(entries, hasLength(1));
    });

    test('rejects non-RAR and truncated buffers', () {
      expect(() => readRarEntries(Uint8List(4)), throwsA(isA<ComicException>()));
      expect(
        () => readRarEntries(Uint8List.fromList('NOTARAR!'.codeUnits)),
        throwsA(isA<ComicException>()),
      );
    });
  });

  group('CBR through the comic parser', () {
    test('RAR 5 comics parse into pages', () {
      final book = parseComicBook(buildRar5(['002.jpg', '001.jpg']));
      expect(book.format, BookFormat.cbr);
      expect(book.pageCount, 2);
      expect(book.pages.first.name, '001.jpg');
      expect(detectFormat(buildRar5(['001.jpg'])), DetectedFormat.comic);
    });

    test('RAR 5 comics with an extra metadata area parse into pages', () {
      final book = parseComicBook(buildRar5(['001.jpg'], withExtraArea: true));

      expect(book.format, BookFormat.cbr);
      expect(book.pageCount, 1);
      expect(book.pages.single.name, '001.jpg');
    });

    test('RAR 5 comics with compressed pages throw', () {
      expect(
        () => parseComicBook(buildRar5(['001.jpg'], method: 3)),
        throwsA(isA<ComicException>()),
      );
    });
  });
}

final Uint8List tinyJpegPage = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 1, 2, 3, 0xFF, 0xD9]);

/// Builds a RAR 4 archive with stored entries.
Uint8List buildRar4(
  final List<String> names, {
  final int flags = 0x8000,
  final bool withHighSizes = false,
  final bool withSalt = false,
  final int nameSizeOvershoot = 0,
}) {
  final builder = BytesBuilder(copy: false);
  builder.add([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);

  for (final name in names) {
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
    header.setUint32(f, tinyJpegPage.length, Endian.little);
    f += 4; // packed
    header.setUint32(f, tinyJpegPage.length, Endian.little);
    f += 4; // unpacked
    header.setUint8(f, 0);
    f += 1; // host OS
    header.setUint32(f, 0, Endian.little);
    f += 4; // file crc
    header.setUint32(f, 0, Endian.little);
    f += 4; // file time
    header.setUint8(f, 29);
    f += 1; // unpack version
    header.setUint8(f, 0x30);
    f += 1; // method: stored
    header.setUint16(f, nameBytes.length + nameSizeOvershoot, Endian.little);
    f += 2;
    header.setUint32(f, 0x20, Endian.little);
    f += 4; // attributes
    f += extras; // high sizes / salt live between attributes and name
    header.buffer.asUint8List().setRange(f, f + nameBytes.length, nameBytes);
    builder.add(header.buffer.asUint8List());
    if (nameSizeOvershoot == 0) {
      builder.add(tinyJpegPage);
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
}) {
  final builder = BytesBuilder(copy: false);
  builder.add([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]);

  _addRar5Block(builder, type: 1, headerFlags: 0);
  for (var index = 0; index < names.length; index++) {
    final name = names[index];
    final nameBytes = name.codeUnits;
    final includeExtraArea = withExtraArea && index == 0;
    final extraArea = includeExtraArea ? [6, 3, 1, 0, 0, 0, 0] : null;
    _addRar5Block(
      builder,
      type: 2,
      headerFlags: 0x0002 | (includeExtraArea ? 0x0001 : 0),
      data: tinyJpegPage,
      extraArea: extraArea,
      write: (final body) {
        body.vint(fileFlags);
        body.vint(tinyJpegPage.length); // unpacked size
        body.vint(0x20); // attributes
        if (fileFlags & 0x0002 != 0) {
          body.uint32(0x5F000000); // mtime
        }
        if (fileFlags & 0x0004 != 0) {
          body.uint32(0); // data crc (unverified)
        }
        body.vint(method << 7); // compression info: version 0, method
        body.addByte(0); // host OS
        body.vint(nameBytes.length);
        body.add(nameBytes);
      },
    );
  }
  _addRar5Block(builder, type: 5, headerFlags: 0);

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

  final block = BytesBuilder(copy: false)
    ..add((ByteData(4)..setUint32(0, 0)).buffer.asUint8List()) // header crc
    ..add(_vintBytes(bodyBytes.length))
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
    final data = ByteData(4)..setUint32(0, value);
    _buffer.add(data.buffer.asUint8List());
  }

  void addByte(final int byte) => _buffer.addByte(byte);

  void add(final List<int> bytes) => _buffer.add(bytes);

  Uint8List takeBytes() => _buffer.takeBytes();
}
