import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/features/comic/archive/rar_random_access.dart';
import 'package:unseal/src/foundation/archive/zip_byte_source.dart';
import 'package:unseal/unseal.dart';

import '../../../tool/rar5_stream_encoder.dart';
import '../../support/rar_fixtures.dart';

Uint8List _bytes(final String name) =>
    Uint8List.fromList(File('test/resources/$name').readAsBytesSync());

/// A hostile solid chain: many mid-size entries whose decode work adds
/// up, built in-process by the same encoder that pins the fixtures.
Uint8List _hostileSolidChain({final int entryCount = 12, final int entryBytes = 512 << 10}) {
  final entries = <FixtureEntry>[
    for (var i = 0; i < entryCount; i++)
      FixtureEntry('page-${i.toString().padLeft(3, '0')}.jpg', fatJpegPage(entryBytes)),
  ];

  return buildRar5Archive(entries: entries, method: 3, dictExp: 0, archiveSolid: true);
}

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

  group('RarRandomAccess RAR 5 header contract', () {
    test('a declared zero CRC is a real checksum that verifies', () {
      // Content whose CRC-32 is genuinely zero: the session must verify
      // it (flag present, value zero) instead of treating zero as
      // "absent".
      final page = withZeroCrc32(tinyJpegPage);
      expect(getCrc32(page), isZero);
      final rar = RarRandomAccess.open(
        MemoryZipByteSource(buildRar5Files({'a.jpg': page}, dataCrc: 0)),
      );
      addTearDown(rar.close);
      final record = rar.find('a.jpg')!;
      expect(record.verifiesCrc, isTrue, reason: 'flag 0x0004 present');

      expect(rar.inflate(record), page);
    });

    test('a declared zero CRC still rejects mismatching content', () {
      final rar = RarRandomAccess.open(
        MemoryZipByteSource(buildRar5Files({'a.jpg': tinyJpegPage}, dataCrc: 0)),
      );
      addTearDown(rar.close);

      expect(() => rar.inflate(rar.find('a.jpg')!), throwsA(isA<ComicException>()));
    });

    test('absent CRC flag never rejects, present CRC verifies', () {
      final absent = RarRandomAccess.open(MemoryZipByteSource(buildRar5(['a.jpg'])));
      addTearDown(absent.close);
      expect(absent.find('a.jpg')!.verifiesCrc, isFalse);
      expect(absent.inflate(absent.find('a.jpg')!), tinyJpegPage);

      final present = RarRandomAccess.open(
        MemoryZipByteSource(
          buildRar5Files({'a.jpg': tinyJpegPage}, dataCrc: getCrc32(tinyJpegPage)),
        ),
      );
      addTearDown(present.close);
      expect(present.find('a.jpg')!.verifiesCrc, isTrue);
      expect(present.inflate(present.find('a.jpg')!), tinyJpegPage);

      final wrong = RarRandomAccess.open(
        MemoryZipByteSource(buildRar5Files({'a.jpg': tinyJpegPage}, dataCrc: 0xDEADBEEF)),
      );
      addTearDown(wrong.close);
      expect(() => wrong.inflate(wrong.find('a.jpg')!), throwsA(isA<ComicException>()));
    });

    test('the shared walk fails open on a broken header CRC', () {
      final archive = buildRar5(['001.jpg'], headerCrcOverride: 0xDEADBEEF);

      expect(
        () => RarRandomAccess.open(MemoryZipByteSource(archive)),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('fails its CRC-32 check'),
          ),
        ),
      );
    });

    test('unsupported RAR 5 variants stay indexed and name their reason', () {
      final cases = <(String, String, Uint8List)>{
        ('split across volumes', '001.jpg', buildRar5(['001.jpg'], splitBlockFlags: 0x0010)),
        ('algorithm version', '001.jpg', buildRar5(['001.jpg'], method: 3, version: 1)),
        ('reserved compression method', '001.jpg', buildRar5(['001.jpg'], method: 7)),
        ('subset limit', '001.jpg', buildRar5(['001.jpg'], method: 3, dictExp: 10)),
        ('unpacked size', '001.jpg', buildRar5(['001.jpg'], fileFlags: 0x0008)),
        (
          'continues from an entry that cannot be decoded',
          '002.jpg',
          buildRar5SolidChainWithBrokenPredecessor(),
        ),
      };

      for (final (expectedReason, entryName, archive) in cases) {
        final rar = RarRandomAccess.open(MemoryZipByteSource(archive));
        addTearDown(rar.close);
        final record = rar.find(entryName)!;
        expect(record.isFile, isTrue, reason: '$expectedReason stays indexed');

        try {
          rar.head(record, 8);
          fail('head must reject: $expectedReason');
        } on ComicException catch (error) {
          expect(error.message, contains(expectedReason), reason: error.message);
        }
        expect(() => rar.inflate(record), throwsA(isA<ComicException>()));
      }
    });

    test('multi-volume archives fail at open', () {
      expect(
        () =>
            RarRandomAccess.open(MemoryZipByteSource(buildRar5(['001.jpg'], archiveFlags: 0x0001))),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('multi-volume'),
          ),
        ),
      );
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

  group('RarRandomAccess cumulative solid limits (RS05)', () {
    test('alternating first/last access exhausts the replay budget typed', () {
      final chain = _hostileSolidChain();
      final rar = RarRandomAccess.open(MemoryZipByteSource(chain));
      addTearDown(rar.close);
      final files = [
        for (final record in rar.entries)
          if (record.isFile) record,
      ];
      expect(files.length, 12);

      ComicException? lastError;
      var rounds = 0;
      var previousReplay = rar.solidReplayBytesUsed;
      try {
        while (rounds < 1000) {
          rar.inflate(files.last);
          rar.inflate(files.first);
          rounds++;
          expect(
            rar.solidReplayBytesUsed,
            greaterThan(previousReplay),
            reason: 'round $rounds re-decodes must charge the cumulative budget',
          );
          previousReplay = rar.solidReplayBytesUsed;
        }
        fail('the hostile alternation must exhaust the budget');
      } on ComicException catch (error) {
        lastError = error;
        expect(error.message, contains('replay budget'));
      }
      expect(lastError, isNotNull, reason: 'the budget rejected the pattern');
      expect(rounds, lessThan(1000), reason: 'the budget stopped the loop');
      expect(
        rar.solidReplayBytesUsed,
        lessThanOrEqualTo(maxRar5SolidReplayBytes),
        reason: 'the charge never overshoots the cap',
      );
    });

    test('checkpoints stay under their count and byte ceilings', () {
      final chain = _hostileSolidChain();
      final rar = RarRandomAccess.open(MemoryZipByteSource(chain));
      addTearDown(rar.close);
      final files = [
        for (final record in rar.entries)
          if (record.isFile) record,
      ];

      // Full reverse walk, then a zig-zag pass: checkpoints churn under
      // eviction the whole time.
      for (final record in files.reversed) {
        rar.inflate(record);
      }
      for (final index in [0, 5, 2, 9, 1, 11, 3, 7]) {
        rar.inflate(files[index]);
      }

      expect(rar.solidCheckpointBytes, lessThanOrEqualTo(maxRar5SolidCheckpointBytes));
      for (final record in files) {
        expect(rar.inflate(record), isNotNull, reason: '${record.name} still decodes');
      }
      expect(rar.solidCheckpointBytes, lessThanOrEqualTo(maxRar5SolidCheckpointBytes));
    });

    test('exhausting the replay budget leaves forward first-pass access working', () {
      final chain = _hostileSolidChain(entryCount: 10, entryBytes: 256 << 10);
      final rar = RarRandomAccess.open(MemoryZipByteSource(chain));
      addTearDown(rar.close);
      final files = [
        for (final record in rar.entries)
          if (record.isFile) record,
      ];

      // Burn the budget on alternation, then walk a FRESH reopen
      // forward: first-pass sequential decode is never replay.
      try {
        while (true) {
          rar.inflate(files.last);
          rar.inflate(files.first);
        }
      } on ComicException {
        // budget exhausted
      }
      final fresh = RarRandomAccess.open(MemoryZipByteSource(chain));
      addTearDown(fresh.close);
      final freshFiles = [
        for (final record in fresh.entries)
          if (record.isFile) record,
      ];
      expect(fresh.solidReplayBytesUsed, 0, reason: 'reopen resets the budget');
      for (final record in freshFiles) {
        expect(fresh.inflate(record), isNotNull, reason: '${record.name} first pass');
      }
      expect(fresh.solidReplayBytesUsed, 0, reason: 'a sequential pass charges nothing');
    });
  });
}
