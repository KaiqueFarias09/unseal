import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:test/test.dart';
import 'package:unseal/src/features/comic/archive/rar5_archive.dart';
import 'package:unseal/src/features/comic/archive/rar5_blake2sp.dart';
import 'package:unseal/src/features/comic/archive/rar_random_access.dart';
import 'package:unseal/src/foundation/archive/zip_byte_source.dart';
import 'package:unseal/unseal.dart';

import '../../../tool/rar5_stream_encoder.dart';
import '../../support/blake2sp_kat.dart';
import '../../support/rar_fixtures.dart';

const String _dir = 'test/resources/books/comic/rar5';

Uint8List _bytes(final String name) => Uint8List.fromList(File('$_dir/$name').readAsBytesSync());

String _hex(final Uint8List bytes) =>
    bytes.map((final b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _katInput(final int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) i & 0xFF]);

void _expectTyped<T extends ComicException>(
  final Uint8List bytes,
  final String messagePart,
  final String reason,
) {
  try {
    parseComicBook(bytes);
    fail('$reason: expected a typed failure containing "$messagePart"');
  } on ComicException catch (error) {
    expect(error.toString(), contains(messagePart), reason: reason);
  }
}

/// Parses the fixture manifest and returns the row of [name].
Map<String, Object?> _manifestRow(final String name) {
  final manifest = (convert.json.decode(File('$_dir/manifest.json').readAsStringSync()) as List)
      .cast<Map<String, Object?>>();
  return manifest.singleWhere((final row) => row['file'] == name);
}

