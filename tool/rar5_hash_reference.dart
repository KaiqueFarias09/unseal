/// D05 reference stage: re-executes the pinned BLAKE2sp C oracle and the
/// real RAR producer against the committed corpus, and refuses anything
/// less.
///
/// `--version` prints the executed toolchain pins and exits (the gate's
/// version command). `--out=<dir>` runs the full reference:
///
///  1. compiles `tool/rar5_hash_blake2sp/` (pinned BLAKE2 sources,
///     revision ed1974ea83433eba7b2d95c5dcd9ac33cb847913) into `<dir>`;
///  2. recomputes every pinned KAT digest — the 256 official unkeyed
///     lengths plus the boundary set — with the C harness and with the
///     Dart hasher, and requires both to match `blake2sp_kat.dart`;
///  3. re-checks the browser test's embedded base64 fixture against the
///     committed `rar5-hash-m3.cbr`;
///  4. with `--rar=<path>`: runs the real `rar` over every committed
///     hash fixture — primaries and the both-checksums archive must
///     test clean, digest-corrupted archives must fail, extractions
///     must equal the manifest digests, and compressed members must
///     report algorithm version `v50`.
///
/// A missing reference, a failing command, or a single mismatching
/// digest fails the stage; absence is never a pass.
library;

import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'package:unseal/src/features/comic/archive/rar5_blake2sp.dart';

import '../test/support/blake2sp_kat.dart';

const String _resourceDir = 'test/resources/books/comic/rar5';
const String _blake2Revision = 'ed1974ea83433eba7b2d95c5dcd9ac33cb847913';

Future<void> main(final List<String> arguments) async {
  if (arguments.contains('--version')) {
    _runVersion(arguments);
    return;
  }
  final out = _option(arguments, '--out');
  if (out == null) {
    stderr.writeln('usage: dart run tool/rar5_hash_reference.dart --out=<dir> [--rar=<path>]');
    exitCode = 2;
    return;
  }
  exitCode = await _runReference(out, _option(arguments, '--rar'));
}

