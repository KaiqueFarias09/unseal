// Entry point for the eLivre public API benchmarks.
//
// Usage:
//     dart run benchmark/e_livre_benchmarks.dart
//     dart run benchmark/e_livre_benchmarks.dart --filter=parseBook
//     dart run benchmark/e_livre_benchmarks.dart --quick
//
// The filter is a case-insensitive substring matched against
// '<group> — <benchmark name>', so `--filter=metadata`, `--filter=alice`
// and `--filter='Full parse'` all select different slices.

import 'dart:io';

import 'benchmark_harness.dart';
import 'book_wire_benchmarks.dart';
import 'calibre_scale_benchmarks.dart';
import 'cfi_benchmarks.dart';
import 'detection_benchmarks.dart';
import 'document_text_search_benchmarks.dart';
import 'getters_benchmarks.dart';
import 'library_corpus_benchmarks.dart';
import 'metadata_benchmarks.dart';
import 'parsing_benchmarks.dart';
import 'utils_benchmarks.dart';

/// Runs every benchmark group (or the filtered subset).
Future<void> main(final List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.writeln(
      'dart run benchmark/e_livre_benchmarks.dart '
      '[--filter=<text>] [--quick]',
    );
    return;
  }
  if (!_parseArguments(arguments)) {
    exitCode = 64; // Usage error.
    return;
  }
  printBanner();
  final total = Stopwatch()..start();

  runDetectionBenchmarks();
  await runParsingBenchmarks();
  await runMetadataBenchmarks();
  runGetterBenchmarks();
  runBookWireBenchmarks();
  runDocumentTextSearchBenchmarks();
  runUtilityBenchmarks();
  runCfiBenchmarks();
  runCalibreScaleBenchmarks();

  // The real-corpus scan runs last: it is the slowest group and only
  // active when ELIVRE_BENCH_LIBRARY points at a library.
  await runLibraryCorpusBenchmarks();

  printFooter(total.elapsed);
}

bool _parseArguments(final List<String> arguments) {
  for (final argument in arguments) {
    if (argument == '--quick' || argument == '-q') {
      quickMode = true;
    } else if (argument.startsWith('--filter=')) {
      benchmarkFilter = argument.substring('--filter='.length);
      if (benchmarkFilter!.isEmpty) {
        benchmarkFilter = null;
      }
    } else if (!argument.startsWith('-')) {
      benchmarkFilter = argument;
    } else {
      stderr.writeln('Unknown option: $argument');
      return false;
    }
  }
  return true;
}
