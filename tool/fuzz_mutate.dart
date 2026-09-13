// Deterministic truncation/mutation CLI over seed fixtures.
//
// This is the CORPUS-side feeder for the fuzzing harnesses: it turns any
// seed fixture into labeled, reproducible fuzz cases without ever needing
// the library. Harness code can either invoke this CLI or import the API
// directly:
//
//     import '../tool/fuzz/mutation.dart';
//
//     final cases = [
//       ...truncationCases(seed),
//       ...mutationCases(seed, seedValue: 7, count: 32),
//     ];
//
// Usage:
//
//     dart run tool/fuzz_mutate.dart --input=<file> --out-dir=<dir> \
//       [--seed=1] [--count=32] [--truncations-only|--mutations-only] \
//       [--json=<report>] [--list]
//
// Every case is written to `<out-dir>/<kind>-<id>.bin` next to a JSON
// report. Case ids contain operation names and offsets only — never
// input contents — so reports are safe to keep anywhere.
import 'dart:convert';
import 'dart:io';

import 'fuzz/mutation.dart';

Future<void> main(final List<String> arguments) async {
  final options = _parseOptions(arguments);
  if (options.input == null) {
    stderr.writeln(
      'usage: dart run tool/fuzz_mutate.dart --input=<file> --out-dir=<dir> '
      '[--seed=1] [--count=32] [--truncations-only|--mutations-only] '
      '[--json=<report>] [--list]',
    );
    exitCode = 64;
    return;
  }
  final seed = await File(options.input!).readAsBytes();
  final cases = <FuzzCase>[
    if (!options.mutationsOnly) ...truncationCases(seed),
    if (!options.truncationsOnly)
      ...mutationCases(seed, seedValue: options.seed, count: options.count),
  ];

  if (options.list) {
    for (final testCase in cases) {
      stdout.writeln(
        '${testCase.kind}\t${testCase.id}\t${testCase.bytes.length}\t${testCase.description}',
      );
    }
    return;
  }

  final outDir = options.outDir ?? 'artifacts/goal3/corpus/fuzz-cases';
  Directory(outDir).createSync(recursive: true);
  for (final testCase in cases) {
    File(
      '$outDir/${testCase.kind}-${_safeName(testCase.id)}.bin',
    ).writeAsBytesSync(testCase.bytes, flush: true);
  }

  final report = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'fuzz-mutation-plan',
    'seed': options.seed,
    'truncationCases': cases.where((final c) => c.kind == 'truncation').length,
    'mutationCases': cases.where((final c) => c.kind == 'mutation').length,
    'seedBytes': seed.length,
    'cases': [
      for (final testCase in cases)
        {
          'id': testCase.id,
          'kind': testCase.kind,
          'bytes': testCase.bytes.length,
          'description': testCase.description,
        },
    ],
  };
  final jsonPath = options.json ?? '$outDir/plan.json';
  File(
    jsonPath,
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n', flush: true);
  stdout.writeln(
    'fuzz_mutate: ${cases.length} cases '
    '(${report['truncationCases']} truncations, ${report['mutationCases']} mutations) '
    'written under $outDir',
  );
}

String _safeName(final String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_@.+-]'), '_');

final class _Options {
  String? input;
  String? outDir;
  String? json;
  int seed = 1;
  int count = 32;
  bool truncationsOnly = false;
  bool mutationsOnly = false;
  bool list = false;
}

_Options _parseOptions(final Iterable<String> arguments) {
  final options = _Options();
  for (final argument in arguments) {
    final value = argument.contains('=') ? argument.split('=').skip(1).join('=') : null;
    if (argument.startsWith('--input=') && value != null) {
      options.input = value;
    } else if (argument.startsWith('--out-dir=') && value != null) {
      options.outDir = value;
    } else if (argument.startsWith('--json=') && value != null) {
      options.json = value;
    } else if (argument.startsWith('--seed=') && value != null) {
      options.seed = int.tryParse(value) ?? 1;
    } else if (argument.startsWith('--count=') && value != null) {
      options.count = int.tryParse(value) ?? 32;
    } else if (argument == '--truncations-only') {
      options.truncationsOnly = true;
    } else if (argument == '--mutations-only') {
      options.mutationsOnly = true;
    } else if (argument == '--list') {
      options.list = true;
    }
  }
  return options;
}
