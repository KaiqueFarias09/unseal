/// Deterministic fuzz input generation: family × seed × index → one
/// stable input.
///
/// The same triple ALWAYS produces the same bytes on the same SDK, so
/// any campaign failure is reproducible through `tool/fuzz_runner.dart
/// single --family=… --seed=… --index=…`.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'fuzz_hostile.dart';
import 'fuzz_mutators.dart';
import 'fuzz_seeds.dart';

/// Format families under fuzz coverage.
enum FuzzFamily {
  /// Zip-backed containers: EPUB, DOCX, ODT, TXTZ, HTMLZ, CBZ, CBC.
  zip,

  /// PDF documents (filters, xref, object structures).
  pdf,

  /// MOBI/AZW3 PalmDB containers.
  mobi,

  /// FB2 XML documents.
  fb2,

  /// Plain TXT/HTML and their zip wrappers.
  text,

  /// AZW4 (PalmDB-wrapped PDF).
  azw4,

  /// Comic archives (CBR/CB7/CBC detection surfaces).
  comic,

  /// Cover image bytes.
  images;

  /// All families, stable order for campaigns.
  static List<FuzzFamily> get all => FuzzFamily.values.toList();
}

/// One generated fuzz input.
final class FuzzInput {
  FuzzInput({required this.fixtureId, required this.family, required this.bytes});

  /// Stable identifier for reports (`gen-<family>-<seed>-<index>`).
  final String fixtureId;

  /// The family that generated the input.
  final FuzzFamily family;

  /// The input bytes.
  final Uint8List bytes;
}

/// Valid seeds by family (built lazily once per process).
final Map<FuzzFamily, List<MapEntry<String, Uint8List>>> _seedsByFamily = _groupSeeds();

Map<FuzzFamily, List<MapEntry<String, Uint8List>>> _groupSeeds() {
  final grouped = <FuzzFamily, List<MapEntry<String, Uint8List>>>{};
  for (final entry in fuzzSeeds().entries) {
    final family = _familyOfSeed(entry.key);
    grouped.putIfAbsent(family, () => <MapEntry<String, Uint8List>>[]).add(entry);
  }
  return grouped;
}

FuzzFamily _familyOfSeed(final String name) {
  if (name.startsWith('pdf')) return FuzzFamily.pdf;
  if (name.startsWith('mobi')) return FuzzFamily.mobi;
  if (name.startsWith('azw4')) return FuzzFamily.azw4;
  if (name.startsWith('fb2')) return FuzzFamily.fb2;
  if (name.startsWith('epub') || name.startsWith('docx') || name.startsWith('odt')) {
    return FuzzFamily.zip;
  }
  if (name.startsWith('cbz')) return FuzzFamily.comic;
  return FuzzFamily.text;
}

/// Generates the deterministic input for (family, seed, index).
///
/// Strategy rotates by index % 4:
///
/// * 0 — mutated valid seed (structural mutations of a parseable doc)
/// * 1 — magic-conforming random tail (sniffer passes, parser fumes)
/// * 2 — structural hostile construction (bombs, deep nesting)
/// * 3 — pure random bytes (sniffer-level chaos)
FuzzInput generateFuzzInput({
  required final FuzzFamily family,
  required final int seed,
  required final int index,
}) {
  final random = Random(seed * 1000003 + index);
  final fixtureId = 'gen-${family.name}-$seed-$index';
  final bytes = switch (index % 4) {
    0 => _mutatedSeed(family, random),
    1 => _magicRandom(family, random),
    2 => _structuralHostile(family, random, index),
    _ => _pureRandom(random),
  };
  return FuzzInput(fixtureId: fixtureId, family: family, bytes: bytes);
}

Uint8List _mutatedSeed(final FuzzFamily family, final Random random) {
  final seeds = _seedsByFamily[family] ?? _seedsByFamily[FuzzFamily.text]!;
  final seed = seeds[random.nextInt(seeds.length)].value;

  return mutateBytes(seed, random, rounds: 1 + random.nextInt(3));
}

Uint8List _magicRandom(final FuzzFamily family, final Random random) {
  const magics = <FuzzFamily, List<int>>{
    FuzzFamily.zip: <int>[0x50, 0x4B, 0x03, 0x04],
    FuzzFamily.pdf: <int>[0x25, 0x50, 0x44, 0x46, 0x2D],
    FuzzFamily.mobi: <int>[],
    FuzzFamily.fb2: <int>[0x3C, 0x3F, 0x78, 0x6D, 0x6C],
    FuzzFamily.text: <int>[],
    FuzzFamily.azw4: <int>[],
    FuzzFamily.comic: <int>[0x52, 0x61, 0x72, 0x21, 0x1A, 0x07],
    FuzzFamily.images: <int>[0x89, 0x50, 0x4E, 0x47],
  };
  final magic = magics[family] ?? const <int>[];
  if (magic.isEmpty) return randomPrintableText(random);

  return randomBytesWithMagic(magic, random);
}

