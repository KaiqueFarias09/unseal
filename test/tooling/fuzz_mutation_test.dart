import 'dart:typed_data';

import 'package:test/test.dart';

import '../../tool/fuzz/mutation.dart';
import '../../tool/fuzz/seeded_random.dart';
import '../../tool/fuzz/structure_offsets.dart';

/// Deterministic ZIP with 2 local headers, a central directory and an EOCD.
Uint8List _zipFixture() {
  final bytes = <int>[];
  final entryOffsets = <int>[];
  final entries = [
    [0x50, 0x4B, 0x03, 0x04, 1, 2, 3],
    [0x50, 0x4B, 0x03, 0x04, 9, 8, 7, 6, 5],
  ];
  for (final entry in entries) {
    entryOffsets.add(bytes.length);
    bytes.addAll(entry);
  }
  for (var i = 0; i < entries.length; i++) {
    bytes.addAll([0x50, 0x4B, 0x01, 0x02, i]);
  }
  final centralStart = bytes.length;
  bytes.addAll([0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0]);
  // footer so EOCD is not the final bytes
  bytes.addAll(List<int>.generate(16, (final i) => i));
  expect(bytes.length, greaterThan(centralStart));
  return Uint8List.fromList(bytes);
}

/// Minimal well-formed-enough PDF: header, one object, xref, trailer, %%EOF.
Uint8List _pdfFixture() {
  const body =
      '%PDF-1.4\n'
      '1 0 obj\n'
      '<</Type/Catalog>>\n'
      'endobj\n'
      'xref\n'
      '0 2\n'
      'trailer\n'
      '<</Size 2/Root 1 0 R>>\n'
      'startxref\n'
      '9\n'
      '%%EOF\n';
  return Uint8List.fromList(body.codeUnits);
}

/// PalmDB-shaped buffer: name, type/creator, record count 3, record list.
Uint8List _palmDbFixture() {
  final bytes = Uint8List(200);
  bytes.setRange(60, 64, 'BOOK'.codeUnits);
  bytes.setRange(64, 68, 'MOBI'.codeUnits);
  bytes[76] = 0;
  bytes[77] = 3;
  // Record info entries at 78: 4-byte offsets 100, 120, 140.
  for (var i = 0; i < 3; i++) {
    final base = 78 + i * 8;
    final offset = 100 + i * 20;
    bytes[base] = (offset >> 24) & 0xFF;
    bytes[base + 1] = (offset >> 16) & 0xFF;
    bytes[base + 2] = (offset >> 8) & 0xFF;
    bytes[base + 3] = offset & 0xFF;
  }
  return bytes;
}

