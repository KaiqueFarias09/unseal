// Tests for the mutation-campaign minimizer: a controlled failure must
// keep reproducing the SAME signature after the sample is reduced, for
// all three defect shapes — thrown error, isolate crash and timeout.
//
// The parsers are top-level functions because `probeParse` runs them in
// a fresh isolate, and the marker bytes make the failure deterministic
// and shrinkable: reduce away everything else and the marker must
// survive.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../tool/fuzz_book_campaign.dart';
import '../../tool/fuzz_book_campaign.dart' as fuzz_campaign;
import '../fuzz/harness/fuzz_invariants.dart';

const _boom = <int>[0x42, 0x4F, 0x4F, 0x4D]; // "BOOM"
const _die = <int>[0x44, 0x49, 0x45]; // "DIE"
const _zzz = <int>[0x5A, 0x5A, 0x5A]; // "ZZZ"

bool _contains(final Uint8List bytes, final List<int> marker) {
  outer:
  for (var start = 0; start + marker.length <= bytes.length; start++) {
    for (var offset = 0; offset < marker.length; offset++) {
      if (bytes[start + offset] != marker[offset]) continue outer;
    }
    return true;
  }
  return false;
}

/// Throws a foreign `RangeError` when the BOOM marker is present.
Future<void> throwOnMarker(final Uint8List bytes) async {
  if (_contains(bytes, _boom)) throw RangeError('controlled marker failure');
}

/// Exits the worker isolate without sending a parse result when the DIE
/// marker is present. The real `probeParse` must classify this as a crash.
Future<void> exitOnMarker(final Uint8List bytes) async {
  if (_contains(bytes, _die)) Isolate.exit();
}

/// Hangs past any short deadline when the ZZZ marker is present.
Future<void> hangOnMarker(final Uint8List bytes) async {
  if (_contains(bytes, _zzz)) await Future<void>.delayed(const Duration(seconds: 5));
}

/// Fills the filler bytes with the given marker near the end, so the
/// minimizer has real shrink work to do.
Uint8List _seeded(final List<int> marker) {
  final bytes = Uint8List(2048);
  for (var index = 0; index < bytes.length; index++) {
    bytes[index] = 0x61 + (index % 26); // plain "aaa…" filler
  }
  bytes.setRange(bytes.length - 32, bytes.length - 32 + marker.length, marker);
  return bytes;
}

void main() {
  group('failureSignature', () {
    test('records the thrown type instead of classifying the throw as ok', () async {
      final signature = await failureSignature(
        _seeded(_boom),
        parse: throwOnMarker,
        timeout: const Duration(seconds: 5),
      );
      expect(signature, 'throw:RangeError');
    });

    test('returns ok when the parser completes', () async {
      final signature = await failureSignature(
        _seeded(<int>[0x00]),
        parse: throwOnMarker,
        timeout: const Duration(seconds: 5),
      );
      expect(signature, 'ok');
    });

    test('keeps a successful result ahead of the isolate exit notification', () async {
      for (var attempt = 0; attempt < 8; attempt++) {
        final signature = await failureSignature(
          _seeded(<int>[0x00]),
          parse: throwOnMarker,
          timeout: const Duration(seconds: 5),
        );
        expect(signature, 'ok');
      }
    });

    test('classifies a worker that exits without a result as crash', () async {
      final signature = await failureSignature(
        _seeded(_die),
        parse: exitOnMarker,
        timeout: const Duration(seconds: 5),
      );
      expect(signature, 'crash');
    });

    test('records a deadline hit as timeout (a silent worker death included)', () async {
      final signature = await failureSignature(
        _seeded(_zzz),
        parse: hangOnMarker,
        timeout: const Duration(milliseconds: 200),
      );
      expect(signature, 'timeout');
    });
  });

  group('minimizeFailure', () {
    test('a thrown failure shrinks to a smaller sample with the same signature', () async {
      Future<String> probe(final Uint8List bytes) =>
          failureSignature(bytes, parse: throwOnMarker, timeout: const Duration(seconds: 5));
      final original = _seeded(_boom);

      final minimized = await minimizeFailure(
        bytes: original,
        signature: 'throw:RangeError',
        probe: probe,
      );

      expect(minimized, isNotNull);
      expect(minimized!.length, lessThan(original.length ~/ 2));
      expect(
        _contains(minimized, _boom),
        isTrue,
        reason: 'the marker causing the failure must survive reduction',
      );
      expect(await probe(minimized), 'throw:RangeError');
    });

    test('a crash signature from a real worker exit shrinks and still crashes', () async {
      final original = _seeded(_die);
      Future<String> probe(final Uint8List bytes) =>
          failureSignature(bytes, parse: exitOnMarker, timeout: const Duration(seconds: 5));

      final minimized = await minimizeFailure(bytes: original, signature: 'crash', probe: probe);

      expect(minimized, isNotNull);
      expect(minimized!.length, lessThan(original.length ~/ 2));
      expect(_contains(minimized, _die), isTrue);
      expect(await probe(minimized), 'crash');
    });

    test('a timeout shrinks to a smaller sample with the timeout signature', () async {
      Future<String> probe(final Uint8List bytes) =>
          failureSignature(bytes, parse: hangOnMarker, timeout: const Duration(milliseconds: 200));
      final original = _seeded(_zzz);

      final minimized = await minimizeFailure(bytes: original, signature: 'timeout', probe: probe);

      expect(minimized, isNotNull);
      expect(minimized!.length, lessThan(original.length ~/ 2));
      expect(_contains(minimized, _zzz), isTrue);
      expect(await probe(minimized), 'timeout');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('returns null when the input does not reproduce the given signature', () async {
      final minimized = await minimizeFailure(
        bytes: _seeded(<int>[0x00]),
        signature: 'throw:RangeError',
        probe: (final bytes) async => 'ok',
      );
      expect(minimized, isNull);
    });
  });

  test('campaign reports use fixture IDs instead of source paths or basenames', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp('fuzz-campaign-privacy-');
    try {
      final privateName = 'private-title-do-not-report.epub';
      final input = File('${temporaryDirectory.path}/$privateName')
        ..writeAsBytesSync(Uint8List.fromList(<int>[0x00, 0x01, 0x02, 0x03]));
      final report = File('${temporaryDirectory.path}/report.json');

      await fuzz_campaign.main(<String>[
        '--input=${input.path}',
        '--rounds=0',
        '--timeout-seconds=5',
        '--out=${report.path}',
      ]);

      final reportText = report.readAsStringSync();
      final decoded = jsonDecode(reportText) as Map<String, Object?>;
      final pristine = (decoded['pristine']! as List).single as Map<String, Object?>;
      expect(pristine['fixtureId'], 'fixture-001');
      expect(reportText, isNot(contains(input.path)));
      expect(reportText, isNot(contains(privateName)));
    } finally {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('a skipped entry cannot hide a later invariant failure', () {
    final verdict = FuzzVerdict(<FuzzEntryPoint, FuzzEntryVerdict>{
      FuzzEntryPoint.detect: FuzzEntryVerdict(FuzzStatus.skipped),
      FuzzEntryPoint.parse: FuzzEntryVerdict(FuzzStatus.untyped, errorType: 'RangeError'),
    });

    expect(verdict.status, FuzzStatus.untyped);
    expect(verdict.isDefect, isTrue);
  });
}
