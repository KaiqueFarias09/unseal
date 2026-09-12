// Entry point for the eLivre public API benchmarks.
//
// Usage:
//     dart run benchmark/e_livre_benchmarks.dart
//     dart run benchmark/e_livre_benchmarks.dart --filter=parseBook
//     dart run benchmark/e_livre_benchmarks.dart --quick
//     dart run benchmark/e_livre_benchmarks.dart --json=report.json
//     dart run benchmark/e_livre_benchmarks.dart --json
//
// The filter is a case-insensitive substring matched against
// '<group> — <benchmark name>', so `--filter=metadata`, `--filter=alice`
// and `--filter='Full parse'` all select different slices.
//
// JSON output modes: `--json=<path>` keeps the human table on stdout
// and writes the schemaVersion-1 report to <path>; plain `--json`
// prints only the report on stdout (machine mode). One measurement
// code path feeds both modes; see json_report.dart for the contract.

import 'dart:io';

import 'benchmark_harness.dart';
import 'book_wire_benchmarks.dart';
import 'calibre_scale_benchmarks.dart';
import 'cfi_benchmarks.dart';
import 'detection_benchmarks.dart';
import 'document_text_search_benchmarks.dart';
import 'getters_benchmarks.dart';
import 'json_report.dart';
import 'library_corpus_benchmarks.dart';
import 'metadata_benchmarks.dart';
import 'mobi_compression_benchmarks.dart';
import 'parsing_benchmarks.dart';
import 'pdf_benchmarks.dart';
import 'utils_benchmarks.dart';

/// Runs every benchmark group (or the filtered subset).
Future<void> main(final List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    stdout.writeln(
      'dart run benchmark/e_livre_benchmarks.dart '
      '[--filter=<text>] [--quick] [--json[=<path>]]',
    );

    return;
  }
  if (!_parseArguments(arguments)) {
    exitCode = 64; // Usage error.
    return;
  }
  quickModeEnabled = quickMode;
  printBanner();
  final total = Stopwatch()..start();
  try {
    runDetectionBenchmarks();
    await runParsingBenchmarks();
    await runMetadataBenchmarks();
    runMobiCompressionBenchmarks();
    runGetterBenchmarks();
    runBookWireBenchmarks();
    runDocumentTextSearchBenchmarks();
    runUtilityBenchmarks();
    runCfiBenchmarks();
    await runPdfBenchmarks();
    runCalibreScaleBenchmarks();

    // The real-corpus scan runs last: it is the slowest group and only
    // active when ELIVRE_BENCH_LIBRARY points at a library.
    await runLibraryCorpusBenchmarks();
  } on Object catch (error) {
    runError = '${error.runtimeType}';
    rethrow;
  } finally {
    printFooter(total.elapsed);
    writeJsonReport();
  }
}

bool _parseArguments(final List<String> arguments) {
  for (final argument in arguments) {
    if (argument == '--quick' || argument == '-q') {
      quickMode = true;
    } else if (parseJsonArgument(argument)) {
      // Configured by the JSON contract module.
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
