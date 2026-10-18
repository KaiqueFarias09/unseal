import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'jpx_precision/lanes.dart';

/// Executes the OpenJPEG reference over the JPEG 2000 precision corpus
/// (the `version` and `reference` stages of the campaign manifest,
/// doc/jpeg2000-precision.md).
///
///     dart run tool/jpx_precision_reference.dart --version
///     dart run tool/jpx_precision_reference.dart --out=build/evidence/C04
///
/// `--version` prints the effective library/binary versions and hashes
/// and exits 0 only when they match the pinned `openjp2 2.5.4`.
///
/// The reference run copies every committed fixture read-only into
/// `<out>/inputs/` after checking its SHA-256 against the corpus
/// MANIFEST, runs `opj_oracle dump` (libopenjp2 through its API, native
/// samples) and `opj_decompress` (`-upsample` and sYCC lanes) on the
/// copies, requires every fresh payload to equal the committed oracle
/// byte for byte, and writes `<out>/reference.json` with the HEAD,
/// commands, exit codes, durations and hashes. Nothing is written
/// outside `<out>`.
///
/// Environment: `OPJ_BIN` (default `/opt/homebrew/bin`), `OPJ_ORACLE`
/// (default `build/tools/opj_oracle`, built on demand with
/// `tool/jpx_oracle/build.sh`), `FFMPEG` (default `ffmpeg`).
const String kPinnedOpenJpegVersion = '2.5.4';

void main(final List<String> arguments) {
  final opjBin = Platform.environment['OPJ_BIN'] ?? '/opt/homebrew/bin';
  final oracleTool = Platform.environment['OPJ_ORACLE'] ?? 'build/tools/opj_oracle';
  final ffmpeg = Platform.environment['FFMPEG'] ?? 'ffmpeg';
  if (arguments.contains('--version')) {
    exitCode = _version(opjBin, oracleTool, ffmpeg) ? 0 : 1;
    return;
  }
  final out = _option(arguments, '--out') ?? 'build/evidence/C04';
  exitCode = _reference(opjBin, oracleTool, ffmpeg, out) ? 0 : 1;
}