void main() {
  group('RAR 5 BLAKE2sp hasher against the official KATs (RH02)', () {
    test('every unkeyed KAT and boundary length matches the pinned digests', () {
      expect(blake2spKatLengths.length, greaterThanOrEqualTo(256));
      for (var i = 0; i < blake2spKatLengths.length; i++) {
        final length = blake2spKatLengths[i];
        final digest = rar5Blake2spDigest(_katInput(length));
        expect(
          _hex(digest),
          blake2spKatDigests[i],
          reason: 'BLAKE2sp of the KAT input of $length bytes',
        );
      }
    });

    test('any streaming chunking produces the same digest', () {
      final chunkings = [1, 3, 7, 63, 64, 65, 127, 255, 511, 512, 513, 4096];
      for (final length in [0, 1, 63, 64, 65, 511, 512, 513, 1024, 65537]) {
        final input = _katInput(length);
        final expected = _hex(rar5Blake2spDigest(input));
        for (final chunk in chunkings) {
          final hasher = Rar5Blake2spHasher();
          for (var start = 0; start < input.length; start += chunk) {
            hasher.add(
              Uint8List.sublistView(
                input,
                start,
                start + chunk > input.length ? input.length : start + chunk,
              ),
            );
          }
          expect(_hex(hasher.close()), expected, reason: '$length bytes in $chunk-byte chunks');
        }
      }
    });
  });

  group('RAR 5 hash extra record parsing (RH01)', () {
    test('-htb entries carry a 32-byte digest that matches the manifest', () {
      final bytes = _bytes('rar5-hash-stored.cbr');
      final container = readRar5Structure(MemoryZipByteSource(bytes));
      final row = _manifestRow('rar5-hash-stored.cbr');
      final digests = <String, String>{
        for (final entry in (row['entries'] as List).cast<Map<String, Object?>>())
          entry['name'] as String: entry['blake2sp'] as String,
      };
      var hashEntries = 0;
      for (final header in container.entries) {
        if (header.isDirectory) continue;
        expect(header.hasBlake2Hash, isTrue, reason: '${header.name} is a -htb entry');
        expect(header.blake2spDigest!.length, 32);
        expect(_hex(header.blake2spDigest!), digests[header.name]);
        hashEntries++;
      }
      expect(hashEntries, 3);
    });

    test('an archive without the record keeps absence and its contract', () {
      final bytes = _bytes('rar5-m3.cbr');
      final container = readRar5Structure(MemoryZipByteSource(bytes));
      for (final header in container.entries) {
        if (header.isDirectory) continue;
        expect(header.hasBlake2Hash, isFalse, reason: header.name);
        expect(header.blake2spDigest, isNull);
      }
      // The public eager parse is unchanged for hash-less archives.
      final book = parseComicBook(bytes);
      expect(book.pages, isNotEmpty);
    });

    test('a digest of 32 zero bytes is present, not absent', () {
      final container = readRar5Structure(
        MemoryZipByteSource(_bytes('rar5-hash-stored-zero-digest.cbr')),
      );
      for (final header in container.entries) {
        if (header.isDirectory) continue;
        expect(header.hasBlake2Hash, isTrue, reason: header.name);
        expect(_hex(header.blake2spDigest!), '0' * 64);
      }
      // Presence means verification runs: the zero digest fails against
      // the computed hash instead of silently passing as "no hash".
      _expectTyped(
        _bytes('rar5-hash-stored-zero-digest.cbr'),
        'fails its declared BLAKE2sp data hash',
        'zero digest must fail verification',
      );
    });

    test('the comic parse contract survives -htb archives', () {
      for (final name in [
        'rar5-hash-stored.cbr',
        'rar5-hash-m1.cbr',
        'rar5-hash-m3.cbr',
        'rar5-hash-m5.cbr',
        'rar5-hash-empty.cbr',
      ]) {
        final book = parseComicBook(_bytes(name));
        expect(book.pages, isNotEmpty, reason: name);
        expect(book.format, BookFormat.cbr, reason: name);
      }
      // The solid fixture has three pages and an intact reading order.
      final solid = parseComicBook(_bytes('rar5-hash-solid.cbr'));
      expect(solid.pages.length, 3);
    });
  });

  group('RAR 5 corpus digests verify across the eager and session paths (RH03)', () {
    final fixtures = [
      'rar5-hash-stored.cbr',
      'rar5-hash-m1.cbr',
      'rar5-hash-m3.cbr',
      'rar5-hash-m5.cbr',
      'rar5-hash-empty.cbr',
    ];

    for (final name in fixtures) {
      test('$name: eager pages equal the pinned decoded bytes', () {
        final row = _manifestRow(name);
        final pinned = {
          for (final entry in (row['entries'] as List).cast<Map<String, Object?>>())
            entry['name'] as String: entry['sha256'] as String,
        };
        final bytes = _bytes(name);
        final book = parseComicBook(bytes);
        for (final page in book.pages) {
          expect(
            _hex(Uint8List.fromList(crypto.sha256.convert(page.content).bytes)),
            pinned[page.path],
            reason: '${page.path} of $name',
          );
        }
      });
    }

    test('both declared checksums verify together when both are present', () {
      // The injected archive carries a correct header CRC-32 and the
      // BLAKE2sp digest; real RAR tests it clean, and so does the parse.
      final book = parseComicBook(_bytes('rar5-hash-both-checksums.cbr'));
      expect(book.pages.length, 2);

      final container = readRar5Structure(
        MemoryZipByteSource(_bytes('rar5-hash-both-checksums.cbr')),
      );
      for (final header in container.entries) {
        if (header.isDirectory) continue;
        expect(header.hasDataCrc, isTrue, reason: header.name);
        expect(header.hasBlake2Hash, isTrue, reason: header.name);
      }
    });
  });

  group('RAR 5 hash negatives isolate their cause (RH04, RH06)', () {
    test('a corrupted digest fails the hash, not the header CRC', () {
      _expectTyped(
        _bytes('rar5-hash-stored-corrupt-digest.cbr'),
        'fails its declared BLAKE2sp data hash',
        'the header CRC was repaired, so the digest is the only cause',
      );
    });

    test('a wrong declared CRC fails the checksum, not the hash', () {
      _expectTyped(
        _bytes('rar5-hash-both-wrong-crc.cbr'),
        'has an invalid checksum',
        'payload and digest are correct, so the CRC is the only cause',
      );
    });

    test('a BLAKE2s digest is never accepted as BLAKE2sp', () {
      _expectTyped(
        _bytes('rar5-hash-m3-blake2s.cbr'),
        'fails its declared BLAKE2sp data hash',
        'BLAKE2s-256 must not substitute for BLAKE2sp',
      );
    });

    test('a corrupt digest under the injected CRC fails the hash', () {
      _expectTyped(
        _bytes('rar5-hash-both-corrupt-digest.cbr'),
        'fails its declared BLAKE2sp data hash',
        'the CRC is correct, so the digest is the only cause',
      );
    });

    test('conflicting duplicate digests fail typed', () {
      _expectTyped(
        _bytes('rar5-hash-conflicting-duplicate.cbr'),
        'declares conflicting BLAKE2sp digests',
        'two different digests on one entry are a conflict',
      );
    });

    test('unknown hash type, truncated and oversized records fail typed at parse', () {
      _expectTyped(
        _bytes('rar5-hash-unknown-type.cbr'),
        'declares an unsupported extra hash type 1',
        'hash type 1 is outside the cut',
      );
      _expectTyped(
        _bytes('rar5-hash-truncated.cbr'),
        'truncated or oversized BLAKE2sp hash record',
        'a short record cannot hold a digest',
      );
      _expectTyped(
        _bytes('rar5-hash-oversized.cbr'),
        'truncated or oversized BLAKE2sp hash record',
        'an oversized record is not silently trimmed',
      );
    });

    test('malformed hash records never crash the shared walk', () {
      // Every derived negative must reach the typed path through the
      // same container walk the session uses.
      for (final name in [
        'rar5-hash-unknown-type.cbr',
        'rar5-hash-truncated.cbr',
        'rar5-hash-oversized.cbr',
        'rar5-hash-conflicting-duplicate.cbr',
      ]) {
        expect(
          () => readRar5Structure(MemoryZipByteSource(_bytes(name))),
          throwsA(isA<ComicException>()),
          reason: name,
        );
      }
    });
  });

  group('RAR 5 sessions verify the hash chain (RH05)', () {
    test('a directly requested corrupt target poisons forward and backward reuse', () {
      final bytes = buildRar5Archive(
        entries: [
          FixtureEntry('a.jpg', tinyJpegPage),
          FixtureEntry('b.jpg', tinyJpegPage),
          FixtureEntry('c.jpg', tinyJpegPage),
        ],
        method: 3,
        dictExp: 0,
        archiveSolid: true,
        blake2spHashes: true,
        corruptDigestIndex: 1,
      );
      final rar = RarRandomAccess.open(MemoryZipByteSource(bytes));
      addTearDown(rar.close);
      expect(
        () => rar.inflate(rar.find('b.jpg')!),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.toString(),
            'message',
            contains('BLAKE2sp data hash'),
          ),
        ),
      );
      for (final name in ['c.jpg', 'a.jpg']) {
        expect(
          () => rar.inflate(rar.find(name)!),
          throwsA(
            isA<ComicException>().having(
              (final error) => error.toString(),
              'message',
              contains('reopen the archive'),
            ),
          ),
          reason: 'failed targets must not publish a reusable checkpoint for $name',
        );
      }
    });

    test('forward, backward and interleaved access verify every member', () async {
      final bytes = _bytes('rar5-hash-solid.cbr');
      final session = await BookSession.open(bytes);
      addTearDown(session.dispose);
      final pages = (session.book as ComicBook).pages.map((final p) => p.path).toList();
      expect(pages.length, 3);

      final loaded = <String, Uint8List>{};
      for (final path in pages) {
        loaded[path] = (await session.loadResource(path))!;
      }
      // Backward access replays from checkpoints and re-verifies.
      for (final path in pages.reversed) {
        expect(await session.loadResource(path), loaded[path], reason: path);
      }
      // Interleaved access across the decoded region.
      expect(await session.loadResource(pages[0]), loaded[pages[0]]);
      expect(await session.loadResource(pages[2]), loaded[pages[2]]);
    });

    test('a corrupted chain dependency fails the open before anything publishes', () async {
      final bytes = _bytes('rar5-hash-solid-corrupt-middle.cbr');
      // Sessions open only when the eager parse of the same bytes
      // would too: the open sniff walks and verifies the whole chain,
      // so the corrupt middle member fails both paths typed and no
      // payload of the archive is ever published.
      await expectLater(
        BookSession.open(bytes),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.toString(),
            'message',
            contains('"z-tiny.jpg" fails its declared BLAKE2sp data hash'),
          ),
        ),
      );
      expect(
        () => parseComicBook(bytes),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.toString(),
            'message',
            contains('fails its declared BLAKE2sp data hash'),
          ),
        ),
      );
    });

    test('reopening the archive starts a fresh, verifying session', () async {
      final bytes = _bytes('rar5-hash-solid.cbr');
      final first = await BookSession.open(bytes);
      final pages = (first.book as ComicBook).pages.map((final p) => p.path).toList();
      final contents = [for (final path in pages) await first.loadResource(path)];
      first.dispose();

      final second = await BookSession.open(bytes);
      addTearDown(second.dispose);
      for (var i = 0; i < pages.length; i++) {
        expect(await second.loadResource(pages[i]), contents[i], reason: pages[i]);
      }
    });

    test('two sessions on the same bytes never share verification state', () async {
      final bytes = _bytes('rar5-hash-solid.cbr');
      final a = await BookSession.open(bytes);
      final b = await BookSession.open(bytes);
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final pages = (a.book as ComicBook).pages.map((final p) => p.path).toList();

      final lastOfA = pages.last;
      final firstOfB = pages.first;
      expect(await a.loadResource(lastOfA), isNotNull);
      expect(await b.loadResource(firstOfB), isNotNull);
      expect(await b.loadResource(lastOfA), isNotNull);
      expect(await a.loadResource(firstOfB), isNotNull);
    });

    test('stored members inside a solid chain verify through the session', () async {
      // s-solid-stored.jpg is a stored record marked solid between
      // compressed members; the chain path must route it through the
      // verifying inflate.
      final bytes = _bytes('rar5-hash-solid.cbr');
      final rar = RarRandomAccess.open(MemoryZipByteSource(bytes));
      addTearDown(rar.close);
      final record = rar.find('s-solid-stored.jpg');
      expect(record, isNotNull);
      final content = rar.inflate(record!);
      final row = _manifestRow('rar5-hash-solid.cbr');
      final pinned = (row['entries'] as List).cast<Map<String, Object?>>().singleWhere(
        (final entry) => entry['name'] == 's-solid-stored.jpg',
      );
      expect(_hex(Uint8List.fromList(crypto.sha256.convert(content).bytes)), pinned['sha256']);
    });
  });

  group('RAR 5 hash verification keeps the CRC and limit contracts (RH06)', () {
    test('the expansion limit rejects before any decode or hashing', () async {
      // The declared size above the requested bound is refused by the
      // existing session caps before the decoder — and the hasher —
      // ever run; the failure is the limit, not a checksum.
      final bytes = _bytes('rar5-hash-m3.cbr');
      final rar = RarRandomAccess.open(MemoryZipByteSource(bytes));
      addTearDown(rar.close);
      final record = rar.find('m-medium.jpg');
      expect(record, isNotNull);
      await expectLater(
        Future.sync(() => rar.inflate(record!, maxBytes: 1024)),
        throwsA(
          isA<InvalidBookException>().having(
            (final error) => error.toString(),
            'message',
            contains('expansion limit'),
          ),
        ),
      );
      // Below the bound the same record verifies and publishes.
      final content = rar.inflate(record!, maxBytes: record.uncompressedSize);
      final row = _manifestRow('rar5-hash-m3.cbr');
      final pinned = (row['entries'] as List).cast<Map<String, Object?>>().singleWhere(
        (final entry) => entry['name'] == 'm-medium.jpg',
      );
      expect(_hex(Uint8List.fromList(crypto.sha256.convert(content).bytes)), pinned['sha256']);
    });
  });
}
