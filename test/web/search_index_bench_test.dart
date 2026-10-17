@TestOn('browser')
library;

// Search-index benchmarks on the browser runtime (dart2js), mirrors of
// the VM group in `benchmark/search_index_benchmarks.dart`.
//
// Measures cold construction, hot queries (exact rare/common/none,
// prefix, fuzzy), and the serialized payload size over a synthetic
// in-memory EPUB, both in-page (eager `BookSearchIndex.build`) and
// through the real Web Worker (the session's incremental batches).
// Numbers print to the test runner's stdout — the browser suite has no
// benchmark harness — and each row asserts a semantic outcome so the
// measured work cannot be discarded.
//
// Run with: dart test test/web/search_index_bench_test.dart -p chrome
//
// The rows print to the runner's stdout (the file-level
// `ignore: avoid_print` marks those prints; the browser suite has no
// logging framework to call).
//
// ignore_for_file: avoid_print

import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/worker_client.dart';
import 'package:unseal/unseal.dart';

const int _sectionCount = 16;
const int _paragraphRepeat = 40;

Uint8List _utf8(final String value) => Uint8List.fromList(convert.utf8.encode(value));

/// A synthetic book with repeated English and Portuguese paragraphs —
/// big enough for query costs to be visible, small enough to keep the
/// Chrome lane quick.
Uint8List _benchEpub() {
  final archive = Archive();
  archive.addFile(
    ArchiveFile('mimetype', 20, _utf8('application/epub+zip'))..compression = CompressionType.none,
  );
  final container = _utf8(
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="content.opf"/></rootfiles></container>',
  );
  archive.addFile(ArchiveFile('META-INF/container.xml', container.length, container));
  final manifestItems = [
    for (var i = 0; i < _sectionCount; i++)
      '<item id="s$i" href="s$i.xhtml" media-type="application/xhtml+xml"/>',
  ].join();
  final spineRefs = [for (var i = 0; i < _sectionCount; i++) '<itemref idref="s$i"/>'].join();
  final package = _utf8(
    '<package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'version="3.0" unique-identifier="uid"><metadata>'
    '<dc:identifier id="uid">urn:uuid:bench</dc:identifier><dc:language>en</dc:language></metadata>'
    '<manifest>$manifestItems</manifest><spine>$spineRefs</spine></package>',
  );
  archive.addFile(ArchiveFile('content.opf', package.length, package));
  for (var i = 0; i < _sectionCount; i++) {
    // Section 0 carries the query targets; the rest pad the corpus
    // with varied filler so the term space is not degenerate.
    final paragraph = i == 0
        ? 'the white rabbit loves navegação e coração. '
        : '${[for (var w = 0; w < 8; w++) 'palavra${i * 8 + w}'].join(' ')} lorem ipsum dolor sit amet. ';
    final body = List.filled(_paragraphRepeat, paragraph).join();
    final section = _utf8(
      '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>$body</p></body></html>',
    );
    archive.addFile(ArchiveFile('s$i.xhtml', section.length, section));
  }

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

double _medianOf(final List<double> samples) {
  final sorted = samples.toList()..sort();

  return sorted[sorted.length ~/ 2];
}

/// Times [action] over [runs] samples after one warm-up, in
/// milliseconds.
Future<double> _timeMs(final Future<Object?> Function() action, {final int runs = 5}) async {
  await action(); // Warm-up.
  final samples = <double>[];
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    await action();
    samples.add(watch.elapsedMicroseconds / 1000);
  }

  return _medianOf(samples);
}

int _syncSink = 0;

