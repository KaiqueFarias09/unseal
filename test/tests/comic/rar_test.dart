import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../../support/rar_fixtures.dart';

void main() {
  group('RAR 4 optional header fields', () {
    test('skips the 64-bit size fields (flag 0x0100)', () {
      final archive = buildRar4(['high.jpg'], flags: 0x8000 | 0x0100, withHighSizes: true);
      final book = parseComicBook(archive);

      expect(book.pages.single.name, 'high.jpg');
      expect(book.pages.single.content, tinyJpegPage);
    });

    test('skips the encryption salt (flag 0x0400)', () {
      final archive = buildRar4(['salt.jpg'], flags: 0x8000 | 0x0400, withSalt: true);
      final book = parseComicBook(archive);

      expect(book.pages.single.name, 'salt.jpg');
      expect(book.pages.single.content, tinyJpegPage);
    });

    test('decodes the real RAR 4 method-29 CBR pages', () {
      final bytes = File(
        'test/resources/books/comic/american-beauty-trading-cards-1909.cbr',
      ).readAsBytesSync();
      final pages = parseComicBook(bytes).pages;

      expect(pages, hasLength(24));
      expect(pages.every((final page) => sniffImageType(page.content) == ImageType.jpeg), isTrue);
    });

    test('stops when a file name runs past the buffer', () {
      final archive = buildRar4(['gone.jpg'], nameSizeOvershoot: 2);
      expect(() => parseComicBook(archive), throwsA(isA<ComicException>()));
    });
  });

  group('RAR 5', () {
    test('reads stored entries behind a main header', () {
      final archive = buildRar5(['002.jpg', '001.jpg']);
      final book = parseComicBook(archive);

      expect(book.pages.map((final page) => page.name).toList(), ['001.jpg', '002.jpg']);
      expect(book.pages.first.content, tinyJpegPage);
    });

    test('reads stored entries with an extra metadata area', () {
      final book = parseComicBook(buildRar5(['001.jpg', '002.jpg'], withExtraArea: true));

      expect(book.pages, hasLength(2));
      expect(book.pages.map((final page) => page.name).toList(), ['001.jpg', '002.jpg']);
      expect(book.pages.first.content, tinyJpegPage);
      expect(book.pages.last.content, tinyJpegPage);
    });

    test('reports compressed entries as not stored', () {
      expect(
        () => parseComicBook(buildRar5(['001.jpg'], method: 3)),
        throwsA(isA<ComicException>()),
      );
    });

    test('parses headers carrying mtime and data crc', () {
      final book = parseComicBook(
        buildRar5Files(
          {'001.jpg': tinyJpegPage},
          fileFlags: 0x0002,
          dataCrc: getCrc32(tinyJpegPage),
        ),
      );

      expect(book.pages.single.name, '001.jpg');
      expect(book.pages.single.content, tinyJpegPage);
    });

    test('rejects a wrong declared data crc through the eager path', () {
      expect(
        () => parseComicBook(buildRar5Files({'001.jpg': tinyJpegPage}, dataCrc: 0xDEADBEEF)),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('invalid checksum'),
          ),
        ),
      );
    });

    test('marks directory entries', () {
      expect(
        () => parseComicBook(buildRar5(['chapter1/'], fileFlags: 0x0001)),
        throwsA(isA<ComicException>()),
      );
    });

    test('stops at the end-of-archive block', () {
      final book = parseComicBook(buildRar5(['001.jpg'], trailingGarbage: true));

      expect(book.pages, hasLength(1));
    });

    test('rejects non-RAR and truncated buffers', () {
      expect(() => parseComicBook(Uint8List(4)), throwsA(isA<ComicException>()));
      expect(
        () => parseComicBook(Uint8List.fromList('NOTARAR!'.codeUnits)),
        throwsA(isA<ComicException>()),
      );
    });
  });

  group('RAR 5 header contract', () {
    test('decodes entry names as UTF-8', () {
      final book = parseComicBook(buildRar5(['página-日本-otronível/ümlauf.jpg']));

      expect(book.pages.single.name, 'ümlauf.jpg');
      expect(book.pages.single.path, 'página-日本-otronível/ümlauf.jpg');
    });

    test('rejects a header whose CRC-32 does not verify', () {
      final archive = buildRar5(['001.jpg'], headerCrcOverride: 0xDEADBEEF);

      expect(
        () => parseComicBook(archive),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('fails its CRC-32 check'),
          ),
        ),
      );
    });

    test('rejects file data areas that run past the end of the file', () {
      final archive = buildRar5(['001.jpg']);
      // Cut the end block and half the packed data: the declared data
      // area no longer fits the container.
      final truncated = Uint8List.sublistView(archive, 0, archive.length - 12);

      expect(
        () => parseComicBook(truncated),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('data area past the end'),
          ),
        ),
      );
    });

    test('rejects split (multi-volume) archives and split entries', () {
      expect(
        () => parseComicBook(buildRar5(['001.jpg'], archiveFlags: 0x0001)),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('multi-volume'),
          ),
        ),
      );
      expect(
        () => parseComicBook(buildRar5(['001.jpg'], splitBlockFlags: 0x0010)),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('split across volumes'),
          ),
        ),
      );
    });

    test('a solid header over non-stream bytes fails at decode, typed', () {
      // The synthetic builder writes raw payload bytes into the data
      // area; a solid declaration does not bypass the stream grammar.
      final archive = buildRar5(['001.jpg'], method: 3, solid: true);

      expect(
        () => parseComicBook(archive),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('could not be decoded'),
          ),
        ),
      );
    });

    test('an archive-level solid flag with independent entries decodes', () {
      // Real solid-flagged archives written with unset per-entry solid
      // bits (like the libarchive fixture) are independent streams:
      // every entry resets the dictionary. The flag alone never
      // rejects.
      final archive = buildRar5Files(
        {'001.jpg': tinyJpegPage, '002.jpg': tinyJpegPage},
        method: 0,
        archiveFlags: 0x0004,
      );
      final book = parseComicBook(archive);

      expect(book.pageCount, 2);
    });

    test('rejects encrypted entries', () {
      // A minimal file-encryption extra record: (size=2, type=1, flags,
      // version) — rejected before any payload work.
      final archive = buildRar5(['001.jpg'], extraRecord: [2, 1, 0, 0]);

      expect(
        () => parseComicBook(archive),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('encrypted'),
          ),
        ),
      );
    });

    test('rejects later compression algorithm versions', () {
      final archive = buildRar5(['001.jpg'], method: 3, version: 1);

      expect(
        () => parseComicBook(archive),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('algorithm version 1'),
          ),
        ),
      );
    });

    test('rejects reserved compression methods', () {
      final archive = buildRar5(['001.jpg'], method: 6);

      expect(
        () => parseComicBook(archive),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('reserved compression method 6'),
          ),
        ),
      );
    });

    test('rejects dictionary declarations above the subset limit', () {
      final archive = buildRar5(['001.jpg'], method: 3, dictExp: 10);

      expect(
        () => parseComicBook(archive),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('above the 64 MiB subset limit'),
          ),
        ),
      );
    });

    test('rejects entries with unknown unpacked size', () {
      final archive = buildRar5(['001.jpg'], fileFlags: 0x0008);

      expect(
        () => parseComicBook(archive),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('unpacked size'),
          ),
        ),
      );
    });

    test('skips service headers and their data areas', () {
      final archive = buildRar5(['001.jpg'], serviceData: [1, 2, 3, 4]);
      final book = parseComicBook(archive);

      expect(book.pages.single.name, '001.jpg');
      expect(book.pages.single.content, tinyJpegPage);
    });

    test('rejects an unknown block type', () {
      final archive = buildRar5(['001.jpg'], withEndBlock: false);
      // Append a block with an unrecognized type after the file entry.
      final bodyBytes = Uint8List.fromList([0x09, 0x00, 0xAA]); // type 9
      final corrupt = Uint8List.fromList([
        ...archive,
        ...((ByteData(4)..setUint32(
              0,
              getCrc32(Uint8List.fromList([bodyBytes.length, ...bodyBytes])),
              Endian.little,
            ))
            .buffer
            .asUint8List()),
        bodyBytes.length,
        ...bodyBytes,
      ]);

      expect(
        () => parseComicBook(corrupt),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('unknown block type 9'),
          ),
        ),
      );
    });

    test('indexes readable entries when the end block is missing', () {
      // rardecode tolerates the missing end block the same way: files
      // before the truncation point stay readable.
      final book = parseComicBook(buildRar5(['001.jpg'], withEndBlock: false));

      expect(book.pages.single.name, '001.jpg');
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
