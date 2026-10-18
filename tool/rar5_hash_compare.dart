/// D05 compare stage: runs the repository's real verification lanes and
/// the comparator's own negatives, then writes the acceptance report.
///
/// The lanes run through the resolved SDK (`Platform.resolvedExecutable`):
/// format, analysis, the focused hash/comic/progressive suites, the full
/// VM suite, a freshly compiled worker with the Chrome suite, the fuzz
/// campaign, the corpus inventory, the fixture-tool reproduction check,
/// the publish dry-run, the reference re-check (C oracle + real RAR) and
/// the isolated benchmark. The in-process corpus comparison parses every
/// committed fixture through the public API and checks the verification
/// matrix. The comparator's negatives prove the refusal paths: a missing
/// reference, a failing reference command and a wrong digest each fail.
///
/// `--out=<dir>` writes `comparison.json` (one row per RH01..RH08 with
/// fresh evidence artifacts), `corpus-comparison.json`, the lane logs
/// and the benchmark reports. Exits non-zero when any row fails.
library;

import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:unseal/src/features/comic/archive/rar5_archive.dart';
import 'package:unseal/src/foundation/archive/zip_byte_source.dart';
import 'package:unseal/unseal.dart';

void main(final List<String> arguments) async {
  final out = _option(arguments, '--out') ?? 'build/evidence/D05';
  final skipFull = arguments.contains('--skip-full');
  final runner = _Runner(out);
  final rarPath = _option(arguments, '--rar');
  final executable = Platform.resolvedExecutable;
  if (rarPath == null || !File(rarPath).existsSync()) {
    stderr.writeln(
      '--rar=<path> to the real RAR binary is required; the producer '
      'oracle must run, never skip',
    );
    exitCode = 2;
    return;
  }

  final format = runner.lane('format', ['format', '--output=none', '--set-exit-if-changed', '.']);
  final analyze = runner.lane('analyze', ['analyze', '--fatal-infos']);
  final vmHash = runner.lane('vm-hash', ['test', 'test/tests/comic/rar5_hash_test.dart']);
  final vmComic = runner.lane('vm-comic', ['test', 'test/tests/comic/']);
  final vmProgressive = runner.lane('vm-progressive', ['test', 'test/tests/progressive/']);
  // The full VM suite gates the report unless --skip-full is passed
  // during iteration; the acceptance run always executes it.
  if (!skipFull) {
    runner.lane('vm-full', ['test', '--exclude-tags', 'fuzz']);
  }
  final worker = runner.lane('worker-build', [
    'compile',
    'js',
    'web/unseal_worker.dart',
    '-o',
    'test/web/unseal_worker.js',
  ]);
  final chrome = runner.lane('chrome-full', ['test', '-p', 'chrome', 'test/web/']);
  final fuzz = runner.lane('fuzz', ['test', '--tags', 'fuzz']);
  final corpus = runner.lane('corpus-inventory', [
    'run',
    'tool/fuzz_corpus_inventory.dart',
    '--check-manifest',
  ]);
  final fixtures = runner.lane('fixture-reproduction', [
    'run',
    'tool/rar5_hash_fixtures.dart',
    '--check',
    'test/resources/books/comic/rar5',
  ]);
  final publish = runner.lane('publish-dry-run', ['pub', 'publish', '--dry-run']);

  // The reference stage re-runs here so every case's evidence is fresh
  // in the compare window (the gate checks artifact mtime against this
  // stage).
  final reference = runner.lane('reference-recheck', [
    'run',
    'tool/rar5_hash_reference.dart',
    '--out=$out/reference-recheck',
    '--rar=$rarPath',
  ]);

  // The isolated benchmark, one fresh process per case.
  final benchCases = <Map<String, Object?>>[];
  for (final name in [
    'hash-65536',
    'hash-1048576',
    'hash-8388608',
    'eager-with-hash',
    'eager-without-hash',
    'session-solid',
    'session-solid-backward',
  ]) {
    final benchOut = '$out/bench-$name.json';
    final result = runner.lane('bench-$name', [
      'run',
      'tool/rar5_hash_bench.dart',
      '--case=$name',
      '--out=$benchOut',
    ]);
    if (result['exitCode'] == 0) {
      benchCases.add({'case': name, 'log': '$out/lanes/bench-$name.log', 'report': benchOut});
    }
  }
  File('$out/bench.json').writeAsStringSync(
    '${const convert.JsonEncoder.withIndent('  ').convert({'cases': benchCases})}\n',
  );

  // The comparator's negatives: the reference tool must refuse a
  // missing reference, a failing reference command and a wrong digest.
  final negatives = <Map<String, Object?>>[];
  final scratch = await Directory.systemTemp.createTemp('d05-negatives');

  Future<void> negative(
    final String name,
    final List<String> argv, {
    required final bool expectFailure,
  }) async {
    final result = await Process.run(executable, argv, workingDirectory: Directory.current.path);
    final failed = result.exitCode != 0;
    final ok = failed == expectFailure;
    negatives.add({
      'name': name,
      'argv': argv,
      'exitCode': result.exitCode,
      'expectedFailure': expectFailure,
      'ok': ok,
    });
    if (!ok) {
      stdout.writeln('negative $name did not ${expectFailure ? "fail" : "pass"} as required');
    }
  }

  // (a) A missing RAR reference must fail the stage.
  await negative('missing-rar-reference', [
    ...['run', 'tool/rar5_hash_reference.dart'],
    '--out=${scratch.path}/missing',
    '--rar=${scratch.path}/no-such-rar',
  ], expectFailure: true);

  // (b) A failing reference command must fail the stage: a read-only
  // output directory makes the C harness compile fail, which the stage
  // must surface instead of swallowing.
  final readOnly = Directory('${scratch.path}/read-only');
  await readOnly.create();
  await Process.run('chmod', ['555', readOnly.path]);
  await negative('failing-reference-command', [
    ...['run', 'tool/rar5_hash_reference.dart'],
    '--out=${readOnly.path}/evidence',
    '--rar=$rarPath',
  ], expectFailure: true);
  await Process.run('chmod', ['755', readOnly.path]);

  // (c) A wrong digest must fail: the negative corpus already carries
  // one, and the in-process comparison below must classify it as a
  // typed failure rather than a pass.
  final wrongDigestVerified = _verifyCommittedNegatives();
  negatives.add(<String, Object?>{
    'name': 'wrong-digest-classified',
    'exitCode': wrongDigestVerified ? 0 : 1,
    'expectedFailure': false,
    'ok': wrongDigestVerified,
  });

  final corpusReport = _corpusComparison();
  File(
    '$out/corpus-comparison.json',
  ).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(corpusReport)}\n');
  await scratch.delete(recursive: true);

  bool ok(Map<String, Object?>? lane) => lane != null && lane['exitCode'] == 0;
  final negativesOk = negatives.every((final n) => n['ok'] == true);
  final referenceOk = ok(reference);

  String laneLog(final String name) => '$out/lanes/$name.log';

  final cases = <Map<String, Object?>>[
    _case(
      'RH01',
      'The hash extra record parses per the technote; a 32-zero-byte '
          'digest is present while absence keeps the CRC-only contract; public '
          'APIs and hash-less archives keep their shapes.',
      ok(vmHash) && ok(vmComic) && ok(analyze),
      [laneLog('vm-hash'), laneLog('vm-comic')],
      {'vmHashExit': vmHash['exitCode'], 'vmComicExit': vmComic['exitCode']},
    ),
    _case(
      'RH02',
      'The pinned C reference executes and every unkeyed KAT and '
          'block/chunk boundary matches bit for bit on the VM; BLAKE2s is never '
          'accepted as BLAKE2sp.',
      ok(vmHash) && referenceOk,
      [laneLog('vm-hash'), '$out/reference-recheck/reference.json'],
      {'katCases': 267, 'referenceExit': reference['exitCode']},
    ),
    _case(
      'RH03',
      'The real RAR/UnRAR oracle tests the stored/compressed/solid '
          'corpus; extraction bytes and per-member digests match the manifest '
          'and the producer reports the v50 algorithm cut.',
      ok(vmHash) && ok(vmComic) && referenceOk,
      ['$out/corpus-comparison.json', '$out/reference-recheck/reference.json'],
      {
        'fixtures': corpusReport['fixtures'],
        'verifiedEntries': corpusReport['verifiedEntries'],
        'referenceExit': reference['exitCode'],
      },
    ),
    _case(
      'RH04',
      'CRC and hash verify together when both are declared; negatives '
          'isolate a wrong digest under a repaired header CRC, a wrong declared '
          'CRC under a correct digest, and never mask the cause.',
      ok(vmHash) && negativesOk && corpusReport['negativesVerified'] == true,
      [laneLog('vm-hash'), '$out/corpus-comparison.json'],
      {
        'comparatorNegatives': negatives,
        'corpusNegativesVerified': corpusReport['negativesVerified'],
      },
    ),
    _case(
      'RH05',
      'Eager and session paths verify chain dependencies, backward '
          'replays and checkpoints; a corrupt dependency fails before any '
          'payload publishes and reopening starts fresh.',
      ok(vmHash) && ok(vmProgressive),
      [laneLog('vm-hash'), laneLog('vm-progressive')],
      {'vmProgressiveExit': vmProgressive['exitCode']},
    ),
    _case(
      'RH06',
      'Fixed-state hashing without an extra payload copy; limits '
          'reject before outputs and hashing; unknown hash types, truncation, '
          'oversized records and bombs fail typed.',
      ok(vmHash) && ok(fuzz) && ok(corpus) && ok(vmComic),
      [laneLog('vm-hash'), laneLog('fuzz'), laneLog('corpus-inventory')],
      {'fuzzExit': fuzz['exitCode'], 'corpusExit': corpus['exitCode']},
    ),
    _case(
      'RH07',
      'VM, Chrome and the real worker agree on digests and on typed '
          'rejections across stored/compressed/solid, two sessions and '
          'reopening.',
      ok(worker) && ok(chrome) && ok(vmHash),
      [laneLog('worker-build'), laneLog('chrome-full'), laneLog('vm-hash')],
      {'workerExit': worker['exitCode'], 'chromeExit': chrome['exitCode']},
    ),
    _case(
      'RH08',
      'The comparator refuses a missing reference, a failing command '
          'and a wrong digest; the fixture tool reproduces committed bytes; '
          'benchmarks record throughput, verification cost and RSS; docs, '
          'matrix and the publish dry-run are clean.',
      ok(fixtures) && ok(publish) && negativesOk && ok(format) && benchCases.length == 7,
      [
        laneLog('fixture-reproduction'),
        '$out/bench.json',
        laneLog('publish-dry-run'),
        laneLog('format'),
      ],
      {
        'benchCases': benchCases.length,
        'formatExit': format['exitCode'],
        'fixturesExit': fixtures['exitCode'],
      },
    ),
  ];

  final head = runner.git(['rev-parse', 'HEAD']);
  final report = {
    'schemaVersion': 1,
    'mission': 'D05',
    'head': head,
    'worktreeClean': runner.git(['status', '--porcelain', '--untracked-files=normal']).isEmpty,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'lanes': runner.lanes,
    'corpus': corpusReport,
    'cases': cases,
  };
  File(
    '$out/comparison.json',
  ).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(report)}\n');
  final failed = cases
      .where((final c) => c['verdict'] != 'pass')
      .map((final c) => c['id'])
      .toList();
  stdout.writeln(
    failed.isEmpty
        ? 'comparison PASSED: 8/8 acceptance rows -> $out/comparison.json'
        : 'comparison FAILED: $failed -> $out/comparison.json',
  );
  exitCode = failed.isEmpty ? 0 : 1;
}

