// Tests for the mutation-campaign minimizer: a controlled failure must
// keep reproducing the SAME signature after the sample is reduced, for
// all three defect shapes — thrown error, isolate crash and timeout.
//
// The parsers are top-level functions because `probeParse` runs them in
// a fresh isolate, and the marker bytes make the failure deterministic
// and shrinkable: reduce away everything else and the marker must
// survive.

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../tool/fuzz_book_campaign.dart';

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

/// Stub probe with the crash shape: the minimizer must preserve a
/// `crash` signature whenever the probe classifies one (the error port
/// fires for errors escaping the worker entry, e.g. spawn failures).
/// Empirically, a worker that dies SILENTLY — a kill request,
/// a fatal error losing the race with the result post — surfaces as
/// `timeout` through `probeParse`, which the timeout tests cover
/// end-to-end with the real probe.
Future<String> crashProbe(final Uint8List bytes) async {
  if (_contains(bytes, _die)) return 'crash';
  return 'ok';
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

    test('a crash signature shrinks to a smaller sample that still crashes', () async {
      final original = _seeded(_die);

      final minimized = await minimizeFailure(
        bytes: original,
        signature: 'crash',
        probe: crashProbe,
      );

      expect(minimized, isNotNull);
      expect(minimized!.length, lessThan(original.length ~/ 2));
      expect(_contains(minimized, _die), isTrue);
      expect(await crashProbe(minimized), 'crash');
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
}
