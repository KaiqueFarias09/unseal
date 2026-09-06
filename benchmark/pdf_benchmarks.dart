// Benchmarks for the PDF pipeline: structure-only metadata reads,
// the full parse (structure + extraction + reflow) and search over
// the reflowed text space.

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';

import 'benchmark_harness.dart';

const String _realFixture = 'test/resources/pdf/dickens-sample.pdf';

/// Runs the PDF benchmarks: the in-repo real-writer fixture plus
/// every PDF under `ELIVRE_BENCH_PDF_DIR` when configured.
Future<void> runPdfBenchmarks() async {
  final group = BenchmarkGroup('PDF');

  final realFile = File(_realFixture);
  if (realFile.existsSync()) {
    final bytes = realFile.readAsBytesSync();
    group.add(
      'parsePdfBook — real writer fixture',
      () => parsePdfBook(bytes),
      inputBytes: bytes.length,
      note: 'structure + extraction + reflow',
    );
    group.add(
      'readPdfMetadata — real writer fixture',
      () => readPdfMetadata(bytes),
      inputBytes: bytes.length,
      note: 'structure only',
    );
    _addSearchBenchmark(group, 'search — real writer fixture', bytes);
  }

  final corpusRoot = Platform.environment['ELIVRE_BENCH_PDF_DIR'];
  if (corpusRoot == null) return;
  final corpus = Directory(corpusRoot);
  if (!corpus.existsSync()) {
    stdout.writeln('[PDF corpus] skipped — $corpusRoot does not exist.');
    return;
  }

  final files =
      corpus
          .listSync()
          .whereType<File>()
          .where((final file) => file.path.toLowerCase().endsWith('.pdf'))
          .toList()
        ..sort((final a, final b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    stdout.writeln('[PDF corpus] skipped — no PDF files under $corpusRoot.');
    return;
  }

  for (final file in files.take(50)) {
    final Uint8List bytes;
    try {
      bytes = file.readAsBytesSync();
    } on Exception {
      continue;
    }
    final label = file.path.split('/').last;
    group.add(
      'parsePdfBook — $label',
      () => parsePdfBook(bytes),
      inputBytes: bytes.length,
      note: 'structure + extraction + reflow',
    );
    _addSearchBenchmark(group, 'search — $label', bytes);
  }
}

void _addSearchBenchmark(final BenchmarkGroup group, final String label, final Uint8List bytes) {
  group.add(
    label,
    () => parsePdfBook(bytes).search('the', maxMatches: 100),
    inputBytes: bytes.length,
    note: 'parse + search over the reflowed space',
  );
}