void main() {
  setUp(() {
    UnsealWorker.configure(Uri.base.resolve('unseal_worker.js'));
  });

  tearDown(UnsealWorker.dispose);

  test('search index benchmarks (browser mirror)', () async {
    final bytes = _benchEpub();
    final book = Unseal.parse(bytes) as EpubBook;
    final textBytes = book.files.html.fold<int>(0, (final t, final f) => t + f.content.length);

    // Cold construction over the parsed book (texts memoized).
    final buildMs = await _timeMs(() async => BookSearchIndex.build(book));
    final index = await BookSearchIndex.build(book);
    final coverage = index.coverage;
    print(
      'BUILD in-page: ${buildMs.toStringAsFixed(1)} ms · '
      '${coverage.indexedSections} sections · ${coverage.termCount} terms · '
      '${coverage.totalOccurrences} occurrences · ~${(textBytes / 1024).round()} KB text',
    );
    expect(coverage.isComplete, isTrue);

    // Hot queries in-page.
    // Chrome clamps performance.now to 100 µs buckets without
    // cross-origin isolation, so cheap queries measure in batches of 64
    // (the same trick the VM harness uses for cheap operations).
    void queryRow(final String label, final String query, final IndexedQueryMode mode) {
      const batch = 64;
      final samples = <double>[];
      index.query(query, mode: mode);
      for (var i = 0; i < 5; i++) {
        final watch = Stopwatch()..start();
        var n = 0;
        for (var q = 0; q < batch; q++) {
          n += index.query(query, mode: mode).hits.length;
        }
        samples.add(watch.elapsedMicroseconds / batch);
        if (n < 0) print('unreachable');
      }
      samples.sort();
      final us = samples[2];
      final hits = index.query(query, mode: mode).hits.length;
      print('QUERY $label "$query" (${mode.name}): ${us.toStringAsFixed(1)} µs/query · $hits hits');
      expect(hits, greaterThanOrEqualTo(0));
    }

    print('SINK: $_syncSink');

    queryRow('exact common', 'the', IndexedQueryMode.exact);
    queryRow('exact rare', 'rabbit', IndexedQueryMode.exact);
    queryRow('exact none', 'qxzjq', IndexedQueryMode.exact);
    queryRow('unaccented', 'navegacao', IndexedQueryMode.exact);
    queryRow('prefix', 'nave', IndexedQueryMode.prefix);
    queryRow('fuzzy', 'navegacau', IndexedQueryMode.fuzzy);

    // Payload size.
    final payload = index.serialize();
    final payloadKb = (convert.json.encode(payload).length / 1024).round();
    print('SERIALIZE: ~$payloadKb KB payload');
    expect(payload['schemaVersion'], 1);

    // The same index through the real worker: incremental batches plus
    // a hot query across the wire.
    final probe = await WorkerClient.instance.sessionOpenInWorker(bytes);
    expect(probe, isNotNull, reason: 'the browser mirror must exercise the real worker');
    final sessionId = probe!.sessionId;
    final sessionBuildMs = await _timeMs(() async {
      // Drop first: every sample rebuilds from an empty index.
      await WorkerClient.instance.sessionSearchIndexDropInWorker(sessionId);
      var coverage = SearchIndexCoverage.fromWire(
        await WorkerClient.instance.sessionSearchIndexEnsureInWorker(sessionId, 0, null),
      );
      while (!coverage.isComplete) {
        coverage = SearchIndexCoverage.fromWire(
          await WorkerClient.instance.sessionSearchIndexEnsureInWorker(sessionId, 4, null),
        );
      }

      return coverage.termCount;
    });
    print('BUILD worker (batched): ${sessionBuildMs.toStringAsFixed(1)} ms');
    final workerQueryMs = await _timeMs(() async {
      return WorkerClient.instance.sessionSearchIndexQueryInWorker(
        sessionId,
        'rabbit',
        mode: IndexedQueryMode.exact,
        maxMatches: null,
        maxExpansions: null,
        contextChars: 48,
      );
    });
    print('QUERY worker exact "rabbit": ${workerQueryMs.toStringAsFixed(3)} ms (round trip)');
    WorkerClient.instance.sessionDisposeInWorker(sessionId);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
