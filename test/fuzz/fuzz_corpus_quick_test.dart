import 'package:test/test.dart';

import 'harness/fuzz_corpus.dart';
import 'harness/fuzz_invariants.dart';

/// Corpus-driven invariants (quick mode).
///
/// Consumes the tracked fuzz corpus at `test/resources/fuzz/` when
/// the parallel tooling stream has landed it; SKIPS CLEANLY when the
/// directory is absent so this branch stays independently green.
/// Every corpus file runs through the killable-worker invariants with
/// bounded time; the extended (tag: fuzz) suite multiplies corpus
/// files with deterministic mutations.
void main() {
  test('tracked fuzz corpus files respect the parse invariants', () async {
    final root = fuzzCorpusRoot();
    if (root == null) {
      markTestSkipped('tracked fuzz corpus not present (test/resources/fuzz)');
      return;
    }
    final files = fuzzCorpusFiles(limit: 24);
    final failures = <String>[];
    for (final file in files) {
      final verdict = await runBoundedParse(
        file.readAsBytesSync(),
        timeout: const Duration(seconds: 60),
      );
      if (verdict.isDefect) {
        failures.add('${fuzzCorpusFixtureId(file, root)}: ${verdict.defectSummary}');
      }
    }
    expect(failures, isEmpty, reason: 'corpus invariants violated: $failures');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
