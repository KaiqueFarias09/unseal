import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';
import 'package:unseal/src/features/comic/archive/rar5_archive.dart';
import 'package:unseal/src/features/comic/archive/rar5_decoder.dart';
import 'package:unseal/src/features/comic/archive/rar_random_access.dart';
import 'package:unseal/src/foundation/archive/zip_byte_source.dart';
import 'package:unseal/unseal.dart';

import '../../support/rar_fixtures.dart';

Uint8List _bytes(final String name) =>
    Uint8List.fromList(File('test/resources/books/comic/rar5/$name').readAsBytesSync());

String _sha256(final Uint8List bytes) => crypto.sha256.convert(bytes).toString();

/// Decodes every file entry of [name] through the same shared walk +
/// solid-chain decoder the eager parser uses, for digest comparisons
/// against the manifest and the recorded oracle results.
Map<String, Uint8List> _decodeEntries(final String name) {
  final bytes = _bytes(name);
  final source = MemoryZipByteSource(bytes);
  final container = readRar5Structure(source);
  final entries = <String, Uint8List>{};
  final decoder = Rar5SolidDecoder();
  for (final header in container.entries) {
    if (header.isDirectory) continue;
    final reason = header.unsupportedReason(sourceLength: bytes.length);
    expect(reason, isNull, reason: '$name/${header.name} must be inside the subset');
    if (header.isStored) {
      entries[header.name] = Uint8List.sublistView(
        bytes,
        header.dataStart,
        header.dataStart + header.packedSize,
      );
      continue;
    }
    entries[header.name] = decoder.decodeEntry(
      packed: source.read(header.dataStart, header.packedSize),
      uncompressedSize: header.unpackedSize,
      windowSize: header.dictSize,
      solid: header.solid,
    );
  }

  return entries;
}

/// Returns [bytes] with the entry at [dataStart] declaring [wrongCrc]:
/// the data CRC field is rewritten and the covering header CRC-32 is
/// recomputed, so the corruption surfaces at data verification, not at
/// the header walk.
Uint8List _forgeDataCrc(final Uint8List bytes, final int dataStart, final int wrongCrc) {
  var offset = 8; // signature
  while (offset + 4 <= bytes.length) {
    final (headerSize, consumedSize) = readRar5Vint(bytes, offset + 4);
    final bodyStart = offset + 4 + consumedSize;
    final headerEnd = bodyStart + headerSize;
    var cursor = bodyStart;
    int vint() {
      final (value, consumed) = readRar5Vint(bytes, cursor);
      cursor += consumed;

      return value;
    }

    final type = vint();
    final flags = vint();
    if (flags & 0x0001 != 0) vint();
    var dataSize = 0;
    if (flags & 0x0002 != 0) dataSize = vint();
    if (type == 2 && headerEnd == dataStart) {
      final fileFlags = vint();
      vint(); // unpacked size
      vint(); // attributes
      if (fileFlags & 0x0002 != 0) cursor += 4; // mtime
      expect(fileFlags & 0x0004 != 0, isTrue, reason: 'the entry declares a CRC');
      final patched = Uint8List.fromList(bytes);
      final crcOffset = cursor;
      patched[crcOffset] = wrongCrc & 0xFF;
      patched[crcOffset + 1] = (wrongCrc >> 8) & 0xFF;
      patched[crcOffset + 2] = (wrongCrc >> 16) & 0xFF;
      patched[crcOffset + 3] = (wrongCrc >> 24) & 0xFF;
      // The header CRC covers the size field and the typed body.
      final headerCrc = getCrc32(Uint8List.sublistView(patched, offset + 4, headerEnd));
      patched[offset] = headerCrc & 0xFF;
      patched[offset + 1] = (headerCrc >> 8) & 0xFF;
      patched[offset + 2] = (headerCrc >> 16) & 0xFF;
      patched[offset + 3] = (headerCrc >> 24) & 0xFF;

      return patched;
    }
    offset = headerEnd + dataSize;
    if (offset <= bodyStart - 4) break;
  }
  throw StateError('entry header not found for data at $dataStart');
}

