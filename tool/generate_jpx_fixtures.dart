import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const String _fixturesDir = 'test/resources/pdf/jpeg2000';

/// Regenerates and verifies the JPEG 2000 fixture family under
/// `test/resources/pdf/jpeg2000/`.
///
/// Every codestream is compressed by OpenJPEG `opj_compress` and every
/// reference payload is decoded by two separate OpenJPEG builds
/// (Release and Debug) of the same pinned revision, so the lossy
/// tolerance ceilings in `tolerances.json` come from oracle-side
/// variability only — never from Dart output. The two ffmpeg-produced
/// codestreams provide a second, independent encoder; they are verified
/// against the same OpenJPEG oracle.
///
/// Environment:
/// - `OPJ_RELEASE_BIN`: directory holding `opj_compress` and
///   `opj_decompress` of the pinned OpenJPEG revision (Release build).
/// - `OPJ_DEBUG_BIN`: directory holding a second `opj_decompress` build
///   (Debug) of the same revision.
/// - `FFMPEG` (optional): ffmpeg binary for the independent-encoder
///   fixtures; those are only regenerated with `--with-ffmpeg`.
///
/// Usage:
/// - `dart run tool/generate_jpx_fixtures.dart` verifies the committed
///   fixtures reproduce byte for byte.
/// - `--write` regenerates fixtures, oracle payloads and tolerances.
///   Sources are deterministic; the real-photo derivatives are inputs
///   committed once and verified like everything else.
void main(final List<String> args) {
  final write = args.contains('--write');
  final withFfmpeg = args.contains('--with-ffmpeg');
  final releaseBin = Platform.environment['OPJ_RELEASE_BIN'];
  final debugBin = Platform.environment['OPJ_DEBUG_BIN'];
  if (releaseBin == null || debugBin == null) {
    stderr.writeln(
      'Set OPJ_RELEASE_BIN and OPJ_DEBUG_BIN to OpenJPEG build bin '
      'directories (pinned revision 8314119b, see MANIFEST.md).',
    );
    exitCode = 2;
    return;
  }

  final root = Directory(_fixturesDir);
  if (!root.existsSync()) {
    stderr.writeln('Missing $_fixturesDir; run from the repository root.');
    exitCode = 2;
    return;
  }

  final problems = <String>[];
  for (final entry in _sources.entries) {
    if (entry.key.startsWith('real-')) continue; // committed inputs
    _checkOrWrite(File('$_fixturesDir/src/${entry.key}'), entry.value, write, 'source', problems);
  }

  final temp = Directory.systemTemp.createTempSync('unseal-jpx-gen');
  try {
    for (final spec in _matrix) {
      final committed = File('$_fixturesDir/${spec.name}.${spec.extension}');
      final canEncode = !spec.real || withFfmpeg;
      if (write && canEncode) {
        final bytes = spec.encodeCommitted(temp.path, releaseBin, problems);
        if (bytes != null) {
          _checkOrWrite(committed, bytes, true, 'codestream', problems);
        }
      } else if (canEncode) {
        final bytes = spec.encodeCommitted(temp.path, releaseBin, problems);
        if (bytes != null) {
          _checkOrWrite(committed, bytes, false, 'codestream', problems);
        }
      }
      if (!committed.existsSync()) {
        if (!problems.any((final item) => item.contains(committed.path))) {
          problems.add('${committed.path}: missing (rerun with --write)');
        }
        continue;
      }

      // Oracle payloads: decode the committed codestream with both
      // builds and keep the byte-exact reference in the repository.
      for (final (dir, bin) in <(String, String)>[
        ('oracle', '$releaseBin/opj_decompress'),
        ('oracle-debug', '$debugBin/opj_decompress'),
      ]) {
        final rawFile = File('${temp.path}/${spec.name}.raw');
        final result = Process.runSync(bin, <String>[
          '-i',
          committed.path,
          '-o',
          rawFile.path,
        ], stdoutEncoding: const Utf8Codec(allowMalformed: true));
        if (result.exitCode != 0 || !rawFile.existsSync()) {
          problems.add('${spec.name}: $bin failed to decode the fixture.');
          continue;
        }
        _checkOrWrite(
          File('$_fixturesDir/$dir/${spec.name}.raw'),
          rawFile.readAsBytesSync(),
          write,
          'oracle payload',
          problems,
        );
      }
    }

    // Tolerance ceilings from inter-build oracle deltas only.
    final tolerances = <String, Object?>{
      'protocol':
          'Lossless fixtures compare byte-exact against the pinned Release '
          'oracle payload. Lossy ceilings were fixed before any Dart '
          'decoder run: observed inter-build OpenJPEG deltas (Release '
          '8314119b vs Debug 8314119b, all zero on this corpus) plus a '
          'float-precision allowance of 3 sample levels / RMSE 0.5 for a '
          'float64 decoder matching the float32 oracle pipeline, capped '
          'by the globals. Loosening them afterwards invalidates '
          'acceptance; tightening is always allowed.',
      'globalMaxAbsError': 4,
      'globalRmse': 1.0,
      'fixtures': <String, Object?>{},
    };
    final fixtureCeilings = tolerances['fixtures']! as Map<String, Object?>;
    for (final spec in _matrix) {
      if (spec.lossless) continue;
      final release = _readOrNull('$_fixturesDir/oracle/${spec.name}.raw');
      final debug = _readOrNull('$_fixturesDir/oracle-debug/${spec.name}.raw');
      if (release == null || debug == null) continue;
      if (release.length != debug.length) {
        problems.add('${spec.name}: oracle builds produced different sizes.');
        continue;
      }
      final stats = _compare(release, debug);
      fixtureCeilings[spec.name] = <String, Object?>{
        // The pinned builds agree bit-exact on every fixture (observed
        // inter-build delta 0), so the ceiling carries a float-precision
        // allowance for a float64 decoder matching OpenJPEG's float32
        // pipeline: 3 sample levels of accumulated lifting/dequant
        // rounding, an RMSE of 0.5, floored by nothing and capped by the
        // globals. Loosening these numbers after the first Dart
        // comparison invalidates acceptance.
        'maxAbsError': stats.$2 + 3 <= 4 ? stats.$2 + 3 : 4,
        'rmse': stats.$3 + 0.5 <= 1.0 ? stats.$3 + 0.5 : 1.0,
      };
    }

    final tolerancesFile = File('$_fixturesDir/tolerances.json');
    if (write) {
      tolerancesFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(tolerances)}\n',
      );
    } else if (tolerancesFile.existsSync()) {
      final committed =
          const JsonDecoder().convert(tolerancesFile.readAsStringSync()) as Map<String, Object?>;
      if (committed.toString() != tolerances.toString()) {
        problems.add('tolerances.json: does not match inter-build oracle deltas.');
      }
    }
  } finally {
    temp.deleteSync(recursive: true);
  }

  for (final problem in problems) {
    stdout.writeln('MISMATCH $problem');
  }
  if (problems.isNotEmpty) {
    exitCode = 1;
    return;
  }
  stdout.writeln(write ? 'JPEG2000 fixtures written.' : 'JPEG2000 fixtures verified.');
}