Uint8List _structuralHostile(final FuzzFamily family, final Random random, final int index) {
  // Escalation ladder: the index selects among constructions so
  // campaigns sweep every stress family-by-family.
  switch (family) {
    case FuzzFamily.pdf:
      return switch (index ~/ 4 % 4) {
        0 => buildDeepNestedPdf(1000 + random.nextInt(20) * 1000),
        1 => buildChainedFlatePdf(stages: 2, targetBytes: 4 << 20),
        2 => buildLzwBombPdf(targetBytes: 4 << 20),
        _ => buildChainedFlatePdf(stages: 3, targetBytes: 2 << 20),
      };
    case FuzzFamily.zip:
      return switch (index ~/ 4 % 3) {
        0 => buildZipBombEpub(targetBytes: 4 << 20),
        1 => _manyEntryZip(500 + random.nextInt(10) * 100),
        _ => _deepPathZip(64 + random.nextInt(16) * 32),
      };
    case FuzzFamily.fb2:
      return buildDeepNestedFb2(1000 + random.nextInt(30) * 1000);
    case FuzzFamily.mobi:
      final seeds = _seedsByFamily[FuzzFamily.mobi]!;
      return buildMobiLyingRecordCount(seeds.first.value, random.nextInt(0x10000));
    case FuzzFamily.azw4:
      // AZW4 wrapping a hostile PDF payload.
      return _azw4Wrapping(switch (index ~/ 4 % 2) {
        0 => buildDeepNestedPdf(20000),
        _ => buildChainedFlatePdf(stages: 2, targetBytes: 2 << 20),
      });
    case FuzzFamily.comic:
      return switch (index ~/ 4 % 2) {
        0 => buildZipBombEpub(targetBytes: 2 << 20), // CBZ-shaped bomb
        _ => randomBytesWithMagic(const <int>[0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], random),
      };
    case FuzzFamily.images:
      return randomBytesWithMagic(switch (random.nextInt(3)) {
        0 => const <int>[0x89, 0x50, 0x4E, 0x47],
        1 => const <int>[0xFF, 0xD8, 0xFF],
        _ => const <int>[0x47, 0x49, 0x46, 0x38],
      }, random);
    case FuzzFamily.text:
      return randomPrintableText(random, maxLength: 8192);
  }
}

Uint8List _pureRandom(final Random random) {
  final length = 1 + random.nextInt(4096);
  final out = Uint8List(length);
  for (var index = 0; index < length; index++) {
    out[index] = random.nextInt(256);
  }

  return out;
}

Uint8List _manyEntryZip(final int count) {
  final bytes = Uint8List.fromList('x'.codeUnits);
  final archive = Archive();
  for (var index = 0; index < count; index++) {
    archive.addFile(ArchiveFile('e$index.txt', 1, bytes)..lastModTime = 946684800);
  }

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Uint8List _deepPathZip(final int depth) {
  final name = '${List.filled(depth, 'd').join('/')}/leaf.txt';
  final archive = Archive()
    ..addFile(ArchiveFile(name, 1, Uint8List.fromList('x'.codeUnits))..lastModTime = 946684800);

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

/// Wraps [pdf] as an AZW4-style PalmDB payload (record 1 holds the
/// PDF bytes; the PDB header announces them through the record list).
Uint8List _azw4Wrapping(final Uint8List pdf) {
  // Minimal PalmDB: 78-byte header, BOOK/MOBI type, one record.
  final header = Uint8List(78 + 8 + 2);
  final name = 'FuzzAZW4'.codeUnits;
  header.setRange(0, name.length, name);
  final view = ByteData.sublistView(header);
  view.setUint32(60, 0x424F4F4B); // 'BOOK'
  view.setUint32(64, 0x4D4F4249); // 'MOBI'
  view.setUint16(76, 1); // record count
  view.setUint32(78, 88); // record 0 data offset
  for (var index = 82; index < 87; index++) {
    view.setUint8(index, 0);
  }
  view.setUint8(87, 1);
  final out = BytesBuilder(copy: false)
    ..add(header)
    ..add(pdf);

  return out.toBytes();
}
