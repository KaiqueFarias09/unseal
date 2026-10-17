import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// Produces the oracle reference evidence for the solid corpus: fixture
/// copies with hash-verified bytes, extraction through the pinned
/// rardecode and libarchive oracles, and a per-entry digest report the
/// oracle gate consumes.
///
/// Inputs are copied read-only into `build/rar5-solid/inputs` and every
/// extraction lands under `build/rar5-solid/reference` — the versioned
/// test fixtures are never touched.
///
/// Usage:
/// ```
/// dart run tool/rar5_solid_reference.dart \
///   [--oracle=<path-to-rardecode-oracle>] [--bsdtar=/usr/bin/bsdtar] \
///   [--out=build/rar5-solid]
/// ```
void main(final List<String> arguments) {
  var oracleBinary = '';
  var bsdtar = '/usr/bin/bsdtar';
  var outDir = 'build/rar5-solid';
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i].startsWith('--oracle=')) {
      oracleBinary = arguments[i].substring('--oracle='.length);
    } else if (arguments[i].startsWith('--bsdtar=')) {
      bsdtar = arguments[i].substring('--bsdtar='.length);
    } else if (arguments[i].startsWith('--out=')) {
      outDir = arguments[i].substring('--out='.length);
    }
  }
  if (oracleBinary.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/rar5_solid_reference.dart --oracle=<binary> '
      '[--bsdtar=path] [--out=dir]',
    );
    exit(2);
  }

  const solidFixtures = [
    'rar5-solid-chain.cbr',
    'rar5-solid-comic.cbr',
    'rar5-solid-mixed.cbr',
    'rar5-solid-dict-grow.cbr',
    'rar5-solid-filter-e8.cbr',
    'libarchive-solid.rar',
  ];
  const fixtureDir = 'test/resources/books/comic/rar5';

  final inputs = Directory('$outDir/inputs');
  if (inputs.existsSync()) inputs.deleteSync(recursive: true);
  inputs.createSync(recursive: true);
  final reference = Directory('$outDir/reference');
  if (reference.existsSync()) reference.deleteSync(recursive: true);
  reference.createSync(recursive: true);

  final report = <String, Object>{
    'oracles': {'rardecode': oracleBinary, 'bsdtar': bsdtar},
    'archives': <Object>[],
  };

  var entries = 0;
  for (final name in solidFixtures) {
    final source = File('$fixtureDir/$name');
    if (!source.existsSync()) {
      stderr.writeln('FAIL: missing fixture $name');
      exit(1);
    }
    final bytes = source.readAsBytesSync();
    final sha = crypto.sha256.convert(bytes).toString();
    final copy = File('${inputs.path}/$name');
    copy.writeAsBytesSync(bytes, mode: FileMode.writeOnly);
    // Read-only inputs, mirroring the protocol's copy discipline.
    Process.runSync('chmod', ['444', copy.path]);
    final copySha = crypto.sha256.convert(copy.readAsBytesSync()).toString();
    if (copySha != sha) {
      stderr.writeln('FAIL: the copy of $name does not match its source bytes');
      exit(1);
    }

    final rardecodeOut = '${reference.path}/$name-rardecode';
    final libarchiveOut = '${reference.path}/$name-libarchive';
    Directory(rardecodeOut).createSync(recursive: true);
    Directory(libarchiveOut).createSync(recursive: true);
    _run(oracleBinary, [copy.path, rardecodeOut]);
    _run(bsdtar, ['-x', '-f', copy.absolute.path, '-C', libarchiveOut]);

    final rardecodeDigests = _digests(rardecodeOut);
    final libarchiveDigests = _digests(libarchiveOut);
    // Filesystems may normalize extracted names (macOS writes NFD while
    // the archive stores NFC), so oracle agreement pairs on content:
    // the sorted (bytes, sha256) multisets must be identical and every
    // digest unique.
    final rardecodeContents =
        rardecodeDigests.values.map((final d) => '${d.length}:${d.digest}').toList()..sort();
    final libarchiveContents =
        libarchiveDigests.values.map((final d) => '${d.length}:${d.digest}').toList()..sort();
    if (rardecodeContents.length != libarchiveContents.length ||
        rardecodeContents.toString() != libarchiveContents.toString()) {
      stderr.writeln('FAIL: the oracles diverge on $name');
      stderr.writeln('rardecode: $rardecodeDigests');
      stderr.writeln('libarchive: $libarchiveDigests');
      exit(1);
    }

    entries += rardecodeDigests.length;
    (report['archives'] as List<Object>).add({
      'archive': name,
      'fixtureSha256': sha,
      'entries': [
        for (final entry in rardecodeDigests.entries)
          {'name': entry.key, 'bytes': entry.value.length, 'sha256': entry.value.digest},
      ],
    });
    stdout.writeln('$name: ${rardecodeDigests.length} entries, oracles agree on content');
  }

  report['totals'] = {'archives': solidFixtures.length, 'entries': entries};
  final reportFile = File('$outDir/reference-digests.json');
  reportFile.writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln('reference digests written to ${reportFile.path}');
}

Map<String, ({int length, String digest})> _digests(final String dirPath) {
  final digests = <String, ({int length, String digest})>{};
  for (final entity in Directory(dirPath).listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = entity.path.substring(dirPath.length + 1).replaceAll('\\', '/');
    final Uint8List bytes;
    try {
      bytes = entity.readAsBytesSync();
    } on FileSystemException {
      continue; // name-normalized duplicates from concurrent walks
    }
    digests[relative] = (length: bytes.length, digest: crypto.sha256.convert(bytes).toString());
  }

  return digests;
}

void _run(final String executable, final List<String> arguments) {
  final result = Process.runSync(executable, arguments);
  if (result.exitCode != 0) {
    throw StateError(
      '$executable ${arguments.join(' ')} failed (${result.exitCode}):\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
}