void main() {
  group('StructureScan', () {
    test('finds ZIP landmarks', () {
      final scan = StructureScan.scan(_zipFixture());
      expect(scan.container, SeedContainer.zip);
      final names = scan.offsets.map((final o) => o.name).toList();
      expect(names.where((final n) => n == 'local-header-0'), isNotEmpty);
      expect(names.where((final n) => n == 'local-header-1'), isNotEmpty);
      expect(names.contains('central-directory-0'), isTrue);
      expect(names.contains('eocd'), isTrue);
      // Offsets are sorted ascending.
      final offsets = scan.offsets.map((final o) => o.offset).toList();
      expect(offsets, equals(List<int>.of(offsets)..sort()));
    });

    test('finds PDF landmarks', () {
      final scan = StructureScan.scan(_pdfFixture());
      expect(scan.container, SeedContainer.pdf);
      final names = scan.offsets.map((final o) => o.name).toList();
      expect(names.contains('pdf-header-0'), isTrue);
      expect(names.contains('obj-0'), isTrue);
      expect(names.contains('trailer-0'), isTrue);
      expect(names.contains('eof-0'), isTrue);
      expect(names.contains('startxref-0'), isTrue);
    });

    test('finds PalmDB record boundaries', () {
      final scan = StructureScan.scan(_palmDbFixture());
      expect(scan.container, SeedContainer.palmDb);
      final records = scan.offsets.where((final o) => o.name.startsWith('pdb-record')).toList();
      expect(records.map((final r) => r.offset), equals(const [100, 120, 140]));
    });

    test('plain text scans as unknown', () {
      final scan = StructureScan.scan(Uint8List.fromList('just some text here to scan'.codeUnits));
      expect(scan.container, SeedContainer.unknown);
    });
  });

  group('truncationCases', () {
    test('anchors cases on structural landmarks', () {
      final ids = truncationCases(_zipFixture()).map((final c) => c.id).toList();
      expect(ids, contains('head@eocd'));
      expect(ids.any((final id) => id.startsWith('head@local-header-')), isTrue);
      expect(ids, contains('tail@eocd'));
    });

    test('every case differs from the seed and is non-empty', () {
      final seed = _pdfFixture();
      for (final testCase in truncationCases(seed)) {
        expect(testCase.bytes, isNot(equals(seed)), reason: testCase.id);
        expect(testCase.bytes, isNotEmpty, reason: testCase.id);
        expect(testCase.kind, 'truncation');
      }
    });

    test('head@x truncation length matches the landmark offset', () {
      final seed = _palmDbFixture();
      final scan = StructureScan.scan(seed);
      final record2 = scan.offsets.firstWhere((final o) => o.name == 'pdb-record-2');
      final headCase = truncationCases(seed).firstWhere((final c) => c.id == 'head@pdb-record-2');
      expect(headCase.bytes.length, record2.offset);
    });
  });

  group('mutationCases', () {
    test('is deterministic per seed value', () {
      final seed = _zipFixture();
      final first = mutationCases(seed, seedValue: 42, count: 16).map((final c) => c.id).toList();
      final second = mutationCases(seed, seedValue: 42, count: 16).map((final c) => c.id).toList();
      expect(first, equals(second));
      // Bytes must match too, not just ids.
      final firstBytes = mutationCases(
        seed,
        seedValue: 42,
        count: 16,
      ).map((final c) => c.bytes).toList();
      final secondBytes = mutationCases(
        seed,
        seedValue: 42,
        count: 16,
      ).map((final c) => c.bytes).toList();
      expect(
        firstBytes.map((final b) => b.join(',')),
        equals(secondBytes.map((final b) => b.join(','))),
      );
    });

    test('different seed values diverge', () {
      final seed = _zipFixture();
      final a = mutationCases(seed, seedValue: 1, count: 24).map((final c) => c.id).toSet();
      final b = mutationCases(seed, seedValue: 2, count: 24).map((final c) => c.id).toSet();
      expect(a.difference(b), isNotEmpty);
    });

    test('respects the count bound and yields unique ids', () {
      final seed = _pdfFixture();
      final cases = mutationCases(seed, seedValue: 3, count: 40).toList();
      expect(cases.length, 40);
      expect(cases.map((final c) => c.id).toSet().length, 40);
    });

    test('structure-anchored mutations land on landmarks', () {
      final seed = _zipFixture();
      final ids = mutationCases(seed, seedValue: 5, count: 64).map((final c) => c.id).toList();
      // The operation table rotates over landmarks: with 5 ZIP landmarks the
      // anchored set covers zero/set-ff/flip-bit/inject-marker/inject-random.
      expect(ids.any((final id) => id.startsWith('zero@')), isTrue);
      expect(ids.any((final id) => id.startsWith('inject-marker@')), isTrue);
      expect(ids.any((final id) => id.startsWith('flip-bit@')), isTrue);
    });

    test('length-preserving operations preserve length', () {
      final seed = _zipFixture();
      for (final testCase in mutationCases(seed, seedValue: 9, count: 64)) {
        if (testCase.id.startsWith('inject-')) {
          expect(testCase.bytes.length, greaterThan(seed.length), reason: testCase.id);
        } else {
          expect(testCase.bytes.length, seed.length, reason: testCase.id);
        }
      }
    });
  });

  group('SeededRandom', () {
    test('same seed reproduces the stream', () {
      final a = SeededRandom(1234);
      final b = SeededRandom(1234);
      final streamA = List<int>.generate(64, (final _) => a.next64());
      final streamB = List<int>.generate(64, (final _) => b.next64());
      expect(streamA, equals(streamB));
    });

    test('below stays in range and covers the domain', () {
      final random = SeededRandom(7);
      final seen = <int>{};
      for (var i = 0; i < 1000; i++) {
        final value = random.below(5);
        expect(value, inInclusiveRange(0, 4));
        seen.add(value);
      }
      expect(seen.length, 5);
    });

    test('words contain only letters', () {
      final random = SeededRandom(99);
      expect(RegExp(r'^[a-z]+$').hasMatch(random.word(12)), isTrue);
    });
  });
}