/// The compression matrix. Every accepted decoder variant owns one
/// fixture here; `real` entries come from the independent ffmpeg
/// encoder over a public-domain photograph instead of opj_compress.
const List<_Spec> _matrix = <_Spec>[
  _Spec('gray53-lossless-lrcp', 'g64.pgm', <String>['-n', '5']),
  _Spec('gray53-lossless-rlcp', 'g64.pgm', <String>['-n', '5', '-p', 'RLCP']),
  _Spec.lossy('gray97-lossy-lrcp', 'g64.pgm', <String>['-n', '5', '-I', '-r', '6']),
  _Spec.lossy('gray97-lossy-rlcp', 'g64.pgm', <String>['-n', '5', '-I', '-r', '6', '-p', 'RLCP']),
  _Spec('rgb53-lossless-rct', 'c64.ppm', <String>['-n', '5', '-mct', '1']),
  _Spec('rgb53-lossless-nomct', 'c64.ppm', <String>['-n', '5', '-mct', '0']),
  _Spec.lossy('rgb97-lossy-ict', 'c64.ppm', <String>['-n', '5', '-I', '-r', '6', '-mct', '1']),
  _Spec.lossy('rgb97-lossy-nomct-rlcp', 'c64.ppm', <String>[
    '-n',
    '5',
    '-I',
    '-r',
    '6',
    '-mct',
    '0',
    '-p',
    'RLCP',
  ]),
  _Spec('gray53-lossless-multitile', 'g100x67.pgm', <String>['-n', '4', '-t', '64,64']),
  _Spec.lossy('rgb97-lossy-multitile', 'c100x67.ppm', <String>[
    '-n',
    '4',
    '-I',
    '-r',
    '5',
    '-t',
    '64,64',
    '-mct',
    '1',
  ]),
  _Spec.lossy('gray97-lossy-3layers', 'g128.pgm', <String>['-n', '5', '-I', '-r', '12,6,3']),
  _Spec('gray53-lossless-jp2', 'g64.pgm', <String>['-n', '5'], extension: 'jp2'),
  _Spec.lossy('rgb97-lossy-jp2', 'c64.ppm', <String>['-n', '5', '-I', '-r', '6'], extension: 'jp2'),
  _Spec('rgb53-lossless-nomct-jp2', 'c64.ppm', <String>['-n', '5', '-mct', '0'], extension: 'jp2'),
  _Spec('gray53-lossless-sop-eph', 'g64.pgm', <String>['-n', '5', '-SOP', '-EPH']),
  _Spec('gray53-lossless-bypass', 'g64.pgm', <String>['-n', '5', '-M', '1']),
  _Spec('gray53-lossless-segmark', 'g64.pgm', <String>['-n', '5', '-M', '32']),
  _Spec('gray53-lossless-precincts', 'g64.pgm', <String>['-n', '5', '-c', '[32,32],[16,16]']),
  _Spec.lossy('gray97-lossy-256', 'g256.pgm', <String>['-n', '6', '-I', '-r', '6']),
  _Spec(
    'real-rgb53-lossless-ffmpeg',
    'real-rgb128.ppm',
    <String>['-c:v', 'jpeg2000', '-pred', 'dwt53', '-format', 'j2k', '-frames:v', '1'],
    real: true,
    encoder: 'ffmpeg',
  ),
  _Spec.lossy(
    'real-gray97-lossy-ffmpeg',
    'real-gray128.pgm',
    <String>['-c:v', 'jpeg2000', '-pred', 'dwt97int', '-format', 'j2k', '-frames:v', '1'],
    real: true,
    encoder: 'ffmpeg',
  ),
];

