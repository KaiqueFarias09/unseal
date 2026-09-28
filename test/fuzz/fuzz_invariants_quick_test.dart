import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'harness/fuzz_inputs.dart';
import 'harness/fuzz_invariants.dart';
import 'harness/fuzz_seeds.dart';

/// Quick deterministic fuzz invariants (default CI suite).
///
/// Every input runs inside a killable worker isolate; a violation of
/// the typed-error / termination / recursion invariants fails the
/// suite with a reproducible `--family --seed --index` triple. The
/// long campaigns live in `tool/fuzz_runner.dart` and the `fuzz`-tag
/// suites; this file stays fast enough for every `dart test` run.
void main() {
  const timeout = Duration(seconds: 30);
  const sessionTimeout = Duration(seconds: 20);

  test('every valid seed parses or throws a typed exception', () async {
    final failures = <String>[];
    for (final seed in fuzzSeeds().entries) {
      final verdict = await runBoundedParse(seed.value, timeout: timeout);
      if (verdict.isDefect) {
        failures.add('${seed.key}: ${verdict.defectSummary}');
      }
    }
    expect(failures, isEmpty, reason: 'seed invariants violated: $failures');
  });

  test('seeded mutation sweep keeps every entry point typed', () async {
    final failures = <String>[];
    const perFamily = 16; // 4 strategies × 4 escalation steps.
    for (final family in FuzzFamily.all) {
      for (var index = 0; index < perFamily; index++) {
        final input = generateFuzzInput(family: family, seed: quickSeed, index: index);
        final verdict = await runBoundedParse(input.bytes, timeout: timeout);
        if (verdict.isDefect) {
          failures.add('${input.fixtureId} (${input.bytes.length}B): ${verdict.defectSummary}');
        }
      }
    }
    expect(failures, isEmpty, reason: 'fuzz invariants violated: $failures');
  });

  test('degenerate inputs (empty, byte, header-only) stay typed', () async {
    final failures = <String>[];
    for (final bytes in degenerateInputs()) {
      final verdict = await runBoundedParse(bytes, timeout: timeout);
      if (verdict.isDefect) {
        failures.add('${_label(bytes)}: ${verdict.defectSummary}');
      }
    }
    expect(failures, isEmpty, reason: 'degenerate-input invariants violated: $failures');
  });

  test('session opens over valid seeds hold the header invariants', () async {
    final counts = <String, int>{};
    final failures = <String>[];
    for (final seed in fuzzSeeds().entries) {
      if (!_sessionFamilies.contains(familyOfSeed(seed.key))) continue;
      final verdict = await runBoundedSessionOpen(seed.value, timeout: sessionTimeout);
      counts[verdict.status.name] = (counts[verdict.status.name] ?? 0) + 1;
      if (_isSessionDefect(verdict)) failures.add('${seed.key}: ${verdict.defectSummary}');
    }
    _report('session seeds', counts);
    expect(failures, isEmpty, reason: 'session seed invariants violated: $failures');
  });

  test('session opens over hostile zip/comic/pdf mutations stay typed', () async {
    final counts = <String, int>{};
    final failures = <String>[];
    const perFamily = 16; // 4 strategies × 4 escalation steps.
    for (final family in _sessionFamilies) {
      for (var index = 0; index < perFamily; index++) {
        final input = generateFuzzInput(family: family, seed: quickSeed, index: index);
        final verdict = await runBoundedSessionOpen(input.bytes, timeout: sessionTimeout);
        counts[verdict.status.name] = (counts[verdict.status.name] ?? 0) + 1;
        if (_isSessionDefect(verdict)) {
          failures.add('${input.fixtureId} (${input.bytes.length}B): ${verdict.defectSummary}');
        }
      }
    }
    _report('session mutations', counts);
    expect(failures, isEmpty, reason: 'session fuzz invariants violated: $failures');
  });
}

/// The families whose containers open through `BookSession`: zip
/// (EPUB/CBZ), comics (CBR/CBZ) and PDF.
const Set<FuzzFamily> _sessionFamilies = <FuzzFamily>{
  FuzzFamily.zip,
  FuzzFamily.comic,
  FuzzFamily.pdf,
};

/// A session-open defect is an untyped error, a worker death or a
/// violated header invariant. A bounded timeout is an accepted
/// classification (the killer reaps the wedged open at the budget);
/// a hang beyond the budget cannot exist by construction.
bool _isSessionDefect(final FuzzVerdict verdict) =>
    verdict.status == FuzzStatus.untyped || verdict.status == FuzzStatus.crash;

/// One-line classification trace for campaign reports.
void _report(final String label, final Map<String, int> counts) {
  final summary = [
    for (final status in FuzzStatus.values)
      if (counts.containsKey(status.name)) '${status.name}=${counts[status.name]}',
  ].join(' ');
  stdout.writeln('$label: $summary');
}

/// Campaign seed used by the quick suite (fixed, never wall-clock).
const int quickSeed = 20260913;

/// Degenerate boundary inputs every entry point must survive typed.
List<Uint8List> degenerateInputs() => <Uint8List>[
  Uint8List(0),
  Uint8List.fromList(<int>[0x00]),
  Uint8List.fromList(<int>[0x50, 0x4B]), // 'PK'
  Uint8List.fromList(<int>[0x25, 0x50, 0x44, 0x46]), // '%PDF'
  Uint8List.fromList(<int>[0x37, 0x7A, 0xBC, 0xAF]), // 7z magic head
  Uint8List.fromList(<int>[0x52, 0x61, 0x72, 0x21]), // 'Rar!'
  Uint8List.fromList('BOOKMOBI'.codeUnits),
  Uint8List.fromList('{\\rtf1'.codeUnits), // truncated RTF (typed failure)
  Uint8List.fromList('<?xml version="1.0"?>'.codeUnits),
  Uint8List.fromList(List<int>.filled(4096, 0xFF)),
];

String _label(final List<int> bytes) =>
    'bytes[${bytes.length}]=${bytes.take(8).map((final b) => b.toRadixString(16)).join(' ')}';