String? _option(final List<String> arguments, final String name) {
  for (final argument in arguments) {
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

String _sha256File(final String path) => sha256.convert(File(path).readAsBytesSync()).toString();

String? _resolveBinary(final String path) {
  final file = File(path);
  if (file.existsSync()) {
    return file.resolveSymbolicLinksSync();
  }
  final found = Process.runSync('which', <String>[path]);
  final resolved = found.stdout.toString().trim();
  return found.exitCode == 0 && resolved.isNotEmpty
      ? File(resolved).resolveSymbolicLinksSync()
      : null;
}

bool _ensureOracle(final String oracleTool) {
  if (File(oracleTool).existsSync()) {
    return true;
  }
  stdout.writeln('building $oracleTool with tool/jpx_oracle/build.sh');
  final build = Process.runSync('sh', <String>['tool/jpx_oracle/build.sh']);
  stdout.write(build.stdout);
  stderr.write(build.stderr);
  return build.exitCode == 0 && File(oracleTool).existsSync();
}

/// Collects the effective tool versions; prints and pins them.
Map<String, Object?>? _tools(final String opjBin, final String oracleTool, final String ffmpeg) {
  final decompress = _resolveBinary('$opjBin/opj_decompress');
  final compress = _resolveBinary('$opjBin/opj_compress');
  if (decompress == null || compress == null) {
    stderr.writeln('opj_decompress/opj_compress not found under $opjBin');
    return null;
  }
  // opj_decompress -h exits 1 by design; the banner names the library.
  final banner = Process.runSync(decompress, <String>['-h']);
  final bannerText = '${banner.stdout}${banner.stderr}';
  final match = RegExp(r'openjp2 library v(\d+\.\d+\.\d+)').firstMatch(bannerText);
  final libraryVersion = match?.group(1);
  if (!_ensureOracle(oracleTool)) {
    stderr.writeln('opj_oracle is unavailable');
    return null;
  }
  final oracleVersion = Process.runSync(oracleTool, <String>['version']);
  final oracleText = oracleVersion.stdout.toString().trim();
  final ffmpegPath = _resolveBinary(ffmpeg);
  final ffmpegVersion = ffmpegPath == null
      ? null
      : Process.runSync(ffmpegPath, <String>[
          '-version',
        ]).stdout.toString().split('\n').first.trim();
  final libraries = <String>[
    for (final candidate in <String>[
      '${File(decompress).parent.parent.path}/lib/libopenjp2.$kPinnedOpenJpegVersion.dylib',
      '/opt/homebrew/lib/libopenjp2.$kPinnedOpenJpegVersion.dylib',
    ])
      if (File(candidate).existsSync()) candidate,
  ];
  return <String, Object?>{
    'pinnedLibraryVersion': kPinnedOpenJpegVersion,
    'upstream':
        'https://github.com/uclouvain/openjpeg/tree/v2.5.4 (6c4a29b00211eb0430fa0e5e890f1ce5c80f409f)',
    'opj_decompress': <String, Object?>{
      'path': decompress,
      'sha256': _sha256File(decompress),
      'bannerExitCode': banner.exitCode,
      'libraryVersion': libraryVersion,
    },
    'opj_compress': <String, Object?>{'path': compress, 'sha256': _sha256File(compress)},
    'libopenjp2': <Object?>[
      for (final library in libraries.toSet())
        <String, Object?>{'path': library, 'sha256': _sha256File(library)},
    ],
    'opj_oracle': <String, Object?>{
      'path': oracleTool,
      'sha256': _sha256File(oracleTool),
      'version': oracleText,
      'source': 'tool/jpx_oracle/opj_oracle.c',
      'sourceSha256': _sha256File('tool/jpx_oracle/opj_oracle.c'),
    },
    'ffmpeg': <String, Object?>{
      'path': ffmpegPath,
      'version': ffmpegVersion,
      if (ffmpegPath != null) 'sha256': _sha256File(ffmpegPath),
      'role': 'independent producer of the real-* fixtures (development tool only)',
    },
  };
}

bool _version(final String opjBin, final String oracleTool, final String ffmpeg) {
  final tools = _tools(opjBin, oracleTool, ffmpeg);
  if (tools == null) {
    return false;
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(tools));
  final decompress = tools['opj_decompress']! as Map<String, Object?>;
  final oracle = tools['opj_oracle']! as Map<String, Object?>;
  final ok =
      decompress['libraryVersion'] == kPinnedOpenJpegVersion &&
      (oracle['version'] as String).endsWith(kPinnedOpenJpegVersion);
  stdout.writeln(
    ok ? 'reference pin satisfied: openjp2 $kPinnedOpenJpegVersion' : 'REFERENCE PIN MISMATCH',
  );
  return ok;
}

/// `<sha256>  <path>` lines from the corpus MANIFEST.
Map<String, String> _manifestHashes() {
  final text = File('$kJpxPrecisionCorpusDir/MANIFEST.md').readAsStringSync();
  final hashes = <String, String>{};
  for (final match in RegExp(r'^([0-9a-f]{64})  (\S+)$', multiLine: true).allMatches(text)) {
    hashes[match.group(2)!] = match.group(1)!;
  }
  return hashes;
}

Map<String, Object?> _run(final String executable, final List<String> arguments) {
  final watch = Stopwatch()..start();
  final result = Process.runSync(
    executable,
    arguments,
    stdoutEncoding: const Utf8Codec(allowMalformed: true),
  );
  watch.stop();
  return <String, Object?>{
    'argv': <String>[executable, ...arguments],
    'exitCode': result.exitCode,
    'durationMs': watch.elapsedMilliseconds,
    'stdoutTail': result.stdout
        .toString()
        .trim()
        .split('\n')
        .where((final l) => l.isNotEmpty)
        .toList()
        .reversed
        .take(2)
        .toList()
        .reversed
        .join(' | '),
  };
}

bool _reference(
  final String opjBin,
  final String oracleTool,
  final String ffmpeg,
  final String out,
) {
  final tools = _tools(opjBin, oracleTool, ffmpeg);
  if (tools == null) {
    return false;
  }
  final head = Process.runSync('git', <String>['rev-parse', 'HEAD']).stdout.toString().trim();
  final inputs = Directory('$out/inputs')..createSync(recursive: true);
  final references = Directory('$out/reference')..createSync(recursive: true);
  final corpus = loadPrecisionCorpus();
  final manifest = _manifestHashes();
  final decompress = (tools['opj_decompress']! as Map<String, Object?>)['path']! as String;
  final fixtures = <Map<String, Object?>>[];
  var problems = 0;
  var commands = 0;
  var artifacts = 0;

  for (final fixture in corpus) {
    final source = File('$kJpxPrecisionCorpusDir/${fixture.file}');
    final copy = File('${inputs.path}/${fixture.file}');
    if (copy.existsSync()) {
      Process.runSync('chmod', <String>['644', copy.path]);
    }
    copy.writeAsBytesSync(source.readAsBytesSync());
    Process.runSync('chmod', <String>['444', copy.path]);
    final inputHash = _sha256File(copy.path);
    final expectedHash = manifest[fixture.file];
    final hashOk = expectedHash == inputHash && _sha256File(source.path) == inputHash;
    if (!hashOk) {
      problems++;
    }
    final record = <String, Object?>{
      'name': fixture.name,
      'file': fixture.file,
      'producer': fixture.producer,
      'precision': fixture.precision,
      'lanes': fixture.lanes,
      'inputCopy': copy.path,
      'inputSha256': inputHash,
      'manifestSha256': expectedHash,
      'inputHashVerified': hashOk,
      'commands': <Object?>[],
      'artifacts': <Object?>[],
    };
    final recordCommands = record['commands']! as List<Object?>;
    final recordArtifacts = record['artifacts']! as List<Object?>;

    void artifact(final String path, final String committed) {
      final produced = File(path);
      final ok = produced.existsSync() && _sha256File(path) == _sha256File(committed);
      if (!ok) {
        problems++;
      }
      artifacts++;
      recordArtifacts.add(<String, Object?>{
        'path': path,
        'sha256': produced.existsSync() ? _sha256File(path) : null,
        'bytes': produced.existsSync() ? produced.lengthSync() : 0,
        'committedReference': committed,
        'matchesCommitted': ok,
      });
    }

    final nativeJson = '${references.path}/${fixture.name}.native.json';
    final nativeBin = '${references.path}/${fixture.name}.native.bin';
    final dump = _run(oracleTool, <String>['dump', copy.path, nativeJson, nativeBin]);
    commands++;
    recordCommands.add(dump);
    if (dump['exitCode'] != 0) {
      problems++;
    }
    artifact(nativeBin, '$kJpxPrecisionCorpusDir/oracle/${fixture.name}.native.bin');
    artifact(nativeJson, '$kJpxPrecisionCorpusDir/oracle/${fixture.name}.native.json');

    for (final lane in fixture.lanes) {
      if (lane == 'native') continue;
      final rawl = '${references.path}/${fixture.name}.$lane.rawl';
      final run = _run(decompress, <String>[
        '-i',
        copy.path,
        '-o',
        rawl,
        if (lane == 'upsample') '-upsample',
      ]);
      commands++;
      recordCommands.add(run);
      if (run['exitCode'] != 0) {
        problems++;
      }
      artifact(rawl, '$kJpxPrecisionCorpusDir/oracle/${fixture.name}.$lane.rawl');
    }
    fixtures.add(record);
    stdout.writeln(
      '${fixture.name}: ${recordCommands.length} command(s), '
      '${recordArtifacts.length} artifact(s) ${problems == 0 ? 'match' : 'checked'}',
    );
  }

  final report = <String, Object?>{
    'schemaVersion': 1,
    'mission': 'C04',
    'head': head,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'protocol': 'doc/jpeg2000-precision.md',
    'tools': tools,
    'corpus': <String, Object?>{
      'dir': kJpxPrecisionCorpusDir,
      'manifestSha256': _sha256File('$kJpxPrecisionCorpusDir/MANIFEST.md'),
      'corpusJsonSha256': _sha256File('$kJpxPrecisionCorpusDir/corpus.json'),
      'tolerancesSha256': _sha256File('$kJpxPrecisionCorpusDir/tolerances.json'),
      'fixtures': corpus.length,
    },
    'summary': <String, Object?>{
      'fixtures': fixtures.length,
      'commands': commands,
      'artifacts': artifacts,
      'problems': problems,
      'status': problems == 0 ? 'passed' : 'failed',
    },
    'fixtures': fixtures,
  };
  File(
    '$out/reference.json',
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln(
    'reference ${problems == 0 ? 'PASSED' : 'FAILED'}: ${fixtures.length} fixtures, '
    '$commands reference commands, $artifacts artifacts, $problems problem(s) -> $out/reference.json',
  );
  return problems == 0;
}