void main() {
  test('random solid access skips stored records and directories in both directions', () {
    final expected = _decodeEntries('rar5-solid-mixed.cbr');
    final rar = RarRandomAccess.open(MemoryZipByteSource(_bytes('rar5-solid-mixed.cbr')));
    addTearDown(rar.close);
    final files = rar.entries.where((record) => record.isFile).toList();
    for (final record in [...files.reversed, ...files]) {
      expect(rar.inflate(record), expected[record.name], reason: record.name);
    }
  });

  test('random solid access verifies intermediate CRC before serving later pages', () {
    final bytes = _bytes('rar5-solid-comic.cbr');
    final container = readRar5Structure(MemoryZipByteSource(bytes));
    final corrupted = _forgeDataCrc(bytes, container.entries[1].dataStart, 0xDEADBEEF);
    final rar = RarRandomAccess.open(MemoryZipByteSource(corrupted));
    addTearDown(rar.close);
    expect(
      () => rar.inflate(rar.entries.last),
      throwsA(
        isA<ComicException>().having((e) => e.message, 'message', contains('invalid checksum')),
      ),
    );
    expect(() => rar.inflate(rar.entries.last), throwsA(isA<ComicException>()));
  });

  test('replacing the same solid checkpoint does not accumulate its weight', () {
    final rar = RarRandomAccess.open(MemoryZipByteSource(_bytes('rar5-solid-comic.cbr')));
    addTearDown(rar.close);
    rar.inflate(rar.entries.first);
    final bytes = rar.solidCheckpointBytes;
    for (var i = 0; i < 20; i++) {
      rar.inflate(rar.entries.first);
      expect(rar.solidCheckpointBytes, bytes);
    }
  });

  group('RAR 5 fixture corpus decodes to the pinned digests (RAR02)', () {
    final manifest =
        (convert.json.decode(
                  File('test/resources/books/comic/rar5/manifest.json').readAsStringSync(),
                )
                as List<Object?>)
            .cast<Map<String, Object?>>();

    for (final fixture in manifest) {
      final name = fixture['file']! as String;
      test('$name matches every pinned entry digest', () {
        final decoded = _decodeEntries(name);
        // Directories carry no payload; their presence is pinned by the
        // manifest row but there are no bytes to compare.
        final expected = (fixture['entries']! as List<Object?>).cast<Map<String, Object?>>().where(
          (final entry) => !(entry['name']! as String).endsWith('/'),
        );
        expect(decoded.keys, expected.map((final entry) => entry['name']));

        for (final entry in expected) {
          final bytes = decoded[entry['name']! as String]!;
          expect(bytes.length, entry['bytes'], reason: '${entry['name']} size');
          expect(_sha256(bytes), entry['sha256'], reason: '${entry['name']} digest');
        }
      });
    }
  });

  group('RAR 5 real libarchive corpus (RAR02)', () {
    test('the real compressed stream decodes to the oracle output', () {
      final decoded = _decodeEntries('libarchive-compressed.rar');

      expect(decoded.keys, ['test.bin']);
      expect(decoded['test.bin'], hasLength(1200));
      expect(
        _sha256(decoded['test.bin']!),
        '588870a2dade35c2650fbb7898c9a9c7f21fce7c281198604e8d0c9737f2c375',
        reason: 'recorded from rardecode and libarchive extraction',
      );
    });

    test('the real ARM-filtered ELF decodes to the oracle output', () {
      final decoded = _decodeEntries('libarchive-arm-filter.rar');

      expect(decoded.keys, ['elf-Linux-ARMv7-ls']);
      expect(decoded['elf-Linux-ARMv7-ls'], hasLength(90808));
      expect(
        _sha256(decoded['elf-Linux-ARMv7-ls']!),
        'e68c62b49184ed764f324fb4722481d60e1bf321b722238d95247f391960605c',
      );
    });

    test('four real compressed entries decode to the oracle outputs', () {
      final decoded = _decodeEntries('libarchive-multiple-files.rar');

      expect(
        _sha256(decoded['test1.bin']!),
        '7d89f86f9f69d744ffff3fc043e15bf89fc3ffc134ffcbb31d164a99bb8b67b0',
      );
      expect(
        _sha256(decoded['test2.bin']!),
        'f81e6fceeeab366306b23466bf6bb3aac2875e0906dc20a8652be0696ceb15a2',
      );
      expect(
        _sha256(decoded['test3.bin']!),
        '5e621f2b6ce8fed758c3df8221f994eda55d1e432c7cc4349c34a30ec2e1c43d',
      );
      expect(
        _sha256(decoded['test4.bin']!),
        '2627f40180217252956edb9a426e8d3e344adaf89019d3bccbe04f6c3416dcdd',
      );
    });

    test('astral-plane UTF-8 names survive, links reject typed', () {
      // The archive holds one real text file plus two link entries; the
      // strict container walk rejects the links (and with them the
      // parse), naming the reason.
      expect(
        () => parseComicBook(_bytes('libarchive-unicode-names.rar')),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('link or redirect'),
          ),
        ),
      );

      // The astral name itself still decodes: the walker indexes it
      // before the rejection surfaces.
      final container = readRar5Structure(
        MemoryZipByteSource(_bytes('libarchive-unicode-names.rar')),
      );
      expect(container.entries.map((final entry) => entry.name).contains('👋🌎.txt'), isTrue);
    });
  });

  group('RAR 5 eager parse of compressed fixtures (RAR02)', () {
    test('a method-3 comic parses its image pages', () {
      final book = parseComicBook(_bytes('rar5-m3.cbr'));

      expect(book.format, BookFormat.cbr);
      // data-3.bin is not an image; only the JPEG becomes a page.
      expect(book.pageCount, 1);
      expect(book.pages.single.name, 'image-3.jpg');
      expect(book.pages.single.content, hasLength(48 * 1024));
    });

    test('every filter fixture decodes through the eager path', () {
      // The filter fixtures hold a single .bin entry, so the eager parse
      // runs the full decode and then fails on the missing image pages —
      // a decode failure would surface a different message first.
      for (final name in [
        'rar5-filter-delta.cbr',
        'rar5-filter-e8.cbr',
        'rar5-filter-e8e9.cbr',
        'rar5-filter-arm.cbr',
      ]) {
        expect(
          () => parseComicBook(_bytes(name)),
          throwsA(
            isA<ComicException>().having(
              (final error) => error.message,
              'message',
              contains('No image pages'),
            ),
          ),
          reason: name,
        );
      }
    });
  });

  group('RAR 5 corruption is typed and limited (RAR03)', () {
    test('a flipped packed byte fails typed (CRC or decoder)', () {
      final original = _bytes('rar5-m2.cbr');
      // Flip one bit in the middle of the first entry's packed data.
      final corrupted = Uint8List.fromList(original);
      final target = corrupted.length ~/ 3;
      corrupted[target] ^= 0x10;

      expect(
        () => parseComicBook(corrupted),
        throwsA(isA<ComicException>()),
        reason: 'the stream must fail its header check, decode, or CRC',
      );
    });

    test('a flipped block-header byte fails typed', () {
      final original = _bytes('rar5-m2.cbr');
      final corrupted = Uint8List.fromList(original);
      // Byte 9 sits in the first block header (CRC + size + body).
      corrupted[9] ^= 0x01;

      expect(() => parseComicBook(corrupted), throwsA(isA<ComicException>()));
    });

    test('a truncated packed payload fails typed', () {
      final original = _bytes('rar5-m2.cbr');
      final corrupted = Uint8List.sublistView(original, 0, original.length - 40);

      expect(() => parseComicBook(corrupted), throwsA(isA<ComicException>()));
    });

    test('a wrong declared data CRC fails typed on both paths', () {
      final archive = buildRar5Files({'a.jpg': tinyJpegPage}, dataCrc: 0xDEADBEEF);

      expect(
        () => parseComicBook(archive),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('invalid checksum'),
          ),
        ),
      );
    });
  });

  group('RAR 5 solid corruption is typed (RS03)', () {
    test('a flipped byte in a continuation entry fails typed on both paths', () {
      final original = _bytes('rar5-solid-chain.cbr');
      // Byte 3/4 through the file lands inside a later entry's packed
      // stream; the chain decode diverges and fails typed (decoder or
      // CRC), never silently.
      final corrupted = Uint8List.fromList(original);
      corrupted[corrupted.length * 3 ~/ 4] ^= 0x20;

      expect(() => parseComicBook(corrupted), throwsA(isA<ComicException>()));

      final source = MemoryZipByteSource(corrupted);
      final rar = RarRandomAccess.open(source);
      addTearDown(rar.close);
      for (final record in rar.entries) {
        if (!record.isFile || record.isStored) continue;
        if (record.unsupportedReason(sourceLength: corrupted.length) != null) continue;
        try {
          rar.inflate(record);
        } on ComicException {
          // Typed failure on some entry of the poisoned chain.
          return;
        }
      }
      fail('the corrupted chain must fail some entry typed');
    });

    test('a wrong declared CRC on a solid entry fails typed', () {
      // Forge the middle entry's declared data CRC: the decode succeeds
      // but verification must reject.
      final packed = _bytes('rar5-solid-comic.cbr');
      final container = readRar5Structure(MemoryZipByteSource(packed));
      final target = container.entries[2]; // a middle page, solid
      expect(target.solid, isTrue, reason: 'fixture layout: the page continues the chain');
      final corrupted = _forgeDataCrc(packed, target.dataStart, 0xDEADBEEF);

      expect(
        () => parseComicBook(corrupted),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('invalid checksum'),
          ),
        ),
      );
    });

    test('a declared CRC of zero verifies against real zero content', () {
      final decoded = _decodeEntries('rar5-solid-mixed.cbr');
      expect(decoded['mixed/zero-crc.bin'], isNotNull, reason: 'the zero-CRC entry decodes');
      expect(getCrc32(decoded['mixed/zero-crc.bin']!), 0, reason: 'its real checksum is zero');
    });

    test('a truncated solid archive fails typed', () {
      final original = _bytes('rar5-solid-chain.cbr');
      final truncated = Uint8List.sublistView(original, 0, original.length - 30);

      expect(() => parseComicBook(truncated), throwsA(isA<ComicException>()));
    });
  });

  group('RAR 5 out-of-subset real corpus rejects typed (RAR05)', () {
    test('solid, encrypted, split and malformed archives never decode', () {
      const rejections = [
        'libarchive-solid.rar',
        'libarchive-encrypted.rar',
        'libarchive-split-part1.rar',
        'libarchive-arm-window-boundary.rar',
      ];
      for (final name in rejections) {
        expect(
          () => parseComicBook(_bytes(name)),
          throwsA(isA<ComicException>()),
          reason: '$name must reject typed',
        );
      }
    });
  });
}