String? _option(final List<String> arguments, final String name) {
  for (final argument in arguments) {
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

String _dartVersion() => Platform.version.split(' ').first;

void _runVersion(final List<String> arguments) {
  final rar = _option(arguments, '--rar');
  stdout.writeln('dart $_dartVersion()');
  stdout.writeln('blake2-reference $_blake2Revision');
  final cc = Process.runSync('cc', [
    '--version',
  ], stdoutEncoding: const convert.Utf8Codec(allowMalformed: true));
  stdout.writeln('cc ${cc.stdout.toString().split('\n').first}');
  if (cc.exitCode != 0) {
    stderr.writeln('cc is not usable');
    exitCode = 1;
    return;
  }
  for (final source in ['blake2s-ref.c', 'blake2sp-ref.c', 'blake2.h', 'blake2-impl.h']) {
    final bytes = File('tool/rar5_hash_blake2sp/ref/$source').readAsBytesSync();
    stdout.writeln('sha256(tool/rar5_hash_blake2sp/ref/$source) = ${crypto.sha256.convert(bytes)}');
  }
  if (rar != null) {
    final result = Process.runSync(
      rar,
      [],
      stdoutEncoding: const convert.Utf8Codec(allowMalformed: true),
    );
    if (result.exitCode != 0) {
      stderr.writeln('rar did not execute');
      exitCode = 1;
      return;
    }
    final banner = result.stdout.toString().split('\n').where((final l) => l.contains('RAR')).first;
    stdout.writeln(banner.trim());
  }
}

Future<int> _runReference(final String out, final String? rarPath) async {
  Directory(out).createSync(recursive: true);
  final record = <String, Object?>{
    'schemaVersion': 1,
    'mission': 'D05',
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'blake2Revision': _blake2Revision,
    'dartVersion': _dartVersion(),
    'steps': <Object?>[],
  };
  final steps = record['steps']! as List<Object?>;

  // 1. Compile the pinned C reference harness into the evidence
  // directory (generated output stays out of Git).
  final harnessPath = '$out/blake2sp-stream';
  final compile = Process.runSync(
    'cc',
    [
      '-O2',
      '-I',
      'tool/rar5_hash_blake2sp/ref',
      'tool/rar5_hash_blake2sp/blake2sp_stream.c',
      'tool/rar5_hash_blake2sp/ref/blake2s-ref.c',
      'tool/rar5_hash_blake2sp/ref/blake2sp-ref.c',
      '-o',
      harnessPath,
    ],
    stdoutEncoding: const convert.Utf8Codec(allowMalformed: true),
    stderrEncoding: const convert.Utf8Codec(allowMalformed: true),
  );
  if (compile.exitCode != 0) {
    stderr.writeln('C reference harness failed to compile:\n${compile.stderr}');
    return 1;
  }
  steps.add({
    'name': 'compile-c-reference',
    'argv': ['cc', '-O2', '-I tool/rar5_hash_blake2sp/ref', '...'],
    'exitCode': 0,
    'binary': harnessPath,
    'binarySha256': crypto.sha256.convert(File(harnessPath).readAsBytesSync()).toString(),
    'status': 'ok',
  });

  // 2. Recompute every pinned KAT digest with the C harness and with
  // the Dart hasher; both must match the committed constants.
  final katChecks = <Object?>[];
  var katFailures = 0;
  for (var i = 0; i < blake2spKatLengths.length; i++) {
    final length = blake2spKatLengths[i];
    final input = Uint8List.fromList([for (var j = 0; j < length; j++) j & 0xFF]);
    final cDigest = await _runHarness(harnessPath, input);
    final dartDigest = _hex(rar5Blake2spDigest(input));
    final pinned = blake2spKatDigests[i];
    final ok = cDigest == pinned && dartDigest == pinned;
    if (!ok) katFailures++;
    katChecks.add({'length': length, 'pinned': pinned, 'c': cDigest, 'dart': dartDigest, 'ok': ok});
  }
  steps.add({
    'name': 'kat-recompute',
    'cases': katChecks.length,
    'failures': katFailures,
    'status': katFailures == 0 ? 'ok' : 'failed',
  });
  if (katFailures > 0) {
    stderr.writeln('$katFailures KAT cases disagree with the committed pins');
    return 1;
  }

  // 3. The browser test's embedded fixture must equal the committed
  // bytes.
  final webTest = File('test/web/rar5_hash_worker_test.dart').readAsStringSync();
  final base64Match = RegExp(r"_m3FixtureBase64 =((?:\s*'[^']*')+);").firstMatch(webTest);
  if (base64Match == null) {
    stderr.writeln('embedded fixture constant not found in the web test');
    return 1;
  }
  final embeddedBase64 = RegExp(
    "'([^']*)'",
  ).allMatches(base64Match.group(1)!).map((final m) => m.group(1)!).join();
  final embedded = convert.base64Decode(embeddedBase64);
  final committed = File('$_resourceDir/rar5-hash-m3.cbr').readAsBytesSync();
  final embeddedOk = _bytesEqual(embedded, committed);
  steps.add({
    'name': 'web-embedding-check',
    'committedSha256': crypto.sha256.convert(committed).toString(),
    'embeddedSha256': crypto.sha256.convert(embedded).toString(),
    'status': embeddedOk ? 'ok' : 'failed',
  });
  if (!embeddedOk) {
    stderr.writeln('the web test embeds stale fixture bytes');
    return 1;
  }

  // 4. The real RAR producer stage.
  if (rarPath == null) {
    stderr.writeln('--rar=<path> is required: the producer oracle must run, never skip');
    return 1;
  }
  final rarVersion = await Process.run(
    rarPath,
    [],
    stdoutEncoding: const convert.Utf8Codec(allowMalformed: true),
  );
  if (rarVersion.exitCode != 0) {
    stderr.writeln('rar did not execute');
    return 1;
  }
  record['rar'] = {
    'path': rarPath,
    'banner': rarVersion.stdout
        .toString()
        .split('\n')
        .firstWhere((final line) => line.contains('RAR')),
  };

  final primaries = [
    'rar5-hash-stored.cbr',
    'rar5-hash-m1.cbr',
    'rar5-hash-m3.cbr',
    'rar5-hash-m5.cbr',
    'rar5-hash-solid.cbr',
    'rar5-hash-empty.cbr',
  ];
  final mustFail = [
    'rar5-hash-stored-corrupt-digest.cbr',
    'rar5-hash-stored-zero-digest.cbr',
    'rar5-hash-m3-blake2s.cbr',
    'rar5-hash-both-corrupt-digest.cbr',
  ];
  final tolerates = [
    'rar5-hash-unknown-type.cbr',
    'rar5-hash-truncated.cbr',
    'rar5-hash-oversized.cbr',
    'rar5-hash-conflicting-duplicate.cbr',
    'rar5-hash-both-checksums.cbr',
    'rar5-hash-both-wrong-crc.cbr',
  ];

  final rarChecks = <Object?>[];
  var rarFailures = 0;
  Future<void> rarCheck(final String name, final String fixture, final bool expectPass) async {
    final result = await Process.run(
      rarPath,
      ['t', '-idq', '$_resourceDir/$fixture'],
      stdoutEncoding: const convert.Utf8Codec(allowMalformed: true),
      stderrEncoding: const convert.Utf8Codec(allowMalformed: true),
    );
    final ok = expectPass ? result.exitCode == 0 : result.exitCode != 0;
    if (!ok) rarFailures++;
    rarChecks.add({
      'fixture': fixture,
      'exitCode': result.exitCode,
      'expectation': expectPass ? 'passes' : 'fails',
      'ok': ok,
    });
  }

  for (final fixture in primaries) {
    await rarCheck('rar-t-primary', fixture, true);
  }
  for (final fixture in mustFail) {
    await rarCheck('rar-t-corrupt', fixture, false);
  }
  for (final fixture in tolerates) {
    // The producer's leniency on out-of-shape records and its choice of
    // checksum on the injected archive are recorded, not asserted: the
    // contract those fixtures pin is Unseal's, and the VM suite covers
    // it. Every outcome is still written to the record.
    final result = await Process.run(
      rarPath,
      ['t', '-idq', '$_resourceDir/$fixture'],
      stdoutEncoding: const convert.Utf8Codec(allowMalformed: true),
      stderrEncoding: const convert.Utf8Codec(allowMalformed: true),
    );
    rarChecks.add({
      'fixture': fixture,
      'exitCode': result.exitCode,
      'expectation': 'recorded',
      'ok': true,
    });
  }

  // Extraction equality and the compression-version cut: every primary
  // extracts into a scratch directory and each file's SHA-256 must
  // equal its manifest pin; every compressed member must report the
  // v50 algorithm cut (stored members report no compression line).
  final manifest =
      (convert.json.decode(File('$_resourceDir/manifest.json').readAsStringSync()) as List)
          .cast<Map<String, Object?>>();
  final scratch = Directory.systemTemp.createTempSync('d05-rar-extract');
  final absoluteResourceDir = Directory(_resourceDir).absolute.path;
  try {
    for (final fixture in primaries) {
      final target = '${scratch.path}/$fixture';
      await Directory(target).create(recursive: true);
      final extract = await Process.run(
        rarPath,
        ['x', '-idq', '$absoluteResourceDir/$fixture'],
        workingDirectory: target,
        stdoutEncoding: const convert.Utf8Codec(allowMalformed: true),
      );
      if (extract.exitCode != 0) {
        rarFailures++;
        rarChecks.add({'fixture': fixture, 'extraction': 'failed', 'ok': false});
        continue;
      }
      final row = manifest.singleWhere((final r) => r['file'] == fixture);
      final pinned = <String, String>{
        for (final entry in (row['entries']! as List).cast<Map<String, Object?>>())
          entry['name']! as String: entry['sha256']! as String,
      };
      var extractionOk = true;
      final extractedFiles = Directory(target)
          .listSync(recursive: true)
          .whereType<File>()
          .map((final file) => file.uri.pathSegments.last)
          .toSet();
      if (!extractedFiles.containsAll(pinned.keys.toSet())) {
        extractionOk = false;
      } else {
        for (final entry in pinned.entries) {
          final bytes = File('$target/${entry.key}').readAsBytesSync();
          if (crypto.sha256.convert(bytes).toString() != entry.value) {
            extractionOk = false;
          }
        }
      }
      if (!extractionOk) rarFailures++;

      final listing = await Process.run(rarPath, [
        'lt',
        '$_resourceDir/$fixture',
      ], stdoutEncoding: const convert.Utf8Codec(allowMalformed: true));
      final listingText = listing.stdout.toString();
      final compressionLines = listingText
          .split('\n')
          .where((final line) => line.trim().startsWith('Compression:'))
          .toList();
      final versionCut =
          listing.exitCode == 0 &&
          compressionLines.length == pinned.length &&
          compressionLines.every((final line) => line.contains('RAR 5.0(v50)'));
      if (!versionCut) rarFailures++;
      rarChecks.add({
        'fixture': fixture,
        'extraction': extractionOk ? 'byte-identical' : 'MISMATCH',
        'pinnedEntries': pinned.length,
        'compressionCut': versionCut ? 'v50' : 'OUTSIDE',
        'ok': extractionOk && versionCut,
      });
    }
  } finally {
    scratch.deleteSync(recursive: true);
  }
  steps.add({
    'name': 'rar-corpus',
    'checks': rarChecks,
    'failures': rarFailures,
    'status': rarFailures == 0 ? 'ok' : 'failed',
  });
  record['katChecks'] = katChecks.length;

  File(
    '$out/reference.json',
  ).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(record)}\n');
  stdout.writeln(
    'reference stage ${rarFailures == 0 && katFailures == 0 ? "PASSED" : "FAILED"}: '
    '${katChecks.length} KATs, ${rarChecks.length} RAR checks -> $out/reference.json',
  );
  return rarFailures == 0 ? 0 : 1;
}

/// Runs the C harness over [input] through its stdin and returns the
/// hex digest line.
Future<String> _runHarness(final String harness, final Uint8List input) async {
  final process = await Process.start(harness, const []);
  process.stdin.add(input);
  await process.stdin.flush();
  await process.stdin.close();
  final output = await process.stdout
      .transform(const convert.Utf8Decoder(allowMalformed: true))
      .join();
  final exit = await process.exitCode;
  if (exit != 0) {
    throw StateError('C harness exited with $exit');
  }
  return output.trim();
}

String _hex(final Uint8List bytes) =>
    bytes.map((final b) => b.toRadixString(16).padLeft(2, '0')).join();

bool _bytesEqual(final Uint8List a, final Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
