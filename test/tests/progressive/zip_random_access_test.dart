import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/foundation/archive/archive_access.dart';
import 'package:unseal/src/foundation/archive/zip_byte_source.dart';
import 'package:unseal/src/foundation/archive/zip_random_access.dart';
import 'package:unseal/src/foundation/exceptions/unseal_exception.dart';
import 'package:unseal/src/foundation/images/image_type_sniffer.dart';

void main() {
  group('ZipRandomAccess', () {
    final fixtures = [
      'test/resources/books/epub/elements-of-chemistry.epub',
      'test/resources/books/epub/fxl-mixed-fixed-override.epub',
      'test/resources/books/comic/halfpenny-surprise-1895.cbz',
    ];

    for (final fixture in fixtures) {
      test('inventory and per-entry inflation match the eager decode: $fixture', () {
        final bytes = File(fixture).readAsBytesSync();
        final source = ZipRandomAccess.open(MemoryZipByteSource(bytes));
        final eager = decodeBookZip(bytes);

        final eagerFiles = <String, ArchiveFile>{
          for (final file in eager.files)
            if (file.isFile) file.name: file,
        };
        final randomFiles = <String, ZipEntryRecord>{
          for (final record in source.entries)
            if (record.isFile) record.name: record,
        };
        expect(randomFiles.keys.toSet(), eagerFiles.keys.toSet());

        for (final entry in randomFiles.values) {
          final inflated = source.inflate(entry);
          final expected = eagerFiles[entry.name]!.content;
          expect(
            inflated.length,
            expected.length,
            reason: 'inflated length differs for ${entry.name}',
          );
          expect(inflated, expected, reason: 'inflated bytes differ for ${entry.name}');
        }
      });
    }

    test('find matches exact and case-insensitive names', () {
      final bytes = File('test/resources/books/epub/elements-of-chemistry.epub').readAsBytesSync();
      final source = ZipRandomAccess.open(MemoryZipByteSource(bytes));

      expect(source.find('META-INF/container.xml'), isNotNull);
      expect(source.find('meta-inf/CONTAINER.xml'), isNotNull);
      expect(source.find('does/not/exist.xml'), isNull);
    });

    test('case-insensitive duplicate paths select the first archive entry', () {
      final bytes = _builtZip(<(String, Uint8List)>[
        ('images/Cover.PNG', Uint8List.fromList(<int>[1])),
        ('images/cover.png', Uint8List.fromList(<int>[2])),
      ]);
      final archive = decodeBookZip(bytes);
      final expected = findArchiveFile(archive, 'images/cover.png')!;
      final source = ZipRandomAccess.open(MemoryZipByteSource(bytes));
      final actual = source.find('images/cover.png')!;

      expect(actual.name, expected.name);
      expect(source.inflate(actual), contentBytes(expected));
    });

    test('head returns a prefix usable for image sniffing', () {
      final bytes = File(
        'test/resources/books/comic/halfpenny-surprise-1895.cbz',
      ).readAsBytesSync();
      final source = ZipRandomAccess.open(MemoryZipByteSource(bytes));
      final eager = decodeBookZip(bytes);

      // Compare against entries the FULL parse classifies as images, so
      // stub or non-image .jpg names cannot flake the assertion.
      final imageNames = eager.files
          .where(
            (final file) =>
                file.isFile && sniffImageType(Uint8List.sublistView(file.content)) != null,
          )
          .map((final file) => file.name)
          .toSet();
      final records = source.entries.where((final entry) => imageNames.contains(entry.name));

      expect(records, isNotEmpty);
      for (final entry in records.take(3)) {
        final head = source.head(entry, 64);
        expect(head, isNotEmpty, reason: entry.name);
        expect(head.length, lessThanOrEqualTo(64));
        expect(sniffImageType(head), isNotNull, reason: entry.name);
      }
    });

    test('inflating past the bounded cap throws the typed error', () {
      final bytes = _builtZip(<(String, Uint8List)>[('a.txt', Uint8List(64))]);
      final source = ZipRandomAccess.open(MemoryZipByteSource(bytes));
      final entry = source.find('a.txt')!;

      expect(() => source.inflate(entry, maxBytes: 8), throwsA(isA<InvalidBookException>()));
    });

    test('a lying central directory over the expansion cap is rejected at open', () {
      final zip = _builtZip(<(String, Uint8List)>[('a.txt', Uint8List(32))]);
      // Patch the declared uncompressed size in the central directory to
      // a value above the 1 GiB container cap.
      final patched = _patchCentralDirectorySize(zip, 'a.txt', (2 << 30));

      expect(
        () => ZipRandomAccess.open(MemoryZipByteSource(Uint8List.fromList(patched))),
        throwsA(isA<InvalidBookException>()),
      );
    });

    test('a zip64 marker is a typed rejection, not a crash', () {
      final zip = _builtZip(<(String, Uint8List)>[('a.txt', Uint8List(32))]);
      final patched = _patchCentralDirectorySize(zip, 'a.txt', 0xFFFFFFFF);

      expect(
        () => ZipRandomAccess.open(MemoryZipByteSource(Uint8List.fromList(patched))),
        throwsA(isA<Zip64NotSupportedException>()),
      );
    });

    test('missing container files keep the typed contract', () {
      final bytes = Uint8List.fromList(<int>[0x50, 0x4b, 0x05, 0x06, 0, 0, 0, 0]);

      expect(
        () => ZipRandomAccess.open(MemoryZipByteSource(bytes)),
        throwsA(isA<InvalidBookException>()),
      );
    });

    test('close is safe and repeatable', () {
      final bytes = File('test/resources/books/epub/elements-of-chemistry.epub').readAsBytesSync();
      final source = ZipRandomAccess.open(MemoryZipByteSource(bytes));
      expect(source.find('META-INF/container.xml'), isNotNull);

      source.close();
      source.close();
    });
  });
}

