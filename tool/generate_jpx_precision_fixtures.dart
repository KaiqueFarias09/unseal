import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Regenerates and verifies the JPEG 2000 precision/subsampling corpus
/// under `test/resources/pdf/jpeg2000/precision/` (doc/jpeg2000-precision.md).
///
/// Producers:
/// - `build/tools/opj_oracle encode` (libopenjp2 2.5.4 through its public
///   API, `tool/jpx_oracle/`): synthetic fixtures with per-component grids,
///   odd sizes, odd origins, tiles, COD options.
/// - `ffmpeg` (native jpeg2000 encoder): the independent producer, fed
///   with the committed public-domain NASA Apollo 17 derivative.
///
/// References, per committed fixture:
/// - `oracle/<name>.native.json|.bin`: every component's native samples
///   from `opj_oracle dump` (no utility post-processing).
/// - `oracle/<name>.upsample.rawl`: `opj_decompress -upsample` output for
///   non-sYCC subsampled fixtures.
/// - `oracle/<name>.rgb.rawl`: `opj_decompress` output (sYCC converted)
///   for sYCC fixtures.
///
/// Environment: `OPJ_ORACLE` (default `build/tools/opj_oracle`), `OPJ_BIN`
/// (default `/opt/homebrew/bin`), `FFMPEG` (default `ffmpeg` on PATH).
///
/// `dart run tool/generate_jpx_precision_fixtures.dart` verifies that every
/// committed byte reproduces; `--write` regenerates fixtures, oracles,
/// `corpus.json`, `tolerances.json` and `MANIFEST.md`.
void main(final List<String> args) {
  final write = args.contains('--write');
  final oracleTool = Platform.environment['OPJ_ORACLE'] ?? 'build/tools/opj_oracle';
  final opjBin = Platform.environment['OPJ_BIN'] ?? '/opt/homebrew/bin';
  final ffmpeg = Platform.environment['FFMPEG'] ?? 'ffmpeg';
  if (!File(oracleTool).existsSync()) {
    stderr.writeln('Missing $oracleTool; run `sh tool/jpx_oracle/build.sh` first.');
    exitCode = 2;
    return;
  }
  if (!Directory(kPrecisionFixturesDir).existsSync() && !write) {
    stderr.writeln('Missing $kPrecisionFixturesDir; rerun with --write.');
    exitCode = 2;
    return;
  }
  final problems = <String>[];
  final temp = Directory.systemTemp.createTempSync('unseal-jpx-precision');
  final hashes = <String, String>{};
  try {
    for (final spec in kPrecisionMatrix) {
      final committed = File('$kPrecisionFixturesDir/${spec.file}');
      final produced = spec.produce(temp.path, oracleTool, ffmpeg, problems);
      if (produced == null) continue;
      _checkOrWrite(committed, produced, write, 'codestream', problems);
      if (!committed.existsSync()) continue;
      final bytes = committed.readAsBytesSync();
      hashes[spec.file] = _sha256(bytes);

      // Native reference: libopenjp2 through opj_oracle dump.
      final nativeJson = File('${temp.path}/${spec.name}.native.json');
      final nativeBin = File('${temp.path}/${spec.name}.native.bin');
      final dump = Process.runSync(oracleTool, <String>[
        'dump',
        committed.path,
        nativeJson.path,
        nativeBin.path,
      ]);
      if (dump.exitCode != 0 || !nativeBin.existsSync()) {
        problems.add('${spec.name}: opj_oracle dump failed (${dump.stderr})');
        continue;
      }
      final geometry = jsonDecode(nativeJson.readAsStringSync()) as Map<String, Object?>;
      spec.checkGeometry(geometry, problems);
      for (final (suffix, file) in <(String, File)>[
        ('native.json', nativeJson),
        ('native.bin', nativeBin),
      ]) {
        final target = File('$kPrecisionFixturesDir/oracle/${spec.name}.$suffix');
        _checkOrWrite(target, file.readAsBytesSync(), write, 'native oracle', problems);
        if (target.existsSync()) {
          hashes['oracle/${spec.name}.$suffix'] = _sha256(target.readAsBytesSync());
        }
      }

      // Utility lanes: upsample (replication) and rgb (sYCC conversion).
      for (final lane in spec.lanes) {
        if (lane == 'native') continue;
        final rawl = File('${temp.path}/${spec.name}.$lane.rawl');
        final result = Process.runSync('$opjBin/opj_decompress', <String>[
          '-i',
          committed.path,
          '-o',
          rawl.path,
          if (lane == 'upsample') '-upsample',
        ], stdoutEncoding: const Utf8Codec(allowMalformed: true));
        if (result.exitCode != 0 || !rawl.existsSync()) {
          problems.add('${spec.name}: opj_decompress ($lane) failed: ${result.stderr}');
          continue;
        }
        final expected = spec.referenceGridBytes;
        if (rawl.lengthSync() != expected) {
          problems.add(
            '${spec.name}: $lane reference has ${rawl.lengthSync()} bytes, expected $expected',
          );
          continue;
        }
        final target = File('$kPrecisionFixturesDir/oracle/${spec.name}.$lane.rawl');
        _checkOrWrite(target, rawl.readAsBytesSync(), write, '$lane oracle', problems);
        if (target.existsSync()) {
          hashes['oracle/${spec.name}.$lane.rawl'] = _sha256(target.readAsBytesSync());
        }
      }
    }

    final corpus = <String, Object?>{
      'protocol': 'doc/jpeg2000-precision.md',
      'reference': <String, Object?>{
        'library': 'openjp2 2.5.4',
        'source': 'https://github.com/uclouvain/openjpeg/tree/v2.5.4',
        'commit': '6c4a29b00211eb0430fa0e5e890f1ce5c80f409f',
        'independentProducer': 'ffmpeg 9.0.2 native jpeg2000 encoder',
      },
      'fixtures': <Object?>[for (final spec in kPrecisionMatrix) spec.toJson()],
    };
    final tolerances = <String, Object?>{
      'protocol':
          'Fixed before any Dart decode (doc/jpeg2000-precision.md). Lossless '
          'fixtures compare exactly on every lane. Lossy native and upsample '
          'lanes allow max |err| 3 and RMSE 0.5 per component in absolute '
          'sample levels at any precision; the rgb lane allows 4 / 1.0 for '
          'the propagation of one-level native differences through the '
          'integer sYCC conversion. Loosening invalidates acceptance.',
      'globalMaxAbsError': 4,
      'globalRmse': 1.0,
      'lanes': <String, Object?>{
        'native': <String, Object?>{'maxAbsError': 3, 'rmse': 0.5},
        'upsample': <String, Object?>{'maxAbsError': 3, 'rmse': 0.5},
        'rgb': <String, Object?>{'maxAbsError': 4, 'rmse': 1.0},
      },
    };
    const encoder = JsonEncoder.withIndent('  ');
    _checkOrWriteText(
      File('$kPrecisionFixturesDir/corpus.json'),
      '${encoder.convert(corpus)}\n',
      write,
      'corpus.json',
      problems,
    );
    _checkOrWriteText(
      File('$kPrecisionFixturesDir/tolerances.json'),
      '${encoder.convert(tolerances)}\n',
      write,
      'tolerances.json',
      problems,
    );
    for (final name in <String>['corpus.json', 'tolerances.json']) {
      final file = File('$kPrecisionFixturesDir/$name');
      if (file.existsSync()) hashes[name] = _sha256(file.readAsBytesSync());
    }
    _checkOrWriteText(
      File('$kPrecisionFixturesDir/MANIFEST.md'),
      _manifest(hashes),
      write,
      'MANIFEST.md',
      problems,
    );
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
  stdout.writeln(
    write
        ? 'JPEG 2000 precision fixtures written (${kPrecisionMatrix.length}).'
        : 'JPEG 2000 precision fixtures verified (${kPrecisionMatrix.length}).',
  );
}

/// Where the corpus lives.
const String kPrecisionFixturesDir = 'test/resources/pdf/jpeg2000/precision';

/// One component grid of a fixture.
final class ComponentSpec {
  const ComponentSpec(this.dx, this.dy);

  final int dx;
  final int dy;
}

int _ceilDiv(final int value, final int divisor) => (value + divisor - 1) ~/ divisor;

/// A corpus entry: geometry, coding options, producer and lanes.
final class PrecisionSpec {
  const PrecisionSpec({
    required this.name,
    required this.precision,
    required this.components,
    required this.lanes,
    this.x0 = 0,
    this.y0 = 0,
    required this.x1,
    required this.y1,
    this.lossless = true,
    this.rate = 0,
    this.levels = 5,
    this.tiles,
    this.mct = 0,
    this.progression = 'LRCP',
    this.sop = false,
    this.eph = false,
    this.colorSpace = 'unknown',
    this.container = 'j2k',
    this.seed = 0x5EED,
    this.ffmpegPixelFormat,
    this.ffmpegPredictor,
    this.insertCocQcc = false,
  });

  final String name;
  final int precision;
  final List<ComponentSpec> components;

  /// `native` always; `upsample` for non-sYCC subsampled images; `rgb`
  /// for sYCC images.
  final List<String> lanes;
  final int x0;
  final int y0;
  final int x1;
  final int y1;
  final bool lossless;
  final double rate;
  final int levels;

  /// `[tdx, tdy, tx0, ty0]` or null for a single tile.
  final List<int>? tiles;
  final int mct;
  final String progression;
  final bool sop;
  final bool eph;

  /// `gray`, `srgb`, `sycc` or `unknown` (drives the JP2 `colr` box).
  final String colorSpace;
  final String container;
  final int seed;

  /// Set for ffmpeg-produced fixtures (the independent producer).
  final String? ffmpegPixelFormat;
  final String? ffmpegPredictor;

  /// Inserts a redundant COC + QCC for component 0 after the main-header
  /// COD/QCD, exercising the override parsers without changing the pixels.
  final bool insertCocQcc;

  String get file => '$name.$container';
  bool get isFfmpeg => ffmpegPixelFormat != null;
  int get width => x1 - x0;
  int get height => y1 - y0;
  int get bytesPerSample => precision <= 8 ? 1 : 2;

  int componentWidth(final int index) =>
      _ceilDiv(x1, components[index].dx) - _ceilDiv(x0, components[index].dx);
  int componentHeight(final int index) =>
      _ceilDiv(y1, components[index].dy) - _ceilDiv(y0, components[index].dy);

  /// Bytes of a reference-grid payload (every component at width x height).
  int get referenceGridBytes => components.length * width * height * bytesPerSample;

  int get colr => switch (container) {
    'jp2' => switch (colorSpace) {
      'gray' => 17,
      'srgb' => 16,
      'sycc' => 18,
      _ => isFfmpeg ? (components.length == 1 ? 17 : 18) : 0,
    },
    _ => 0,
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'file': file,
    'producer': isFfmpeg
        ? 'ffmpeg 9.0.2 jpeg2000 ($ffmpegPredictor, $ffmpegPixelFormat)'
        : insertCocQcc
        ? 'opj_oracle encode (libopenjp2 2.5.4) + redundant COC/QCC insertion'
        : 'opj_oracle encode (libopenjp2 2.5.4)',
    'content': isFfmpeg ? 'NASA Apollo 17 derivative (public domain)' : 'synthetic LCG',
    'container': container,
    'precision': precision,
    'x0': x0,
    'y0': y0,
    'width': width,
    'height': height,
    'components': <Object?>[
      for (var index = 0; index < components.length; index++)
        <String, Object?>{
          'dx': components[index].dx,
          'dy': components[index].dy,
          'width': componentWidth(index),
          'height': componentHeight(index),
        },
    ],
    'colr': colr == 0 ? null : colr,
    'transform': lossless ? '5/3' : '9/7',
    'lossless': lossless,
    'mct': mct,
    'tiles': tiles,
    'lanes': lanes,
  };

  /// Produces the fixture bytes, or null after recording a problem.
  Uint8List? produce(
    final String dir,
    final String oracleTool,
    final String ffmpeg,
    final List<String> problems,
  ) {
    final output = File('$dir/$file');
    final ProcessResult result;
    if (isFfmpeg) {
      result = Process.runSync(ffmpeg, <String>[
        '-y',
        '-loglevel',
        'error',
        '-i',
        'test/resources/pdf/jpeg2000/src/real-rgb128.ppm',
        '-vf',
        'scale=$width:$height:flags=lanczos',
        '-pix_fmt',
        ffmpegPixelFormat!,
        '-c:v',
        'jpeg2000',
        '-pred',
        ffmpegPredictor!,
        '-format',
        container,
        '-frames:v',
        '1',
        output.path,
      ]);
    } else {
      final spec = StringBuffer()
        ..writeln('x0=$x0')
        ..writeln('y0=$y0')
        ..writeln('x1=$x1')
        ..writeln('y1=$y1')
        ..writeln('comps=${components.length}');
      for (var index = 0; index < components.length; index++) {
        spec.writeln('comp$index=${components[index].dx},${components[index].dy},$precision');
      }
      spec
        ..writeln('colorspace=$colorSpace')
        ..writeln('lossless=${lossless ? 1 : 0}')
        ..writeln('rate=$rate')
        ..writeln('levels=$levels')
        ..writeln('tile=${tiles == null ? '0,0,0,0' : tiles!.join(',')}')
        ..writeln('mct=$mct')
        ..writeln('prog=$progression')
        ..writeln('cblk=64,64')
        ..writeln('sop=${sop ? 1 : 0}')
        ..writeln('eph=${eph ? 1 : 0}');
      final specFile = File('$dir/$name.txt')..writeAsStringSync(spec.toString());
      final samples = File('$dir/$name.bin')..writeAsBytesSync(syntheticSamples());
      result = Process.runSync(oracleTool, <String>[
        'encode',
        specFile.path,
        samples.path,
        output.path,
      ]);
    }
    if (result.exitCode != 0 || !output.existsSync()) {
      problems.add('$name: producer failed: ${result.stderr}');
      return null;
    }
    final bytes = output.readAsBytesSync();
    return insertCocQcc ? _withRedundantCocQcc(bytes) : bytes;
  }

  /// Deterministic planar samples for every component: the 8-bit corpus
  /// pattern (gradient + seeded LCG noise + hard bars) scaled to the
  /// precision for luma/gray, smoother chroma-like fields for components
  /// 1 and 2 so sYCC conversions produce varied colours and clipping.
  Uint8List syntheticSamples() {
    final out = BytesBuilder(copy: false);
    final maxValue = (1 << precision) - 1;
    final half = 1 << (precision - 1);
    var state = seed & 0x7FFFFFFF;
    for (var index = 0; index < components.length; index++) {
      final width = componentWidth(index);
      final height = componentHeight(index);
      final plane = Uint16List(width * height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
          final noise = (state >> 8) & (maxValue >> 2);
          final int value;
          if (index == 0 || mct == 1) {
            final gradient = (x * maxValue) ~/ (width > 1 ? width - 1 : 1);
            final bars = ((x ~/ 7) + (y ~/ 5)) % 11 == 0 ? 0 : maxValue;
            value =
                (gradient ~/ 2) +
                noise +
                ((bars - half) ~/ 8) +
                (maxValue >> 3) +
                index * (maxValue >> 4);
          } else if (index == 1) {
            value =
                half +
                ((y * (maxValue >> 1)) ~/ (height > 1 ? height - 1 : 1)) -
                (maxValue >> 2) +
                (noise >> 3);
          } else {
            value =
                half +
                ((x * (maxValue >> 1)) ~/ (width > 1 ? width - 1 : 1)) -
                (maxValue >> 2) -
                (noise >> 3);
          }
          plane[y * width + x] = value.clamp(0, maxValue);
        }
      }
      for (final sample in plane) {
        if (precision <= 8) {
          out.addByte(sample);
        } else {
          out.addByte(sample & 0xFF);
          out.addByte(sample >> 8);
        }
      }
    }
    return out.toBytes();
  }

  /// Cross-checks the libopenjp2 geometry against the declared spec, so
  /// the committed `corpus.json` never disagrees with the reference.
  void checkGeometry(final Map<String, Object?> geometry, final List<String> problems) {
    if (geometry['x0'] != x0 ||
        geometry['y0'] != y0 ||
        geometry['x1'] != x1 ||
        geometry['y1'] != y1) {
      problems.add(
        '$name: reference image grid ${geometry['x0']},${geometry['y0']}-${geometry['x1']},${geometry['y1']} differs from the spec',
      );
    }
    final comps = geometry['comps']! as List<Object?>;
    if (comps.length != components.length) {
      problems.add('$name: reference has ${comps.length} components, spec ${components.length}');
      return;
    }
    for (var index = 0; index < comps.length; index++) {
      final comp = comps[index]! as Map<String, Object?>;
      if (comp['dx'] != components[index].dx ||
          comp['dy'] != components[index].dy ||
          comp['w'] != componentWidth(index) ||
          comp['h'] != componentHeight(index) ||
          comp['prec'] != precision ||
          comp['sgnd'] != 0) {
        problems.add('$name: reference component $index $comp differs from the spec');
      }
    }
  }
}

