// Deterministic structural-mutation campaign over BOOK fixtures.
//
// Composes the two pieces the tracked suites already use — the
// deterministic mutators (`test/fuzz/harness/fuzz_mutators.dart`) and
// the killable-isolate invariants engine
// (`test/fuzz/harness/fuzz_invariants.dart`) — and applies them to real
// book-shaped fixtures, which `tool/fuzz_runner.dart --corpus` never
// touches (it is hardwired to `test/resources/fuzz`). Seed selection is
// deterministic, not coverage-guided: every fixture produces the same
// mutants for the same seed.
//
// For every fixture the campaign runs the pristine bytes once and N
// deterministic mutants. Each run classifies as one of:
//
// * ok            — parsed; when the pristine parse also succeeded, a
//                   document-text ratio below [contentLossRatio] marks
//                   the mutant as `content-loss` (parses but loses text);
// * typed         — a graceful UnsealException rejection;
// * defect        — untyped error, crash or timeout. Defects are
//                   minimized (chunk-halving under a stable failure
//                   signature) and the reduced bytes are written to the
//                   repro directory, never into the repository.
//
// Usage:
//     dart run tool/fuzz_book_campaign.dart \
//       --input=test/resources/books/format_expansion/garden.pdb \
//       --input=test/resources/books/lrf/original.lrf \
//       [--seed=20260926] [--rounds=24] [--timeout-seconds=30] \
//       [--out=artifacts/fuzz/book-campaign.json]
//
// Deterministic: the same seed and fixture set always produce the same
// mutants and the same report.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:unseal/unseal.dart';

import '../test/fuzz/harness/fuzz_invariants.dart';
import '../test/fuzz/harness/fuzz_mutators.dart';
import 'fuzz/parse_probe.dart';

Future<void> main(final List<String> arguments) async {
  final inputs = <String>[];
  var seed = 20260926;
  var rounds = 24;
  var timeoutSeconds = 30;
  String? out;
  var reproDir = 'artifacts/fuzz/repro';
  for (final argument in arguments) {
    final value = argument.contains('=') ? argument.split('=').skip(1).join('=') : null;
    if (argument.startsWith('--input=') && value != null) {
      inputs.add(value);
    } else if (argument.startsWith('--seed=') && value != null) {
      seed = int.parse(value);
    } else if (argument.startsWith('--rounds=') && value != null) {
      rounds = int.parse(value);
    } else if (argument.startsWith('--timeout-seconds=') && value != null) {
      timeoutSeconds = int.parse(value);
    } else if (argument.startsWith('--out=') && value != null) {
      out = value;
    } else if (argument.startsWith('--repro-dir=') && value != null) {
      reproDir = value;
    } else {
      stderr.writeln('unknown argument: $argument');
      exitCode = 64;
      return;
    }
  }
  if (inputs.isEmpty) {
    stderr.writeln(
      'usage: --input=<fixture path> (repeatable) [--seed=N] [--rounds=N] '
      '[--timeout-seconds=S] [--out=path] [--repro-dir=path]',
    );
    exitCode = 64;
    return;
  }
  final timeout = Duration(seconds: timeoutSeconds);
  final records = <Map<String, Object?>>[];
  final pristineRecords = <Map<String, Object?>>[];
  var pristineChecks = 0;
  var defects = 0;
  var contentLoss = 0;

  for (var fixtureIndex = 0; fixtureIndex < inputs.length; fixtureIndex++) {
    final path = inputs[fixtureIndex];
    // Stable for a fixed ordered invocation, and independent of source names
    // or paths so private corpus metadata never enters the report.
    final fixtureId = 'fixture-${(fixtureIndex + 1).toString().padLeft(3, '0')}';
    final pristine = File(path).readAsBytesSync();
    final pristineVerdict = await runBoundedParse(pristine, timeout: timeout);
    pristineChecks++;
    stdout.writeln(
      '$fixtureId pristine: ${pristineVerdict.status.name} '
      '(${pristine.length} B)',
    );
    final pristineTextLength = pristineVerdict.status == FuzzStatus.ok
        ? _documentTextLength(pristine)
        : null;
    final pristineParses = pristineTextLength != null;
    pristineRecords.add(<String, Object?>{
      'fixtureId': fixtureId,
      'status': pristineVerdict.status.name,
    });

    for (var round = 0; round < rounds; round++) {
      final random = Random(seed + fixtureIndex * 1000003 + round);
      final mutant = mutateBytes(pristine, random, rounds: 2);
      final verdict = await runBoundedParse(mutant, timeout: timeout);
      String? classification;
      if (verdict.isDefect) {
        classification = 'defect';
        defects++;
        final failure = _expectedFailure(verdict);
        final minimized = failure == null
            ? null
            : await minimizeFailure(
                bytes: mutant,
                signature: failure.signature,
                probe: (final chunk) =>
                    failureSignature(chunk, entryPoint: failure.entryPoint, timeout: timeout),
              );
        Directory(reproDir).createSync(recursive: true);
        final reproName = '$fixtureId.m$round.min.bin';
        final reproPath = '$reproDir/$reproName';
        File(reproPath).writeAsBytesSync(minimized ?? mutant);
        stdout.writeln(
          '  DEFECT round $round: ${verdict.defectSummary} — repro $reproPath '
          '(${(minimized ?? mutant).length} B, was ${mutant.length} B'
          '${minimized == null ? ' · not minimized' : ''})',
        );
      } else if (pristineParses && verdict.status == FuzzStatus.ok) {
        final mutantTextLength = _documentTextLength(mutant);
        if (mutantTextLength != null &&
            pristineTextLength > 0 &&
            mutantTextLength < pristineTextLength * 0.5) {
          classification = 'content-loss';
          contentLoss++;
        }
      }
      records.add(<String, Object?>{
        'fixtureId': fixtureId,
        'round': round,
        'bytes': mutant.length,
        'status': verdict.status.name,
        'defectSummary': verdict.defectSummary,
        'classification': classification,
      });
    }
  }

  final byStatus = <String, int>{};
  for (final record in records) {
    final status = record['status']! as String;
    byStatus[status] = (byStatus[status] ?? 0) + 1;
  }
  final report = <String, Object?>{
    'tool': 'fuzz_book_campaign',
    'seed': seed,
    'rounds': rounds,
    'fixtures': inputs.length,
    'mutantRuns': records.length,
    'pristineChecks': pristineChecks,
    'totalsByStatus': byStatus,
    'defects': defects,
    'contentLoss': contentLoss,
    'pristine': pristineRecords,
    'runs_detail': records,
  };
  if (out != null) {
    File(out).parent.createSync(recursive: true);
    File(out).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('report: $out');
  }
  stdout.writeln(
    'campaign done: ${records.length} mutants · $pristineChecks pristine '
    'checks · defects=$defects · content-loss=$contentLoss · byStatus=$byStatus',
  );
  if (defects > 0) exitCode = 1;
}

