/// Corpus-driven invariants (extended mode, tag: fuzz).
///
/// Runs the WHOLE tracked corpus (bounded per-file size) plus seeded
/// mutations of every corpus file through the killable-worker
/// invariants. The regular CI lane excludes this tag; run it explicitly
/// with `dart test --tags fuzz`.
@Tags(<String>['fuzz'])
library;

import 'dart:math';

import 'package:test/test.dart';

import 'harness/fuzz_corpus.dart';
import 'harness/fuzz_invariants.dart';
import 'harness/fuzz_mutators.dart';

void main() {
  test(
    'extended corpus campaign respects the parse invariants',
    () async {
      final root = fuzzCorpusRoot();
      expect(root, isNotNull, reason: 'tracked fuzz corpus is missing');
      final files = fuzzCorpusFiles(limit: 512);
      expect(files, isNotEmpty, reason: 'tracked fuzz corpus is empty');
      final failures = <String>[];
      for (final file in files) {
        final bytes = file.readAsBytesSync();
        final id = fuzzCorpusFixtureId(file, root!);
        final verdict = await runBoundedParse(bytes, timeout: const Duration(seconds: 120));
        if (verdict.isDefect) failures.add('$id: ${verdict.defectSummary}');

        // String.hashCode is per-process randomized; derive a stable
        // seed from the path instead.
        var pathSeed = 0;
        for (final codeUnit in id.codeUnits) {
          pathSeed = (pathSeed * 31 + codeUnit) & 0x7FFFFFFF;
        }
        final random = Random(pathSeed);
        for (var round = 0; round < 3; round++) {
          final mutated = mutateBytes(bytes, random, rounds: 2);
          final mutatedVerdict = await runBoundedParse(
            mutated,
            timeout: const Duration(seconds: 120),
          );
          if (mutatedVerdict.isDefect) {
            failures.add('$id~mut$round: ${mutatedVerdict.defectSummary}');
          }
        }
      }
      expect(failures, isEmpty, reason: 'extended corpus invariants violated: $failures');
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
