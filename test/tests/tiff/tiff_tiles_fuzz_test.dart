import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../../fuzz/harness/fuzz_invariants.dart';
import '../../fuzz/harness/fuzz_mutators.dart';
import '../../support/tiff_tiled_embedded.dart';

/// Bounded mutation campaign over the tiled corpus: every mutant must
/// either decode or fail with a typed exception, never with a raw
/// `RangeError`, `FormatException`, or a parser implementation error.
/// Deterministic seeds keep the campaign reproducible; the extended
/// `--tags fuzz` suite multiplies the same corpus with more rounds.
void main() {
  final seeds = <String, Uint8List>{
    ...embeddedTiledTiffFixtures,
    for (final name in const [
      'gray8-none-t16-le.tif',
      'bilevel-packbits-t16.tif',
      'gray16-none-t16-be.tif',
      'rgb8-exact-32x32-t32.tif',
      'gray4-none-t16.tif',
      'bilevel-g3-2d-fill-t32x16.tif',
    ])
      name: Uint8List.fromList(File('test/resources/tiff/tiled/$name').readAsBytesSync()),
  };

  test('TT05 fuzz: 896 tiled mutants decode or fail typed in process', () {
    final random = Random(20261018);
    var decoded = 0;
    var typed = 0;
    final defects = <String>[];
    seeds.forEach((final name, final seed) {
      for (var mutant = 0; mutant < 64; mutant++) {
        final bytes = mutateBytes(seed, random, rounds: 1 + random.nextInt(4));
        try {
          Unseal.parse(bytes);
          decoded++;
        } on UnsealException {
          typed++;
        } on Object catch (error) {
          defects.add('$name#$mutant: ${error.runtimeType}: $error');
        }
      }
    });
    expect(defects, isEmpty, reason: defects.take(5).join('\n'));
    expect(decoded + typed, seeds.length * 64);
    expect(typed, greaterThan(0));
  });

  test('TT05 fuzz: sampled tiled mutants stay bounded in a killable worker', () async {
    final random = Random(20261019);
    final names = seeds.keys.toList();
    final failures = <String>[];
    for (var index = 0; index < 24; index++) {
      final name = names[index % names.length];
      final bytes = mutateBytes(seeds[name]!, random, rounds: 2 + random.nextInt(3));
      final verdict = await runBoundedParse(bytes, timeout: const Duration(seconds: 20));
      if (verdict.isDefect) failures.add('$name#$index: ${verdict.defectSummary}');
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
