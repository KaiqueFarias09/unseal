import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';
import 'package:unseal/src/features/comic/archive/rar5_archive.dart';
import 'package:unseal/src/features/comic/archive/rar5_decoder.dart';
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

void main() {
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