final class _Spec {
  const _Spec(
    this.name,
    this.source,
    this.args, {
    this.extension = 'j2k',
    this.real = false,
    this.encoder = 'opj_compress',
  }) : lossless = true;

  const _Spec.lossy(
    this.name,
    this.source,
    this.args, {
    this.extension = 'j2k',
    this.real = false,
    this.encoder = 'opj_compress',
  }) : lossless = false;

  final String name;
  final String source;
  final List<String> args;
  final String extension;
  final bool real;
  final bool lossless;
  final String encoder;

  /// Compresses (or encodes) this fixture into the temporary directory
  /// and returns the produced bytes, or null after recording a problem.
  Uint8List? encodeCommitted(
    final String dir,
    final String releaseBin,
    final List<String> problems,
  ) {
    final sourceFile = File('$dir/$source');
    sourceFile.writeAsBytesSync(_sourceBytes(source));
    final produced = File('$dir/$name.$extension');
    final ProcessResult result;
    if (encoder == 'ffmpeg') {
      final ffmpeg = Platform.environment['FFMPEG'] ?? 'ffmpeg';
      result = Process.runSync(ffmpeg, <String>[
        '-y',
        '-loglevel',
        'error',
        '-i',
        sourceFile.path,
        ...args,
        produced.path,
      ]);
    } else {
      result = Process.runSync('$releaseBin/opj_compress', <String>[
        '-i',
        sourceFile.path,
        '-o',
        produced.path,
        ...args,
      ]);
    }
    if (result.exitCode != 0 || !produced.existsSync()) {
      problems.add('$name: $encoder failed: ${result.stderr}');
      return null;
    }
    return produced.readAsBytesSync();
  }
}

