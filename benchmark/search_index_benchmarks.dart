// Benchmarks for the per-publication search index ([BookSearchIndex]).
//
// The group separates the costs the search-index campaign cares about:
// cold construction over memoized canonical texts (the parse and the
// document-text scan are measured by the documentText group), hot
// queries on a warm index (exact rare/common/none, prefix, fuzzy), the
// serialized payload size, and the import cost of revalidating that
// payload. Every row's note carries the index shape (sections, terms,
// occurrences) so sizes compare across books.

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'package:unseal/unseal.dart';

import 'benchmark_harness.dart';
import 'fixtures.dart';
import 'library_fixtures.dart';

/// The real-corpus book driving the large-scale rows.
const String _shakespeareFileName =
    'Complete Works of William Shakespeare (Ill - SHAKESPEARE, WILLIAM.epub';

/// Runs the search-index benchmark group.
Future<void> runSearchIndexBenchmarks() async {
  final group = BenchmarkGroup('BookSearchIndex');

  // Small book: Alice. Construction reuses a pre-parsed book whose
  // document texts are memoized, so the row measures tokenization,
  // postings, digests and tree work — the index's own cost.
  final alice = Unseal.parse(epubAlice.bytes);
  final aliceWarm = await BookSearchIndex.build(alice);

  await group.addAsync(
    'build — alice.epub (${alice.files.html.length} sections)',
    () async => (await BookSearchIndex.build(alice)).coverage.totalOccurrences,
    inputBytes: _textLength(alice),
    note:
        '${aliceWarm.coverage.termCount} terms · '
        '${aliceWarm.coverage.totalOccurrences} occurrences · '
        'fresh index per sample, document texts memoized',
  );

  _addQueryRows(group, 'alice', aliceWarm);
  _addSizeRows(group, 'alice', aliceWarm);

  final shakespeare = _shakespeareEpub();
  if (shakespeare == null) {
    skipLibraryGroup('BookSearchIndex — real corpus');

    return;
  }
  final shakespeareWarm = await BookSearchIndex.build(shakespeare);
  await group.addAsync(
    'build — shakespeare (${shakespeare.files.html.length} sections)',
    () async => (await BookSearchIndex.build(shakespeare)).coverage.totalOccurrences,
    inputBytes: _textLength(shakespeare),
    note:
        '${shakespeareWarm.coverage.termCount} terms · '
        '${shakespeareWarm.coverage.totalOccurrences} occurrences',
  );
  _addQueryRows(group, 'shakespeare', shakespeareWarm);
  _addSizeRows(group, 'shakespeare', shakespeareWarm);
}

/// Hot-query rows: exact rare/common/none, unaccented-over-accented,
/// prefix and fuzzy, all on the pre-built warm [index].
void _addQueryRows(final BenchmarkGroup group, final String label, final BookSearchIndex index) {
  final rows = <(String, String, IndexedQueryMode)>[
    ('exact common', label == 'alice' ? 'the' : 'love', IndexedQueryMode.exact),
    ('exact rare', label == 'alice' ? 'rabbit' : 'zephyr', IndexedQueryMode.exact),
    ('exact none', 'qxzjq', IndexedQueryMode.exact),
    ('unaccented', label == 'alice' ? 'injavement' : 'azione', IndexedQueryMode.exact),
    ('prefix', label == 'alice' ? 'rab' : 'lov', IndexedQueryMode.prefix),
    ('fuzzy', label == 'alice' ? 'rabit' : 'lovce', IndexedQueryMode.fuzzy),
  ];
  for (final (kind, query, mode) in rows) {
    final probe = index.query(query, mode: mode);
    group.add(
      '$label — $kind "$query" (${mode.name})',
      () => index.query(query, mode: mode).hits.length,
      processedBytes: 0,
      note:
          '${probe.hits.length} hits'
          '${probe.isTruncated ? ' (capped)' : ''} · warm index',
    );
  }
}

/// Payload size and revalidation rows: [BookSearchIndex.serialize]
/// length (the persisted footprint) and [BookSearchIndex.deserialize]
/// over the same payload (the import cost: digest re-verification
/// needs the texts, so the row runs without a book and reports the
/// structural cost; digest verification adds one sha256 per section).
void _addSizeRows(final BenchmarkGroup group, final String label, final BookSearchIndex index) {
  final payload = index.serialize();
  final payloadLength = payload.toString().length;
  group.add(
    '$label — serialize',
    () => index.serialize().toString().length,
    processedBytes: 0,
    note:
        'payload ≈ ${formatBytes(payloadLength)} over '
        '${index.coverage.indexedSections} sections',
  );
  group.add(
    '$label — deserialize (structural)',
    () => BookSearchIndex.deserialize(payload).coverage.termCount,
    processedBytes: 0,
    note:
        'rebuilds the trie from the payload; text digests not '
        're-verified in this row',
  );
}

int _textLength(final Book book) {
  return book.files.html.fold<int>(0, (final total, final file) => total + file.content.length);
}

EpubBook? _shakespeareEpub() {
  if (_shakespeareResolved) return _shakespeareBook;

  _shakespeareResolved = true;
  final book = libraryRoot == null ? null : findLibraryBook(_shakespeareFileName);
  if (book != null) {
    try {
      _shakespeareBook = Unseal.parse(book.read()) as EpubBook;
    } on Object {
      _shakespeareBook = null;
    }
  }

  return _shakespeareBook;
}

EpubBook? _shakespeareBook;
bool _shakespeareResolved = false;