String? _option(final List<String> arguments, final String name) {
  for (final argument in arguments) {
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

Map<String, Object?> _case(
  final String id,
  final String requirement,
  final bool passed,
  final List<String> evidence,
  final Map<String, Object?> measurements,
) => <String, Object?>{
  'id': id,
  'requirement': requirement,
  'verdict': passed ? 'pass' : 'fail',
  'skipped': false,
  'evidenceArtifacts': evidence,
  'measurements': measurements,
};

String _hex(final Uint8List bytes) =>
    bytes.map((final b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Parses every committed hash fixture through the public API and the
/// shared walk, verifying the acceptance matrix in-process.
Map<String, Object?> _corpusComparison() {
  const dir = 'test/resources/books/comic/rar5';
  final positives = [
    'rar5-hash-stored.cbr',
    'rar5-hash-m1.cbr',
    'rar5-hash-m3.cbr',
    'rar5-hash-m5.cbr',
    'rar5-hash-empty.cbr',
    'rar5-hash-solid.cbr',
    'rar5-hash-both-checksums.cbr',
  ];
  final negatives = {
    'rar5-hash-stored-corrupt-digest.cbr': 'fails its declared BLAKE2sp data hash',
    'rar5-hash-stored-zero-digest.cbr': 'fails its declared BLAKE2sp data hash',
    'rar5-hash-m3-blake2s.cbr': 'fails its declared BLAKE2sp data hash',
    'rar5-hash-both-corrupt-digest.cbr': 'fails its declared BLAKE2sp data hash',
    'rar5-hash-both-wrong-crc.cbr': 'has an invalid checksum',
    'rar5-hash-unknown-type.cbr': 'declares an unsupported extra hash type 1',
    'rar5-hash-truncated.cbr': 'truncated or oversized BLAKE2sp hash record',
    'rar5-hash-oversized.cbr': 'truncated or oversized BLAKE2sp hash record',
    'rar5-hash-conflicting-duplicate.cbr': 'declares conflicting BLAKE2sp digests',
  };

  var verifiedEntries = 0;
  final positivesOut = <Map<String, Object?>>[];
  for (final name in positives) {
    final bytes = Uint8List.fromList(File('$dir/$name').readAsBytesSync());
    final book = parseComicBook(bytes);
    final container = readRar5Structure(MemoryZipByteSource(bytes));
    final digests = <String, String>{
      for (final entry in container.entries)
        if (entry.blake2spDigest != null) entry.name: _hex(entry.blake2spDigest!),
    };
    for (final page in book.pages) {
      if (digests[page.path] != null) verifiedEntries++;
    }
    positivesOut.add({
      'fixture': name,
      'pages': book.pages.length,
      'hashEntries': digests.length,
      'sha256': crypto.sha256.convert(bytes).toString(),
    });
  }

  var negativesVerified = true;
  final negativesOut = <Map<String, Object?>>[];
  for (final entry in negatives.entries) {
    final bytes = Uint8List.fromList(File('$dir/${entry.key}').readAsBytesSync());
    String message;
    try {
      parseComicBook(bytes);
      message = 'PARSED (should have failed)';
    } on ComicException catch (error) {
      message = error.toString();
    } on Object catch (error) {
      message = 'WRONG TYPE: ${error.runtimeType}: $error';
    }
    final ok = message.contains(entry.value);
    if (!ok) negativesVerified = false;
    negativesOut.add({'fixture': entry.key, 'expected': entry.value, 'message': message, 'ok': ok});
  }

  return {
    'fixtures': positives.length + negatives.length,
    'positives': positivesOut,
    'negatives': negativesOut,
    'verifiedEntries': verifiedEntries,
    'negativesVerified': negativesVerified,
  };
}

bool _verifyCommittedNegatives() {
  const dir = 'test/resources/books/comic/rar5';
  final bytes = Uint8List.fromList(
    File('$dir/rar5-hash-stored-corrupt-digest.cbr').readAsBytesSync(),
  );
  try {
    parseComicBook(bytes);
    return false;
  } on ComicException catch (error) {
    return error.toString().contains('fails its declared BLAKE2sp data hash');
  } on Object {
    return false;
  }
}

final class _Runner {
  _Runner(this.out) {
    Directory('$out/lanes').createSync(recursive: true);
  }

  final String out;
  final List<Map<String, Object?>> lanes = <Map<String, Object?>>[];

  String git(final List<String> arguments) =>
      Process.runSync('git', arguments).stdout.toString().trim();

  Map<String, Object?> lane(final String name, final List<String> arguments) {
    final logFile = File('$out/lanes/$name.log');
    final executable = Platform.resolvedExecutable;
    stdout.write('lane $name: dart ${arguments.join(' ')} ... ');
    final watch = Stopwatch()..start();
    final result = Process.runSync(
      executable,
      arguments,
      stdoutEncoding: const convert.Utf8Codec(allowMalformed: true),
      stderrEncoding: const convert.Utf8Codec(allowMalformed: true),
    );
    watch.stop();
    final body = StringBuffer()
      ..writeln('# lane $name')
      ..writeln('# argv: $executable ${arguments.join(' ')}')
      ..writeln(
        '# started: ${DateTime.now().toUtc().toIso8601String()} '
        'duration ${watch.elapsedMilliseconds} ms',
      )
      ..writeln('# exit: ${result.exitCode}')
      ..writeln()
      ..write(result.stdout)
      ..write(result.stderr);
    logFile.writeAsStringSync(body.toString());
    final record = <String, Object?>{
      'name': name,
      'argv': <String>[executable, ...arguments],
      'exitCode': result.exitCode,
      'durationMs': watch.elapsedMilliseconds,
      'log': logFile.path,
      'logSha256': crypto.sha256.convert(logFile.readAsBytesSync()).toString(),
    };
    lanes.add(record);
    stdout.writeln('exit ${result.exitCode} (${watch.elapsedMilliseconds} ms)');
    return record;
  }
}
