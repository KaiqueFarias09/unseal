import 'package:test/test.dart';

import 'harness/fuzz_corpus.dart';
import 'harness/fuzz_invariants.dart';

/// Corpus-driven invariants (quick mode).
///
/// Consumes the tracked fuzz corpus at `test/resources/fuzz/`.
/// Every corpus file runs through the killable-worker invariants with
/// bounded time; the extended (tag: fuzz) suite multiplies corpus
/// files with deterministic mutations.
void main() {
  test(
    'tracked fuzz corpus files respect the parse invariants',
    () async {
      final root = fuzzCorpusRoot();
      expect(root, isNotNull, reason: 'tracked fuzz corpus is missing');
      final files = fuzzCorpusFiles(limit: 24);
      expect(files, isNotEmpty, reason: 'tracked fuzz corpus is empty');
      final failures = <String>[];
      for (final file in files) {
        final verdict = await runBoundedParse(
          file.readAsBytesSync(),
          timeout: const Duration(seconds: 60),
        );
        if (verdict.isDefect) {
          failures.add('${fuzzCorpusFixtureId(file, root!)}: ${verdict.defectSummary}');
        }
      }
      expect(failures, isEmpty, reason: 'corpus invariants violated: $failures');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
