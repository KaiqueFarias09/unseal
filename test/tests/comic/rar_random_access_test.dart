import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/features/comic/archive/rar_random_access.dart';
import 'package:unseal/src/foundation/archive/zip_byte_source.dart';
import 'package:unseal/unseal.dart';

import '../../support/rar_fixtures.dart';

Uint8List _bytes(final String name) =>
    Uint8List.fromList(File('test/resources/$name').readAsBytesSync());

void main() {
  group('RarRandomAccess parity with the eager decode', () {
    final fixtures = [
      'books/comic/synthetic-stored-pages.cbr',
      'books/comic/american-beauty-trading-cards-1909.cbr',
    ];

    for (final fixture in fixtures) {
      test('indexed entries inflate to the eager page bytes: $fixture', () {
        final bytes = _bytes(fixture);
        final rar = RarRandomAccess.open(MemoryZipByteSource(bytes));
        addTearDown(rar.close);
        final full = Unseal.parse(bytes) as ComicBook;

        for (final page in full.pages) {
          final record = rar.find(page.path);
          expect(record, isNotNull, reason: 'page ${page.path} must be indexed');
          expect(rar.inflate(record!), page.content, reason: 'payload of ${page.path}');
          expect(
            rar.head(record, 8),
            page.content.sublist(0, math.min(8, page.content.length)),
            reason: 'head prefix of ${page.path}',
          );
        }
        // Every indexed file entry the eager reader kept is a page; the
        // two inventories cannot drift.
        final pagePaths = {for (final page in full.pages) page.path};
        for (final record in rar.entries) {
          if (!record.isFile) continue;
          expect(pagePaths, contains(record.name), reason: 'indexed ${record.name}');
        }
      });
    }

    test('case-insensitive find matches, missing paths do not', () {
      final rar = RarRandomAccess.open(
        MemoryZipByteSource(buildRar4(['Pages/001.jpg', 'Pages/002.jpg'])),
      );
      addTearDown(rar.close);

      expect(rar.find('Pages/001.jpg'), isNotNull);
      expect(rar.find('pages/001.JPG'), isNotNull);
      expect(rar.find('Pages/missing.jpg'), isNull);
      expect(rar.find(''), isNull);
    });
  });

  group('RarRandomAccess payload modes', () {
    test('solid stored entries keep their verbatim payload', () {
      // The eager reader ignores the solid bit for stored entries; the
      // random-access reader must too.
      final rar = RarRandomAccess.open(
        MemoryZipByteSource(buildRar4(['a.jpg'], flags: 0x8000 | 0x0010)),
      );
      addTearDown(rar.close);

      expect(rar.inflate(rar.find('a.jpg')!), tinyJpegPage);
    });

    test('truncated stored entries drop out of sniffing and fail inflate typed', () {
      final full = buildRar4(['a.jpg', 'b.jpg']);
      // Cut off the end block and part of b.jpg's data: a.jpg stays
      // intact and b.jpg's declared payload no longer fits.
      final bytes = Uint8List.sublistView(full, 0, full.length - 11);
      final rar = RarRandomAccess.open(MemoryZipByteSource(bytes));
      addTearDown(rar.close);

      expect(rar.find('a.jpg'), isNotNull);
      final truncated = rar.find('b.jpg')!;
      expect(rar.head(truncated, 64), isEmpty, reason: 'the eager reader drops it');

      try {
        rar.inflate(truncated);
        fail('inflate must reject the truncated payload');
      } on ComicException catch (error) {
        expect(error.message, contains('b.jpg'));
      }
    });

    test('unsupported compressed entries stay indexed and fail typed', () {
      final rar = RarRandomAccess.open(MemoryZipByteSource(buildRar4(['a.jpg'], method: 0x33)));
      addTearDown(rar.close);
      final record = rar.find('a.jpg')!;
      expect(record.isFile, isTrue, reason: 'unsupported entries stay indexed');

      final String headFailure;
      try {
        rar.head(record, 8);
        fail('head must reject unsupported compression');
      } on ComicException catch (error) {
        headFailure = error.message;
      }
      expect(headFailure, contains('a.jpg'));
      expect(() => rar.inflate(record), throwsA(isA<ComicException>()));
    });

    test('unknown unpack versions fail typed like the eager reader', () {
      final rar = RarRandomAccess.open(
        MemoryZipByteSource(buildRar4(['a.jpg'], method: 0x33, unpackVersion: 36)),
      );
      addTearDown(rar.close);
      final record = rar.find('a.jpg')!;

      expect(() => rar.head(record, 8), throwsA(isA<ComicException>()));
    });

    test('RAR 5 compressed entries stay indexed and fail typed', () {
      final rar = RarRandomAccess.open(MemoryZipByteSource(buildRar5(['001.jpg'], method: 3)));
      addTearDown(rar.close);
      final record = rar.find('001.jpg')!;
      expect(record.isFile, isTrue);

      expect(() => rar.head(record, 8), throwsA(isA<ComicException>()));
      expect(() => rar.inflate(record), throwsA(isA<ComicException>()));
    });
  });

  group('RarRandomAccess CRC verification (session-only delta)', () {
    test('declared non-zero CRCs verify on stored RAR 4 payloads', () {
      final crc = getCrc32(tinyJpegPage);
      final rar = RarRandomAccess.open(
        MemoryZipByteSource(buildRar4Files({'a.jpg': tinyJpegPage}, fileCrc: crc)),
      );
      addTearDown(rar.close);

      expect(rar.inflate(rar.find('a.jpg')!), tinyJpegPage);
    });

    test('corrupt stored payloads with declared CRCs reject typed', () {
      final rar = RarRandomAccess.open(
        MemoryZipByteSource(buildRar4Files({'a.jpg': tinyJpegPage}, fileCrc: 0xDEADBEEF)),
      );
      addTearDown(rar.close);

      expect(() => rar.inflate(rar.find('a.jpg')!), throwsA(isA<ComicException>()));
    });

    test('declared non-zero CRCs verify on stored RAR 5 payloads', () {
      final crc = getCrc32(tinyJpegPage);
      final rar = RarRandomAccess.open(
        MemoryZipByteSource(buildRar5Files({'001.jpg': tinyJpegPage}, dataCrc: crc)),
      );
      addTearDown(rar.close);

      expect(rar.inflate(rar.find('001.jpg')!), tinyJpegPage);
    });

    test('zero CRCs never reject', () {
      final rar = RarRandomAccess.open(
        MemoryZipByteSource(buildRar5Files({'001.jpg': tinyJpegPage})),
      );
      addTearDown(rar.close);

      expect(rar.inflate(rar.find('001.jpg')!), tinyJpegPage);
    });
  });

  group('RarRandomAccess container guards', () {
    test('signatures are typed rejections', () {
      expect(
        () => RarRandomAccess.open(MemoryZipByteSource(Uint8List.fromList('NOTARAR!'.codeUnits))),
        throwsA(isA<ComicException>()),
      );
      expect(
        () => RarRandomAccess.open(MemoryZipByteSource(Uint8List(4))),
        throwsA(isA<ComicException>()),
      );
    });

    test('declared totals above the 512 MiB entry cap reject at open', () {
      final bomb = buildRar4Files({
        'bomb.jpg': tinyJpegPage,
      }, declaredUnpackedSize: (512 << 20) + 1);

      expect(
        () => RarRandomAccess.open(MemoryZipByteSource(bomb)),
        throwsA(isA<InvalidBookException>()),
      );
    });

    test('declared expansion ratios above the cap reject at open', () {
      // Two entries declaring 17 MiB each over a few hundred bytes of
      // container: past the 32 MiB ratio floor and far above 200x.
      final bomb = buildRar4Files({
        'a.jpg': tinyJpegPage,
        'b.jpg': tinyJpegPage,
      }, declaredUnpackedSize: 17 << 20);

      expect(
        () => RarRandomAccess.open(MemoryZipByteSource(bomb)),
        throwsA(isA<InvalidBookException>()),
      );
    });
  });
}