/// Inserts `COC` (component 0, same parameters as COD) and `QCC`
/// (component 0, same parameters as QCD) right after the main-header QCD
/// of a single-component-coding codestream. The reference decodes the
/// result identically.
Uint8List _withRedundantCocQcc(final Uint8List bytes) {
  var cursor = 2; // Past SOC; SIZ is the first segment.
  int? codStart;
  int? codEnd;
  int? qcdStart;
  int? qcdEnd;
  while (cursor + 4 <= bytes.length) {
    final marker = (bytes[cursor] << 8) | bytes[cursor + 1];
    if (marker == 0xFF90) break; // SOT: main header done.
    final length = (bytes[cursor + 2] << 8) | bytes[cursor + 3];
    if (marker == 0xFF52) {
      codStart = cursor;
      codEnd = cursor + 2 + length;
    } else if (marker == 0xFF5C) {
      qcdStart = cursor;
      qcdEnd = cursor + 2 + length;
    }
    cursor += 2 + length;
  }
  if (codStart == null || qcdStart == null) {
    throw StateError('codestream lacks COD/QCD in the main header');
  }
  // COD body: Scod(1) SGcod(4) SPcod(5 + precincts). COC body: Ccoc(1)
  // Scoc(1) SPcoc(= SPcod).
  final scod = bytes[codStart + 4];
  final spcod = bytes.sublist(codStart + 9, codEnd);
  final coc = <int>[0xFF, 0x53, 0, 0, 0, scod & 0x01, ...spcod];
  final cocLength = coc.length - 2;
  coc[2] = cocLength >> 8;
  coc[3] = cocLength & 0xFF;
  final qcdBody = bytes.sublist(qcdStart + 4, qcdEnd);
  final qcc = <int>[0xFF, 0x5D, 0, 0, 0, ...qcdBody];
  final qccLength = qcc.length - 2;
  qcc[2] = qccLength >> 8;
  qcc[3] = qccLength & 0xFF;
  final out = BytesBuilder(copy: false)
    ..add(bytes.sublist(0, qcdEnd))
    ..add(coc)
    ..add(qcc)
    ..add(bytes.sublist(qcdEnd!));
  return out.toBytes();
}