/// Builds a minimal stored-entry zip: local headers, central directory
/// and EOCD, all little-endian.
Uint8List _builtZip(final List<(String, Uint8List)> entries) {
  final out = BytesBuilder();

  final locals = <(String, int, int, int)>[]; // name, offset, size, crc
  var crc = 0;
  for (final (name, content) in entries) {
    crc = getCrc32(content);
    final nameBytes = name.codeUnits;
    final offset = out.length;
    out.add(
      Uint8List.fromList([
        0x50, 0x4b, 0x03, 0x04, // local header signature
        20, 0, // version needed
        0, 0, // flags
        0, 0, // method: stored
        0, 0, 0, 0, // time/date
        ..._uint32(crc),
        ..._uint32(content.length),
        ..._uint32(content.length),
        ..._uint16(nameBytes.length),
        0, 0, // extra length
      ]),
    );
    out.add(Uint8List.fromList(nameBytes));
    out.add(content);
    locals.add((name, offset, content.length, crc));
  }

  final centralStart = out.length;
  for (final (name, offset, size, entryCrc) in locals) {
    final nameBytes = name.codeUnits;
    out.add(
      Uint8List.fromList([
        0x50, 0x4b, 0x01, 0x02, // central directory signature
        20, 0, 20, 0, // versions
        0, 0, // flags
        0, 0, // method: stored
        0, 0, 0, 0, // time/date
        ..._uint32(entryCrc),
        ..._uint32(size),
        ..._uint32(size),
        ..._uint16(nameBytes.length),
        0, 0, // extra length
        0, 0, // comment length
        0, 0, // disk number
        0, 0, // internal attributes
        0, 0, 0, 0, // external attributes
        ..._uint32(offset),
      ]),
    );
    out.add(Uint8List.fromList(nameBytes));
  }
  final centralSize = out.length - centralStart;

  out.add(
    Uint8List.fromList([
      0x50, 0x4b, 0x05, 0x06, // EOCD signature
      0, 0, 0, 0, // disk numbers
      ..._uint16(locals.length),
      ..._uint16(locals.length),
      ..._uint32(centralSize),
      ..._uint32(centralStart),
      0, 0, // comment length
    ]),
  );

  return out.toBytes();
}

/// Rewrites one entry's declared uncompressed size in the central
/// directory (first matching record).
List<int> _patchCentralDirectorySize(final Uint8List zip, final String name, final int size) {
  final bytes = Uint8List.fromList(zip);
  final nameBytes = name.codeUnits;
  // Scan for the central signature followed by the entry name.
  for (var i = 0; i < bytes.length - 46 - nameBytes.length; i++) {
    if (bytes[i] != 0x50 || bytes[i + 1] != 0x4b || bytes[i + 2] != 0x01 || bytes[i + 3] != 0x02) {
      continue;
    }
    var matches = true;
    for (var j = 0; j < nameBytes.length; j++) {
      if (bytes[i + 46 + j] != nameBytes[j]) {
        matches = false;
        break;
      }
    }
    if (!matches) continue;

    final sizeOffset = i + 24; // uncompressed size field
    ByteData.sublistView(bytes, sizeOffset, sizeOffset + 4).setUint32(0, size, Endian.little);

    return bytes;
  }

  fail('central directory record for $name not found');
}

List<int> _uint16(final int value) => [value & 0xFF, (value >> 8) & 0xFF];

List<int> _uint32(final int value) => [
  value & 0xFF,
  (value >> 8) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 24) & 0xFF,
];
