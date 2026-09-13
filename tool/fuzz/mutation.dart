import 'dart:typed_data';

import 'seeded_random.dart';
import 'structure_offsets.dart';

/// One deterministic fuzz input derived from a seed fixture.
final class FuzzCase {
  const FuzzCase({
    required this.id,
    required this.kind,
    required this.description,
    required this.bytes,
  });

  /// Stable identifier, derived from the operation and offsets only —
  /// never from file contents — so ids are safe to commit in reports.
  final String id;

  /// Either `truncation` or `mutation`.
  final String kind;

  /// Human-readable summary of the transformation (offsets and sizes only).
  final String description;

  /// The transformed bytes.
  final Uint8List bytes;
}

/// Enumerates deterministic TRUNCATION cases over [seed].
///
/// Cases are anchored on structurally interesting offsets from
/// [StructureScan.scan] — EOCD, central directory entries, xref,
/// `%%EOF`, PalmDB record boundaries — plus a few fractional cuts:
///
/// * `head@o`  keep `bytes[0:o)` — drops everything after the landmark.
/// * `tail@o`  keep `bytes[o:length)` — drops the container header side.
/// * `cut@o+w` remove a window `[o, o+w)` around the landmark.
/// * `frac:p`  proportional cuts at 10%..90% of the file.
///
/// The result is a lazy iterable: cases are built on demand, so huge
/// seeds never materialize every variant at once.
Iterable<FuzzCase> truncationCases(final Uint8List seed) sync* {
  if (seed.isEmpty) {
    return;
  }
  final scan = StructureScan.scan(seed);
  final seen = <String>{};

  FuzzCase? emit(final String id, final String description, final Uint8List bytes) {
    if (bytes.isEmpty || bytes.length == seed.length || !seen.add(id)) {
      return null;
    }
    return FuzzCase(id: id, kind: 'truncation', description: description, bytes: bytes);
  }

  for (final landmark in scan.offsets) {
    final o = landmark.offset;
    if (o <= 0 || o >= seed.length) {
      continue;
    }
    final head = emit(
      'head@${landmark.name}',
      'keep first $o bytes (cut at ${landmark.name})',
      Uint8List.sublistView(seed, 0, o),
    );
    if (head != null) {
      yield head;
    }
    final tail = emit(
      'tail@${landmark.name}',
      'drop first $o bytes (cut at ${landmark.name})',
      Uint8List.sublistView(seed, o),
    );
    if (tail != null) {
      yield tail;
    }
    final window = (seed.length - o).clamp(1, 64);
    final end = (o + window).clamp(0, seed.length);
    final cut = emit(
      'cut@${landmark.name}+$window',
      'remove bytes [$o, $end) around ${landmark.name}',
      _splice(seed, o, end),
    );
    if (cut != null) {
      yield cut;
    }
    // Off-by-one neighbours of every landmark.
    for (final delta in const [-1, 1]) {
      final o2 = o + delta;
      if (o2 <= 0 || o2 >= seed.length) {
        continue;
      }
      final near = emit(
        'head@${landmark.name}${delta < 0 ? '-' : '+'}${delta.abs()}',
        'keep first $o2 bytes (${landmark.name}$delta)',
        Uint8List.sublistView(seed, 0, o2),
      );
      if (near != null) {
        yield near;
      }
    }
  }

  for (var percent = 10; percent <= 90; percent += 10) {
    final o = (seed.length * percent) ~/ 100;
    if (o <= 0 || o >= seed.length) {
      continue;
    }
    final frac = emit(
      'head@frac$percent',
      'keep first $o bytes ($percent%)',
      Uint8List.sublistView(seed, 0, o),
    );
    if (frac != null) {
      yield frac;
    }
  }
}