/// The corpus. Every lossy entry has a lossless sibling with the same
/// geometry and precision.
const List<PrecisionSpec> kPrecisionMatrix = <PrecisionSpec>[
  // Grayscale precision ladder on the 1x1 grid.
  PrecisionSpec(
    name: 'synth-gray9-lossless',
    precision: 9,
    components: [ComponentSpec(1, 1)],
    x1: 64,
    y1: 48,
    colorSpace: 'gray',
    lanes: ['native'],
  ),
  PrecisionSpec(
    name: 'synth-gray10-lossless-odd',
    precision: 10,
    components: [ComponentSpec(1, 1)],
    x1: 63,
    y1: 45,
    colorSpace: 'gray',
    lanes: ['native'],
    seed: 0xA10,
  ),
  PrecisionSpec(
    name: 'synth-gray12-lossless-tiles',
    precision: 12,
    components: [ComponentSpec(1, 1)],
    x1: 100,
    y1: 67,
    tiles: [32, 32, 0, 0],
    levels: 4,
    progression: 'RLCP',
    colorSpace: 'gray',
    lanes: ['native'],
    seed: 0xBEEF,
  ),
  PrecisionSpec(
    name: 'synth-gray12-lossless-coc-qcc',
    precision: 12,
    components: [ComponentSpec(1, 1)],
    x1: 64,
    y1: 48,
    colorSpace: 'gray',
    lanes: ['native'],
    seed: 0xC0C,
    insertCocQcc: true,
  ),
  PrecisionSpec(
    name: 'synth-gray16-lossless',
    precision: 16,
    components: [ComponentSpec(1, 1)],
    x1: 64,
    y1: 48,
    colorSpace: 'gray',
    lanes: ['native'],
    seed: 0x1616,
  ),
  PrecisionSpec(
    name: 'synth-gray16-lossy',
    precision: 16,
    components: [ComponentSpec(1, 1)],
    x1: 64,
    y1: 48,
    colorSpace: 'gray',
    lanes: ['native'],
    seed: 0x1616,
    lossless: false,
    rate: 4,
  ),
  PrecisionSpec(
    name: 'synth-gray16-lossless-origin-tiles',
    precision: 16,
    components: [ComponentSpec(1, 1)],
    x0: 5,
    y0: 3,
    x1: 69,
    y1: 51,
    tiles: [32, 32, 4, 2],
    sop: true,
    eph: true,
    colorSpace: 'gray',
    lanes: ['native'],
    seed: 0x0516,
  ),
  // Subsampled grayscale: native + replication upsample.
  PrecisionSpec(
    name: 'synth-gray12-sub2x2-odd',
    precision: 12,
    components: [ComponentSpec(2, 2)],
    x1: 63,
    y1: 45,
    colorSpace: 'gray',
    lanes: ['native', 'upsample'],
    seed: 0x2212,
  ),
  PrecisionSpec(
    name: 'synth-gray16-sub2x2-odd-lossless',
    precision: 16,
    components: [ComponentSpec(2, 2)],
    x1: 63,
    y1: 45,
    colorSpace: 'gray',
    lanes: ['native', 'upsample'],
    seed: 0x2216,
  ),
  PrecisionSpec(
    name: 'synth-gray16-sub2x2-odd-lossy',
    precision: 16,
    components: [ComponentSpec(2, 2)],
    x1: 63,
    y1: 45,
    colorSpace: 'gray',
    lanes: ['native', 'upsample'],
    seed: 0x2216,
    lossless: false,
    rate: 4,
    levels: 4,
  ),
  PrecisionSpec(
    name: 'synth-gray8-sub2x1-origin',
    precision: 8,
    components: [ComponentSpec(2, 1)],
    x0: 3,
    x1: 66,
    y1: 48,
    colorSpace: 'gray',
    lanes: ['native', 'upsample'],
    seed: 0x2103,
  ),
  PrecisionSpec(
    name: 'synth-gray12-sub1x3-tiles',
    precision: 12,
    components: [ComponentSpec(1, 3)],
    x1: 64,
    y1: 50,
    tiles: [40, 24, 0, 0],
    levels: 3,
    colorSpace: 'gray',
    lanes: ['native', 'upsample'],
    seed: 0x1303,
  ),
  // RGB with component transforms on shared grids.
  PrecisionSpec(
    name: 'synth-rgb12-rct-lossless',
    precision: 12,
    components: [ComponentSpec(1, 1), ComponentSpec(1, 1), ComponentSpec(1, 1)],
    x1: 64,
    y1: 48,
    mct: 1,
    colorSpace: 'srgb',
    lanes: ['native'],
    seed: 0xFACE,
  ),
  PrecisionSpec(
    name: 'synth-rgb16-rct-lossless-odd',
    precision: 16,
    components: [ComponentSpec(1, 1), ComponentSpec(1, 1), ComponentSpec(1, 1)],
    x1: 63,
    y1: 45,
    mct: 1,
    colorSpace: 'srgb',
    lanes: ['native'],
    seed: 0xFA16,
  ),
  PrecisionSpec(
    name: 'synth-rgb16-ict-lossy-odd',
    precision: 16,
    components: [ComponentSpec(1, 1), ComponentSpec(1, 1), ComponentSpec(1, 1)],
    x1: 63,
    y1: 45,
    mct: 1,
    colorSpace: 'srgb',
    lanes: ['native'],
    seed: 0xFA16,
    lossless: false,
    rate: 6,
  ),
  PrecisionSpec(
    name: 'synth-rgb12-rct-lossless-jp2',
    precision: 12,
    components: [ComponentSpec(1, 1), ComponentSpec(1, 1), ComponentSpec(1, 1)],
    x1: 64,
    y1: 48,
    mct: 1,
    colorSpace: 'srgb',
    container: 'jp2',
    lanes: ['native'],
    seed: 0xFACE,
  ),
  // RGB with subsampling outside the sYCC rule: replication upsample.
  PrecisionSpec(
    name: 'synth-rgb8-sub-dy2',
    precision: 8,
    components: [ComponentSpec(1, 2), ComponentSpec(1, 2), ComponentSpec(1, 2)],
    x1: 64,
    y1: 48,
    colorSpace: 'srgb',
    lanes: ['native', 'upsample'],
    seed: 0xD12,
  ),
  PrecisionSpec(
    name: 'synth-rgb10-sub2x2-all',
    precision: 10,
    components: [ComponentSpec(2, 2), ComponentSpec(2, 2), ComponentSpec(2, 2)],
    x1: 64,
    y1: 48,
    colorSpace: 'srgb',
    lanes: ['native', 'upsample'],
    seed: 0xA22,
  ),
  // sYCC: native + converted RGB.
  PrecisionSpec(
    name: 'synth-sycc8-444-lossless',
    precision: 8,
    components: [ComponentSpec(1, 1), ComponentSpec(1, 1), ComponentSpec(1, 1)],
    x1: 64,
    y1: 48,
    colorSpace: 'sycc',
    container: 'jp2',
    lanes: ['native', 'rgb'],
    seed: 0x444,
  ),
  PrecisionSpec(
    name: 'synth-sycc8-420-lossless',
    precision: 8,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 2), ComponentSpec(2, 2)],
    x1: 64,
    y1: 48,
    colorSpace: 'sycc',
    container: 'jp2',
    lanes: ['native', 'rgb'],
    seed: 0x420,
  ),
  PrecisionSpec(
    name: 'synth-sycc8-420-lossless-odd',
    precision: 8,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 2), ComponentSpec(2, 2)],
    x1: 63,
    y1: 45,
    colorSpace: 'sycc',
    container: 'jp2',
    lanes: ['native', 'rgb'],
    seed: 0x421,
  ),
  PrecisionSpec(
    name: 'synth-sycc12-420-lossless-origin-tiles',
    precision: 12,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 2), ComponentSpec(2, 2)],
    x0: 1,
    y0: 1,
    x1: 64,
    y1: 46,
    tiles: [32, 32, 0, 0],
    levels: 3,
    progression: 'RLCP',
    sop: true,
    eph: true,
    colorSpace: 'sycc',
    container: 'jp2',
    lanes: ['native', 'rgb'],
    seed: 0x1212,
  ),
  PrecisionSpec(
    name: 'synth-sycc10-422-lossless-odd',
    precision: 10,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 1), ComponentSpec(2, 1)],
    x1: 63,
    y1: 45,
    colorSpace: 'sycc',
    container: 'jp2',
    lanes: ['native', 'rgb'],
    seed: 0x422,
  ),
  PrecisionSpec(
    name: 'synth-sycc8-422-lossless-origin',
    precision: 8,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 1), ComponentSpec(2, 1)],
    x0: 1,
    x1: 64,
    y1: 48,
    colorSpace: 'sycc',
    container: 'jp2',
    lanes: ['native', 'rgb'],
    seed: 0x4221,
  ),
  PrecisionSpec(
    name: 'synth-sycc16-420-lossless',
    precision: 16,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 2), ComponentSpec(2, 2)],
    x1: 64,
    y1: 48,
    colorSpace: 'sycc',
    container: 'jp2',
    lanes: ['native', 'rgb'],
    seed: 0x1620,
  ),
  PrecisionSpec(
    name: 'synth-sycc16-420-lossy',
    precision: 16,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 2), ComponentSpec(2, 2)],
    x1: 64,
    y1: 48,
    colorSpace: 'sycc',
    container: 'jp2',
    lanes: ['native', 'rgb'],
    seed: 0x1620,
    lossless: false,
    rate: 4,
  ),
  // Bare codestream with the 4:2:0 layout: the opj_decompress sYCC rule.
  PrecisionSpec(
    name: 'synth-3comp-420-bare-lossless',
    precision: 8,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 2), ComponentSpec(2, 2)],
    x1: 64,
    y1: 48,
    colorSpace: 'unknown',
    lanes: ['native', 'rgb'],
    seed: 0xBA20,
  ),
  // Independent producer (ffmpeg) over the public-domain photograph.
  PrecisionSpec(
    name: 'real-gray16-lossless-ffmpeg',
    precision: 16,
    components: [ComponentSpec(1, 1)],
    x1: 64,
    y1: 48,
    lanes: ['native'],
    ffmpegPixelFormat: 'gray16be',
    ffmpegPredictor: 'dwt53',
  ),
  PrecisionSpec(
    name: 'real-rgb16-lossless-ffmpeg',
    precision: 16,
    components: [ComponentSpec(1, 1), ComponentSpec(1, 1), ComponentSpec(1, 1)],
    x1: 64,
    y1: 48,
    lanes: ['native'],
    ffmpegPixelFormat: 'rgb48be',
    ffmpegPredictor: 'dwt53',
  ),
  PrecisionSpec(
    name: 'real-sycc8-420-lossless-odd-ffmpeg',
    precision: 8,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 2), ComponentSpec(2, 2)],
    x1: 63,
    y1: 45,
    container: 'jp2',
    lanes: ['native', 'rgb'],
    ffmpegPixelFormat: 'yuv420p',
    ffmpegPredictor: 'dwt53',
  ),
  PrecisionSpec(
    name: 'real-sycc8-422-lossless-ffmpeg',
    precision: 8,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 1), ComponentSpec(2, 1)],
    x1: 64,
    y1: 48,
    container: 'jp2',
    lanes: ['native', 'rgb'],
    ffmpegPixelFormat: 'yuv422p',
    ffmpegPredictor: 'dwt53',
  ),
  PrecisionSpec(
    name: 'real-sycc10-420-lossless-ffmpeg',
    precision: 10,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 2), ComponentSpec(2, 2)],
    x1: 64,
    y1: 48,
    container: 'jp2',
    lanes: ['native', 'rgb'],
    ffmpegPixelFormat: 'yuv420p10be',
    ffmpegPredictor: 'dwt53',
  ),
  PrecisionSpec(
    name: 'real-sycc12-420-lossless-ffmpeg',
    precision: 12,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 2), ComponentSpec(2, 2)],
    x1: 64,
    y1: 48,
    container: 'jp2',
    lanes: ['native', 'rgb'],
    ffmpegPixelFormat: 'yuv420p12be',
    ffmpegPredictor: 'dwt53',
  ),
  PrecisionSpec(
    name: 'real-sycc12-420-lossy-ffmpeg',
    precision: 12,
    components: [ComponentSpec(1, 1), ComponentSpec(2, 2), ComponentSpec(2, 2)],
    x1: 64,
    y1: 48,
    container: 'jp2',
    lanes: ['native', 'rgb'],
    ffmpegPixelFormat: 'yuv420p12be',
    ffmpegPredictor: 'dwt97int',
    lossless: false,
  ),
];