/// Deterministic sources. `real-*.pgm|ppm` are committed inputs derived
/// once from the public-domain NASA Apollo 17 photograph (see
/// MANIFEST.md); everything else regenerates from these functions.
final Map<String, Uint8List> _sources = _buildSources();

Map<String, Uint8List> _buildSources() {
  return <String, Uint8List>{
    'g64.pgm': _pgm('P5', 64, 64, 0x5EED, 1),
    'g128.pgm': _pgm('P5', 128, 128, 0x5EED, 1),
    'g100x67.pgm': _pgm('P5', 100, 67, 0xBEEF, 1),
    'g256.pgm': _pgm('P5', 256, 256, 0x1234, 1),
    'c64.ppm': _pgm('P6', 64, 64, 0xFACE, 3),
    'c100x67.ppm': _pgm('P6', 100, 67, 0xC0DE, 3),
  };
}

Uint8List _pgm(
  final String magic,
  final int width,
  final int height,
  final int seed,
  final int channels,
) {
  final out = BytesBuilder();
  out.add(utf8.encode('$magic\n$width $height\n255\n'));
  out.add(_samples(width * channels, height, seed));
  return out.toBytes();
}

/// Gradient plus seeded LCG noise plus hard bars, so fixtures exercise
/// sign coding, strong edges and mid tones instead of flat fields.
Uint8List _samples(final int width, final int height, final int seed) {
  var state = seed & 0x7FFFFFFF;
  final out = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
      final noise = (state >> 16) & 0x3F;
      final gradient = (x * 255) ~/ (width > 1 ? width - 1 : 1);
      final bars = ((x ~/ 7) + (y ~/ 5)) % 11 == 0 ? 0 : 255;
      final value = (gradient ~/ 2) + noise + ((bars - 128) ~/ 8) + 32;
      out[y * width + x] = value.clamp(0, 255);
    }
  }
  return out;
}

Uint8List _sourceBytes(final String name) {
  final generated = _sources[name];
  if (generated != null) return generated;
  final committed = File('$_fixturesDir/src/$name');
  if (!committed.existsSync()) {
    stderr.writeln(
      'Missing committed real-photo source $name; see MANIFEST.md for the '
      'derivation from the NASA Apollo 17 photograph.',
    );
    exit(2);
  }
  return committed.readAsBytesSync();
}

Uint8List? _readOrNull(final String path) {
  final file = File(path);
  return file.existsSync() ? file.readAsBytesSync() : null;
}

/// Returns (sampleCount, maxAbsError, rmse) between two oracle payloads.
(int, int, double) _compare(final Uint8List first, final Uint8List second) {
  var max = 0;
  var sumSquares = 0;
  for (var index = 0; index < first.length; index++) {
    final delta = first[index] - second[index];
    final magnitude = delta.abs();
    if (magnitude > max) max = magnitude;
    sumSquares += delta * delta;
  }
  final rmse = first.isEmpty ? 0.0 : _sqrt(sumSquares / first.length.toDouble());
  return (first.length, max, rmse);
}

double _sqrt(final double value) {
  if (value <= 0) return 0;
  var guess = value > 1 ? value / 2 : value;
  for (var i = 0; i < 64; i++) {
    guess = 0.5 * (guess + value / guess);
  }
  return guess;
}

void _checkOrWrite(
  final File file,
  final Uint8List bytes,
  final bool write,
  final String kind,
  final List<String> problems,
) {
  if (write) {
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return;
  }
  if (!file.existsSync()) {
    problems.add('${file.path}: missing $kind (rerun with --write)');
    return;
  }
  if (!_equal(file.readAsBytesSync(), bytes)) {
    problems.add('${file.path}: $kind differs from the generator.');
  }
}

bool _equal(final List<int> first, final List<int> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