/// Enumerates deterministic MUTATION cases over [seed].
///
/// [seedValue] drives every pseudo-random choice; the same
/// `(seed, seedValue)` pair always yields byte-identical cases.
/// Mutations are a mix of structure-anchored edits (zero/set/inject at
/// landmark offsets) and uniformly random bit flips, byte sets and
/// range operations. [count] bounds the number of cases returned.
Iterable<FuzzCase> mutationCases(
  final Uint8List seed, {
  final int seedValue = 1,
  final int count = 32,
}) sync* {
  if (seed.isEmpty || count <= 0) {
    return;
  }
  final scan = StructureScan.scan(seed);
  final landmarks = scan.offsets;
  final random = SeededRandom(seedValue * 0x2545F4914F6CDD1D);
  var emitted = 0;
  final seen = <String>{};

  // Structure-anchored edits come first: every landmark gets a deterministic
  // edit from a rotating operation table.
  const operations = ['zero', 'set-ff', 'flip-bit', 'inject-marker', 'inject-random'];
  for (final landmark in landmarks) {
    if (emitted >= count) {
      return;
    }
    final operation = operations[emitted % operations.length];
    final o = landmark.offset;
    if (o < 0 || o >= seed.length) {
      continue;
    }
    final (id, description, bytes) = switch (operation) {
      'zero' => (
        'zero@${landmark.name}',
        'zero 8 bytes at ${landmark.name} ($o)',
        _overwrite(seed, o, Uint8List(8)),
      ),
      'set-ff' => (
        'set-ff@${landmark.name}',
        'set 8 bytes to 0xFF at ${landmark.name} ($o)',
        _overwrite(seed, o, Uint8List.fromList(List<int>.filled(8, 0xFF))),
      ),
      'flip-bit' => (
        'flip-bit@${landmark.name}',
        'flip one bit at ${landmark.name} ($o)',
        _flipBit(seed, o, random.below(8)),
      ),
      'inject-marker' => (
        'inject-marker@${landmark.name}',
        'inject 8 x 0x41 at ${landmark.name} ($o)',
        _spliceInsert(seed, o, Uint8List.fromList(List<int>.filled(8, 0x41))),
      ),
      _ => (
        'inject-random@${landmark.name}',
        'inject 16 random bytes at ${landmark.name} ($o)',
        _spliceInsert(seed, o, random.bytes(16)),
      ),
    };
    if (seen.add(id)) {
      emitted++;
      yield FuzzCase(id: id, kind: 'mutation', description: description, bytes: bytes);
    }
  }

  // Random edits fill the remaining budget.
  while (emitted < count) {
    final pos = random.below(seed.length);
    final choice = random.below(4);
    final (id, description, bytes) = switch (choice) {
      0 => () {
        final bit = random.below(8);
        return (
          'flip-${pos.toRadixString(16)}-bit$bit',
          'flip bit $bit at 0x${pos.toRadixString(16)}',
          _flipBit(seed, pos, bit),
        );
      }(),
      1 => () {
        final value = random.below(256);
        return (
          'set-${pos.toRadixString(16)}-0x${value.toRadixString(16)}',
          'overwrite one byte at 0x${pos.toRadixString(16)} with 0x${value.toRadixString(16)}',
          _overwrite(seed, pos, Uint8List.fromList([value])),
        );
      }(),
      2 => () {
        final window = random.pick(const [4, 16, 64]);
        return (
          'zero-range-${pos.toRadixString(16)}-w$window',
          'zero $window bytes at 0x${pos.toRadixString(16)}',
          _overwrite(seed, pos, Uint8List(window)),
        );
      }(),
      _ => () {
        final window = random.pick(const [8, 32]);
        return (
          'dup-range-${pos.toRadixString(16)}-w$window',
          'duplicate a $window-byte range onto itself at 0x${pos.toRadixString(16)}',
          _duplicateRange(seed, pos, window),
        );
      }(),
    };
    if (seen.add(id)) {
      emitted++;
      yield FuzzCase(id: id, kind: 'mutation', description: description, bytes: bytes);
    }
  }
}

/// Removes the range `[begin, end)` and closes the gap.
Uint8List _splice(final Uint8List source, final int begin, final int end) {
  final result = Uint8List(source.length - (end - begin));
  result.setRange(0, begin, source);
  result.setRange(begin, result.length, source, end);
  return result;
}

/// Overwrites `patch.length` bytes at [offset], clamped to the buffer.
Uint8List _overwrite(final Uint8List source, final int offset, final Uint8List patch) {
  final result = Uint8List.fromList(source);
  final end = (offset + patch.length).clamp(0, result.length);
  if (offset >= end) {
    return result;
  }
  result.setRange(offset, end, patch);
  return result;
}

/// Flips bit [bit] of the byte at [offset].
Uint8List _flipBit(final Uint8List source, final int offset, final int bit) {
  final result = Uint8List.fromList(source);
  result[offset] ^= 1 << bit;
  return result;
}

/// Inserts [patch] at [offset], growing the buffer.
Uint8List _spliceInsert(final Uint8List source, final int offset, final Uint8List patch) {
  final result = Uint8List(source.length + patch.length);
  result.setRange(0, offset, source);
  result.setRange(offset, offset + patch.length, patch);
  result.setRange(offset + patch.length, result.length, source, offset);
  return result;
}

/// Copies [window] bytes starting at [offset] back onto the buffer
/// starting at [offset] (self-overlapping duplication stress).
Uint8List _duplicateRange(final Uint8List source, final int offset, final int window) {
  final result = Uint8List.fromList(source);
  final end = (offset + window).clamp(0, result.length);
  if (offset >= end) {
    return result;
  }
  final copy = Uint8List.fromList(result.sublist(offset, end));
  final target = (offset + copy.length).clamp(0, result.length);
  result.setRange(offset, target, copy);
  return result;
}