String _manifest(final Map<String, String> hashes) {
  final buffer = StringBuffer()
    ..writeln('# JPEG 2000 precision and subsampling fixtures')
    ..writeln()
    ..writeln('Generated and verified by `tool/generate_jpx_precision_fixtures.dart`;')
    ..writeln('the contract and comparison protocol are in `doc/jpeg2000-precision.md`.')
    ..writeln('`corpus.json` lists every fixture with its declared geometry, producer and')
    ..writeln('comparison lanes; `tolerances.json` carries the lossy ceilings fixed before')
    ..writeln('any Dart decode.')
    ..writeln()
    ..writeln('Reference: OpenJPEG `openjp2` 2.5.4 (Homebrew 2.5.4_1; upstream tag `v2.5.4`,')
    ..writeln('commit `6c4a29b00211eb0430fa0e5e890f1ce5c80f409f`, BSD-2-Clause, see')
    ..writeln('`licenses/openjpeg-LICENSE`). `oracle/*.native.*` come from')
    ..writeln('`tool/jpx_oracle/opj_oracle dump` (the library, no post-processing);')
    ..writeln('`oracle/*.upsample.rawl` and `oracle/*.rgb.rawl` from `opj_decompress`')
    ..writeln('(`-upsample`, and the sYCC conversion of its `color.c`).')
    ..writeln()
    ..writeln('Producers: `synth-*` are encoded by `opj_oracle encode` (libopenjp2 2.5.4')
    ..writeln('through its public API) from the seeded synthetic pattern; `real-*` are')
    ..writeln('encoded by the independent ffmpeg 9.0.2 native `jpeg2000` encoder (GPL')
    ..writeln('build, used as a development tool only, no code shipped) from')
    ..writeln('`../src/real-rgb128.ppm`, the public-domain NASA photograph "The Earth seen')
    ..writeln('from Apollo 17" derivative documented in `../MANIFEST.md`.')
    ..writeln()
    ..writeln('Payload layout (`.bin` and `.rawl`): components in order, row-major, one')
    ..writeln('byte per sample up to 8 bits and two little-endian bytes above.')
    ..writeln()
    ..writeln('## Matrix')
    ..writeln()
    ..writeln('| Fixture | Precision | Grid | Components (dx,dy) | Transform | Lanes |')
    ..writeln('| --- | --- | --- | --- | --- | --- |');
  for (final spec in kPrecisionMatrix) {
    final comps = spec.components.map((final c) => '${c.dx},${c.dy}').join(' ');
    final grid =
        '${spec.width}x${spec.height} @${spec.x0},${spec.y0}${spec.tiles == null ? '' : ' tiles ${spec.tiles![0]}x${spec.tiles![1]}'}';
    buffer.writeln(
      '| `${spec.file}` | ${spec.precision} | $grid | $comps | ${spec.lossless ? '5/3 lossless' : '9/7 lossy'}${spec.mct == 1 ? ' + MCT' : ''}${spec.colr == 0 ? '' : ' colr ${spec.colr}'} | ${spec.lanes.join(', ')} |',
    );
  }
  buffer
    ..writeln()
    ..writeln('## Hashes')
    ..writeln()
    ..writeln('SHA-256 of every committed file:')
    ..writeln()
    ..writeln('```');
  final names = hashes.keys.toList()..sort();
  for (final name in names) {
    buffer.writeln('${hashes[name]}  $name');
  }
  buffer.writeln('```');
  return buffer.toString();
}

String _sha256(final List<int> bytes) => sha256.convert(bytes).toString();

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
  final committed = file.readAsBytesSync();
  if (committed.length != bytes.length) {
    problems.add('${file.path}: $kind differs from the generator (size)');
    return;
  }
  for (var index = 0; index < bytes.length; index++) {
    if (committed[index] != bytes[index]) {
      problems.add('${file.path}: $kind differs from the generator (byte $index)');
      return;
    }
  }
}

void _checkOrWriteText(
  final File file,
  final String text,
  final bool write,
  final String kind,
  final List<String> problems,
) {
  if (write) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
    return;
  }
  if (!file.existsSync()) {
    problems.add('${file.path}: missing $kind (rerun with --write)');
    return;
  }
  if (file.readAsStringSync() != text) {
    problems.add('${file.path}: $kind differs from the generator');
  }
}