/// The failure signature a defect verdict must reproduce when minimized:
/// `throw:<Type>` for untyped errors, `crash` for isolate death, and
/// `timeout` for deadline kills. `null` for statuses that are not
/// defects. The first failing entry point determines the signature.
({FuzzEntryPoint entryPoint, String signature})? _expectedFailure(final FuzzVerdict verdict) {
  for (final entry in FuzzEntryPoint.values) {
    final entryVerdict = verdict.entries[entry];
    if (entryVerdict == null) continue;
    switch (entryVerdict.status) {
      case FuzzStatus.untyped:
        final errorType = entryVerdict.errorType;
        if (errorType == null) return null;
        return (entryPoint: entry, signature: 'throw:$errorType');
      case FuzzStatus.crash:
        return (entryPoint: entry, signature: 'crash');
      case FuzzStatus.timeout:
        return (entryPoint: entry, signature: 'timeout');
      case FuzzStatus.ok:
      case FuzzStatus.typed:
      case FuzzStatus.skipped:
        continue;
    }
  }
  return null;
}

/// Total document text across the book's HTML files, or `null` when the
/// bytes do not parse into a book. Runs on the main isolate — only call
/// it for inputs the bounded verdict already proved safe.
int? _documentTextLength(final Uint8List bytes) {
  try {
    final book = Unseal.parse(bytes);
    var total = 0;
    for (final file in book.files.html) {
      total += documentTextOf(file).length;
    }
    return total;
  } on Object {
    return null;
  }
}

/// Chunk-halving shrink loop: keep removing a quarter of [bytes] while
/// [signature] still reproduces through [probe]. Returns `null` when
/// nothing shrank, or when the original input does not reproduce
/// [signature] to begin with.
Future<Uint8List?> minimizeFailure({
  required final Uint8List bytes,
  required final String signature,
  required final Future<String> Function(Uint8List) probe,
  final int maxSteps = 40,
  final int minBytes = 64,
}) async {
  if (await probe(bytes) != signature) return null;

  var current = Uint8List.fromList(bytes);
  var shrunk = false;
  for (var step = 0; step < maxSteps && current.length > minBytes; step++) {
    final chunk = current.length ~/ 4;
    var improved = false;
    for (var start = 0; start + 1 < current.length; start += chunk) {
      final end = (start + chunk).clamp(1, current.length);
      final candidate = Uint8List.fromList(<int>[
        ...current.sublist(0, start),
        ...current.sublist(end),
      ]);
      if (await probe(candidate) == signature) {
        current = candidate;
        improved = true;
        shrunk = true;
        break;
      }
    }
    if (!improved) break;
  }
  return shrunk ? current : null;
}

/// Failure signature of [bytes] through [entryPoint] (default
/// [Unseal.parse]), or through [parse] when a custom parser is supplied.
/// The result is classified the way [probeParse] sees it:
/// `throw:<Type>` when the parser throws a foreign error, `crash` when
/// the worker isolate dies, `timeout` when the deadline kills it, and
/// `ok`/`reject:<Type>` for clean outcomes.
///
/// The thrown error MUST reach [probeParse] uncaught — catching it here
/// would erase the type and every failure would classify as `ok`.
Future<String> failureSignature(
  final Uint8List bytes, {
  final FuzzEntryPoint entryPoint = FuzzEntryPoint.parse,
  final FutureOr<void> Function(Uint8List)? parse,
  final Duration timeout = const Duration(seconds: 30),
}) async {
  final parser = parse ?? _parserFor(entryPoint);
  Future<void> parseInWorker(final Uint8List input) async {
    await parser(input);
  }

  final probe = await probeParse(bytes, parseInWorker, timeout: timeout);
  return probe.signature;
}

Future<void> Function(Uint8List) _parserFor(final FuzzEntryPoint entryPoint) =>
    switch (entryPoint) {
      FuzzEntryPoint.detect => _detectFormat,
      FuzzEntryPoint.parse => _parse,
      FuzzEntryPoint.metadata => _readMetadata,
      FuzzEntryPoint.open => _read,
    };

Future<void> _detectFormat(final Uint8List bytes) async {
  detectFormat(bytes);
}

Future<void> _parse(final Uint8List bytes) async {
  Unseal.parse(bytes);
}

Future<void> _readMetadata(final Uint8List bytes) async {
  Unseal.readMetadataSync(bytes);
}

Future<void> _read(final Uint8List bytes) async {
  await Unseal.read(bytes);
}
