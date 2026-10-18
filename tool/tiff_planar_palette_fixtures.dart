/// Builds the planar/palette TIFF fixture corpus under
/// `test/resources/tiff/planar-palette/`.
///
/// `dart run tool/tiff_planar_palette_fixtures.dart generate [--pics=DIR]`
/// writes deterministic source images (via `tool/tiff_fixtures.dart`),
/// copies the independent libtiff `pics-3.8.0` files when a directory is
/// given, derives every tracked fixture with libtiff 4.7.2 (`tiffcp -p
/// separate` and `tool/reference/tiff_oracle_encode` for the layouts
/// `tiffcp` cannot write), regenerates
/// `test/support/tiff_planar_palette_embedded.dart` for the browser lane,
/// and rewrites `test/resources/tiff/planar-palette/manifest.json` with
/// the SHA-256, producer, arguments, and expected outcome of every file.
///
/// `dart run tool/tiff_planar_palette_fixtures.dart check` verifies that
/// every tracked file still matches the manifest.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'tiff_fixtures.dart' show buildUncompressedTiff, grayGradient, rgbGradient;

const planarPaletteDir = 'test/resources/tiff/planar-palette';
const manifestPath = '$planarPaletteDir/manifest.json';
const embeddedPath = 'test/support/tiff_planar_palette_embedded.dart';
const stagingDir = 'build/tiff-planar-palette-fixtures/sources';
const encoderBinary = 'build/oracle/tiff_oracle_encode';
const encoderSource = 'tool/reference/tiff_oracle_encode/tiff_oracle_encode.c';

String get tiffcp => Platform.environment['TIFFCP_PATH'] ?? '/opt/homebrew/bin/tiffcp';

/// The independent files copied verbatim from libtiff's `pics-3.8.0`
/// set (SGI / GraphicsMagick written, not libtiff).
const independentFiles = <String, (String, String)>{
  'flower-rgb-planar-08.tif': (
    'compare',
    'RGB 8-bit planar 2, none, 73x43 strips of 112 rows (real GraphicsMagick file)',
  ),
  'flower-rgb-planar-16.tif': (
    'compare-native',
    'RGB 16-bit planar 2, none, 73x43 (real GraphicsMagick file; libtiff rounds the RGBA lane)',
  ),
  'jello.tif': (
    'compare',
    'palette 8-bit PackBits, 256x192, real SGI-written file with full-range ColorMap',
  ),
  'flower-palette-02.tif': ('compare', 'palette 2-bit none, 73x43 (real file)'),
  'flower-palette-04.tif': ('compare', 'palette 4-bit none, 73x43 (real file)'),
  'flower-palette-08.tif': ('compare', 'palette 8-bit none, 73x43 (real file)'),
  'flower-palette-16.tif': (
    'reject:TiffUnsupportedCodecException',
    'palette 16-bit (typed rejection: outside the palette recorte)',
  ),
  'flower-rgb-planar-02.tif': (
    'reject:TiffException',
    'RGB planar 2-bit (typed rejection: sub-byte RGB samples)',
  ),
  'flower-rgb-planar-04.tif': (
    'reject:TiffException',
    'RGB planar 4-bit (typed rejection: sub-byte RGB samples)',
  ),
  'flower-separated-planar-08.tif': (
    'reject:TiffUnsupportedCodecException',
    'separated (photometric 5) planar 8-bit (typed rejection)',
  ),
  'flower-separated-planar-16.tif': (
    'reject:TiffUnsupportedCodecException',
    'separated (photometric 5) planar 16-bit (typed rejection)',
  ),
};

/// Cross-corpus files the reference stage reads from the strip corpus.
const stripCorpusFiles = <String, (String, String)>{
  'palette-1c-8b.tiff': (
    'compare',
    'strip-corpus palette 8-bit none, 157x151, Page Number 0-1 (decodes since D03)',
  ),
  'minisblack-2c-8b-alpha.tiff': (
    'reject:TiffUnsupportedCodecException',
    'strip-corpus planar 2 with ExtraSamples (alpha stays outside the recorte)',
  ),
};

/// The fixtures embedded for the browser lane (small files only).
const embeddedFixtures = <String>[
  'palette1-none-strips-be.tif',
  'palette4-t16.tif',
  'palette8-enc-strips.tif',
  'palette8-legacy8bit.tif',
  'planar8-none-t16-le.tif',
  'planar8-zip2-t16-big.tif',
  'planar16-zip2-t16.tif',
  'planar8-o2-t16.tif',
  'mixed-planar-palette-3page.tif',
  'flower-rgb-planar-08.tif',
  'flower-palette-02.tif',
];

final class _Derived {
  const _Derived(this.name, this.source, this.tool, this.arguments, this.expectation, this.layout);

  final String name;
  final String source;
  final String tool;
  final List<String> arguments;
  final String expectation;
  final String layout;
}

Future<void> main(final List<String> arguments) async {
  final mode = arguments.isEmpty ? 'generate' : arguments.first;
  String? pics;
  for (final argument in arguments) {
    if (argument.startsWith('--pics=')) pics = argument.substring(7);
  }
  if (mode == 'generate') {
    await _generate(pics);
  } else if (mode == 'check') {
    exitCode = _check() ? 0 : 1;
  } else {
    stderr.writeln(
      'usage: dart run tool/tiff_planar_palette_fixtures.dart [generate [--pics=DIR]|check]',
    );
    exitCode = 64;
  }
}

// ---------------------------------------------------------------------------
// Sources
// ---------------------------------------------------------------------------

Uint8List _rgb16Ramp(final int width, final int height) {
  final pixels = Uint8List(width * height * 6);
  final view = ByteData.sublistView(pixels);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final base = (y * width + x) * 6;
      view.setUint16(base, (x * 1021 + y * 7) & 0xFFFF, Endian.little);
      view.setUint16(base + 2, (x * 13 + y * 997) & 0xFFFF, Endian.little);
      view.setUint16(base + 4, (x * y * 31 + 5) & 0xFFFF, Endian.little);
    }
  }
  return pixels;
}

/// Packs `bits`-bit gray samples (1, 2, or 4) MSB first.
Uint8List _packedGray(
  final int width,
  final int height,
  final int bits,
  final int Function(int, int) sample,
) {
  final rowBytes = (width * bits + 7) ~/ 8;
  final pixels = Uint8List(rowBytes * height);
  final perByte = 8 ~/ bits;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final shift = 8 - bits - (x % perByte) * bits;
      pixels[y * rowBytes + x ~/ perByte] |= (sample(x, y) & ((1 << bits) - 1)) << shift;
    }
  }
  return pixels;
}

Map<String, Uint8List> _sources() => {
  'rgb8-100x75.tif': buildUncompressedTiff(
    width: 100,
    height: 75,
    bitsPerSample: 8,
    samplesPerPixel: 3,
    photometric: 2,
    pixels: rgbGradient(100, 75),
  ),
  'rgb8-96x64.tif': buildUncompressedTiff(
    width: 96,
    height: 64,
    bitsPerSample: 8,
    samplesPerPixel: 3,
    photometric: 2,
    pixels: rgbGradient(96, 64),
  ),
  'rgb16-48x40.tif': buildUncompressedTiff(
    width: 48,
    height: 40,
    bitsPerSample: 16,
    samplesPerPixel: 3,
    photometric: 2,
    pixels: _rgb16Ramp(48, 40),
  ),
  'gray8-96x64.tif': buildUncompressedTiff(
    width: 96,
    height: 64,
    bitsPerSample: 8,
    samplesPerPixel: 1,
    photometric: 1,
    pixels: grayGradient(96, 64),
  ),
  'gray4-100x75.tif': buildUncompressedTiff(
    width: 100,
    height: 75,
    bitsPerSample: 4,
    samplesPerPixel: 1,
    photometric: 1,
    pixels: _packedGray(100, 75, 4, (final x, final y) => x * 3 + y * 5),
  ),
  'gray2-100x75.tif': buildUncompressedTiff(
    width: 100,
    height: 75,
    bitsPerSample: 2,
    samplesPerPixel: 1,
    photometric: 1,
    pixels: _packedGray(100, 75, 2, (final x, final y) => x + y),
  ),
  'bilevel-128x96.tif': buildUncompressedTiff(
    width: 128,
    height: 96,
    bitsPerSample: 1,
    samplesPerPixel: 1,
    photometric: 0,
    pixels: _packedGray(128, 96, 1, (final x, final y) => (x ~/ 8 + y ~/ 8) & 1),
  ),
};

// ---------------------------------------------------------------------------
// Derivations
// ---------------------------------------------------------------------------

List<_Derived> _derivations() {
  const compare = 'compare';
  const compareNative = 'compare-native';
  const unsupported = 'reject:TiffUnsupportedCodecException';
  _Derived cp(
    final String name,
    final String source,
    final List<String> args,
    final String layout, [
    final String expectation = compare,
  ]) => _Derived(name, source, 'tiffcp', args, expectation, layout);
  _Derived enc(
    final String name,
    final String source,
    final List<String> args,
    final String layout, [
    final String expectation = compare,
  ]) => _Derived(name, source, 'tiff_oracle_encode', args, expectation, layout);
  return [
    // Planar 8-bit: strips, tiles, byte orders, BigTIFF, codecs, predictors.
    cp('planar8-none-strips.tif', 'rgb8-96x64.tif', [
      '-p',
      'separate',
      '-c',
      'none',
    ], 'RGB8 planar 2 none, whole-image strips'),
    cp('planar8-none-t16-le.tif', 'rgb8-100x75.tif', [
      '-p',
      'separate',
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'none',
    ], 'RGB8 planar 2 none 16x16 tiles LE (edge tiles)'),
    cp('planar8-packbits-t32-be.tif', 'rgb8-100x75.tif', [
      '-p',
      'separate',
      '-B',
      '-t',
      '-w',
      '32',
      '-l',
      '32',
      '-c',
      'packbits',
    ], 'RGB8 planar 2 PackBits 32x32 BE'),
    cp('planar8-zip2-t16-big.tif', 'rgb8-100x75.tif', [
      '-p',
      'separate',
      '-8',
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'zip:2',
    ], 'RGB8 planar 2 Deflate predictor 2 16x16 BigTIFF (stride-1 differencing)'),
    cp('planar8-lzw2-strips.tif', 'rgb-lzw-predictor.tif', [
      '-p',
      'separate',
      '-c',
      'lzw:2',
    ], 'RGB8 planar 2 LZW predictor 2 strips (from the strip corpus)'),
    cp('planar8-rows8.tif', 'rgb8-96x64.tif', [
      '-p',
      'separate',
      '-r',
      '8',
      '-c',
      'none',
    ], 'RGB8 planar 2 none, strips of 8 rows'),
    // Planar 16-bit: tiffcp refuses contig->separate conversion above
    // 8 bits ("Cannot handle different planar configuration w/
    // bits/sample != 8"), so the encoder writes these planes directly.
    // Byte order and predictor carries matter per plane.
    enc(
      'planar16-none-strips.tif',
      'rgb16-48x40.tif',
      ['--planar', '--compression', 'none'],
      'RGB16 planar 2 none strips',
      compareNative,
    ),
    enc(
      'planar16-zip2-t16.tif',
      'rgb16-48x40.tif',
      ['--planar', '--tile', '16x16', '--compression', 'zip', '--predictor', '2'],
      'RGB16 planar 2 Deflate predictor 2 16x16',
      compareNative,
    ),
    enc(
      'planar16-lzw-t32-be.tif',
      'rgb16-48x40.tif',
      ['--planar', '--tile', '32x32', '--compression', 'lzw', '--big-endian'],
      'RGB16 planar 2 LZW 32x32 BE',
      compareNative,
    ),
    // Planar from the independent sources.
    cp('quad-planar-zip2-t64-big-be.tif', 'quad-tile.tif', [
      '-p',
      'separate',
      '-8',
      '-B',
      '-t',
      '-w',
      '64',
      '-l',
      '64',
      '-c',
      'zip:2',
    ], 'quad RGB8 planar 2 Deflate predictor 2 64x64 BigTIFF BE, SampleFormat 4'),
    cp('flower-planar-none-t32-be.tif', 'flower-rgb-planar-08.tif', [
      '-p',
      'separate',
      '-B',
      '-t',
      '-w',
      '32',
      '-l',
      '32',
      '-c',
      'none',
    ], 'flower RGB8 planar 2 none 32x32 BE'),
    cp(
      'flower-planar16-zip2-t16.tif',
      'flower-rgb-planar-16.tif',
      ['-p', 'separate', '-t', '-w', '16', '-l', '16', '-c', 'zip:2'],
      'flower RGB16 planar 2 Deflate predictor 2 16x16',
      compareNative,
    ),
    // Planar orientations via the encoder (tiffcp drops Orientation).
    enc('planar8-o2-t16.tif', 'rgb8-100x75.tif', [
      '--planar',
      '--tile',
      '16x16',
      '--compression',
      'lzw',
      '--orientation',
      '2',
    ], 'RGB8 planar 2 LZW 16x16, Orientation 2'),
    enc(
      'planar16-o3-strips-big-be.tif',
      'rgb16-48x40.tif',
      ['--planar', '--compression', 'none', '--orientation', '3', '--bigtiff', '--big-endian'],
      'RGB16 planar 2 none, Orientation 3, BigTIFF BE',
      compareNative,
    ),
    // Palette derivations from the real palette sources.
    cp('palette8-none-t16-le.tif', 'palette-1c-8b.tiff', [
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'none',
    ], 'palette 8-bit none 16x16 tiles LE (from the strip corpus)'),
    cp('palette8-packbits-strips-be.tif', 'palette-1c-8b.tiff', [
      '-B',
      '-c',
      'packbits',
    ], 'palette 8-bit PackBits strips BE'),
    cp('palette8-zip-t16-big.tif', 'palette-1c-8b.tiff', [
      '-8',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'zip',
    ], 'palette 8-bit Deflate 16x16 BigTIFF'),
    cp(
      'palette8-lzw2-reject.tif',
      'palette-1c-8b.tiff',
      ['-c', 'lzw:2'],
      'palette 8-bit LZW predictor 2 (typed rejection: differencing on indices)',
      unsupported,
    ),
    cp('jello-zip-t32-be.tif', 'jello.tif', [
      '-B',
      '-t',
      '-w',
      '32',
      '-l',
      '32',
      '-c',
      'zip',
    ], 'jello palette 8-bit Deflate 32x32 BE'),
    cp('palette4-t16.tif', 'flower-palette-04.tif', [
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'lzw',
    ], 'flower palette 4-bit LZW 16x16'),
    cp('palette2-packbits-strips.tif', 'flower-palette-02.tif', [
      '-c',
      'packbits',
    ], 'flower palette 2-bit PackBits strips'),
    // Synthesized palettes through the encoder (fixed full-range ramp,
    // plus the legacy byte-range colormap variant).
    enc('palette1-none-strips-be.tif', 'miniswhite-1c-1b.tiff', [
      '--palette-bits',
      '1',
      '--compression',
      'none',
      '--big-endian',
    ], 'bilevel converted to a 1-bit palette with the fixed ramp, BE'),
    enc('palette4-enc-strips.tif', 'gray4-100x75.tif', [
      '--palette-bits',
      '4',
      '--compression',
      'packbits',
    ], 'gray4 indices converted to a 4-bit palette'),
    enc('palette2-enc-strips-be.tif', 'gray2-100x75.tif', [
      '--palette-bits',
      '2',
      '--compression',
      'lzw',
      '--big-endian',
    ], 'gray2 indices converted to a 2-bit palette, BE'),
    enc('palette8-enc-strips.tif', 'gray8-96x64.tif', [
      '--palette-bits',
      '8',
      '--compression',
      'zip',
    ], 'gray8 converted to an 8-bit full-range palette'),
    enc('palette8-legacy8bit.tif', 'gray8-96x64.tif', [
      '--palette-bits',
      '8',
      '--legacy-cmap',
      '--compression',
      'packbits',
    ], 'gray8 converted with a byte-range (legacy 8-bit) ColorMap'),
    enc('palette8-o4-t32.tif', 'gray8-96x64.tif', [
      '--palette-bits',
      '8',
      '--tile',
      '32x32',
      '--compression',
      'lzw',
      '--orientation',
      '4',
    ], 'palette 8-bit LZW 32x32, Orientation 4'),
  ];
}

/// Multi-IFD files concatenated from single-page outputs; tiffcp keeps
/// each input's layout when neither -s nor -t is given.
List<(String, List<String>, List<String>, String, String)> _concatenations() => [
  (
    'mixed-planar-palette-3page.tif',
    <String>[],
    ['rgb-lzw-predictor.tif', 'planar8-none-strips.tif', 'palette8-packbits-strips-be.tif'],
    'page 1 RGB8 contig LZW predictor 2, page 2 RGB8 planar none, page 3 palette PackBits',
    'compare',
  ),
  (
    'mixed-planar-big-be-2page.tif',
    ['-8', '-B'],
    ['planar16-none-strips.tif', 'palette8-zip-t16-big.tif'],
    'BigTIFF BE: page 1 RGB16 planar none (RGBA lane rounds), page 2 palette Deflate tiles',
    'compare-native',
  ),
];

// ---------------------------------------------------------------------------
// generate
// ---------------------------------------------------------------------------

Future<void> _generate(final String? pics) async {
  _requireTool(tiffcp, ['-h']);
  _buildEncoder();
  Directory(stagingDir).createSync(recursive: true);
  Directory(planarPaletteDir).createSync(recursive: true);

  final entries = <Map<String, Object?>>[];
  if (pics != null) {
    for (final name in independentFiles.keys) {
      final source = File('$pics/depth/$name').existsSync() ? '$pics/depth/$name' : '$pics/$name';
      File(source).copySync('$planarPaletteDir/$name');
    }
  }
  for (final name in independentFiles.keys) {
    final file = File('$planarPaletteDir/$name');
    if (!file.existsSync()) {
      throw StateError('$name is missing; pass --pics=<dir> with the extracted pics-3.8.0.');
    }
    final (expectation, layout) = independentFiles[name]!;
    entries.add(
      _entry(name, 'libtiffpic pics-3.8.0 (independent)', const <String>[], expectation, layout),
    );
  }

  final sources = _sources();
  sources.forEach((final name, final bytes) => File('$stagingDir/$name').writeAsBytesSync(bytes));
  // Derivation inputs from the tracked corpora.
  final derivationInputs = <(String, String)>{
    ('tiled/quad-tile.tif', 'quad-tile.tif'),
    ('rgb-lzw-predictor.tif', 'rgb-lzw-predictor.tif'),
    ('palette-1c-8b.tiff', 'palette-1c-8b.tiff'),
    ('miniswhite-1c-1b.tiff', 'miniswhite-1c-1b.tiff'),
  };
  for (final (tracked, staged) in derivationInputs) {
    File('test/resources/tiff/$tracked').copySync('$stagingDir/$staged');
  }
  File('$planarPaletteDir/jello.tif').copySync('$stagingDir/jello.tif');
  File(
    '$planarPaletteDir/flower-rgb-planar-08.tif',
  ).copySync('$stagingDir/flower-rgb-planar-08.tif');
  File(
    '$planarPaletteDir/flower-rgb-planar-16.tif',
  ).copySync('$stagingDir/flower-rgb-planar-16.tif');
  File('$planarPaletteDir/flower-palette-04.tif').copySync('$stagingDir/flower-palette-04.tif');
  File('$planarPaletteDir/flower-palette-02.tif').copySync('$stagingDir/flower-palette-02.tif');

  for (final derived in _derivations()) {
    final output = '$planarPaletteDir/${derived.name}';
    final input = '$stagingDir/${derived.source}';
    final List<String> argv;
    if (derived.tool == 'tiffcp') {
      argv = [tiffcp, ...derived.arguments, input, output];
    } else {
      argv = [encoderBinary, input, output, ...derived.arguments];
    }
    _runOrThrow(argv);
    entries.add(
      _entry(
        derived.name,
        '${derived.tool} (libtiff 4.7.2) from ${derived.source}',
        derived.arguments,
        derived.expectation,
        derived.layout,
      ),
    );
    // Single-page outputs double as inputs for the multi-IFD files.
    File(output).copySync('$stagingDir/${derived.name}');
  }
  for (final (name, options, inputs, layout, expectation) in _concatenations()) {
    final argv = [
      tiffcp,
      ...options,
      ...inputs.map((final input) => '$stagingDir/$input'),
      '$planarPaletteDir/$name',
    ];
    _runOrThrow(argv);
    entries.add(
      _entry(
        name,
        'tiffcp (libtiff 4.7.2) concatenating ${inputs.join(', ')}',
        options,
        expectation,
        layout,
      ),
    );
  }

  entries.sort((final a, final b) => (a['name']! as String).compareTo(b['name']! as String));
  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'tiff-planar-palette-corpus',
    'libtiff': '4.7.2',
    'files': entries,
  };
  File(manifestPath).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(manifest)}\n');
  _writeEmbedded();
  stdout.writeln('wrote ${entries.length} entries to $manifestPath');
}

Map<String, Object?> _entry(
  final String name,
  final String producer,
  final List<String> arguments,
  final String expectation,
  final String layout,
) {
  final bytes = File('$planarPaletteDir/$name').readAsBytesSync();
  return {
    'name': name,
    'bytes': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
    'producer': producer,
    if (arguments.isNotEmpty) 'arguments': arguments,
    'expectation': expectation,
    'layout': layout,
  };
}

void _writeEmbedded() {
  final buffer = StringBuffer()
    ..writeln('// Generated by tool/tiff_planar_palette_fixtures.dart; do not edit.')
    ..writeln('//')
    ..writeln('// Small planar/palette fixtures embedded for the browser lane,')
    ..writeln('// where tests cannot read test/resources from disk. Bytes are')
    ..writeln('// identical to the tracked files of the same name under')
    ..writeln('// test/resources/tiff/planar-palette/.')
    ..writeln("import 'dart:convert';")
    ..writeln("import 'dart:typed_data';")
    ..writeln()
    ..writeln('/// The embedded planar/palette fixtures by file name.')
    ..writeln('final Map<String, Uint8List> embeddedPlanarPaletteFixtures = <String, Uint8List>{');
  for (final name in embeddedFixtures) {
    final encoded = base64.encode(File('$planarPaletteDir/$name').readAsBytesSync());
    buffer.writeln("  '$name': base64.decode(");
    for (var index = 0; index < encoded.length; index += 76) {
      final end = index + 76 < encoded.length ? index + 76 : encoded.length;
      buffer.writeln("    '${encoded.substring(index, end)}'");
    }
    buffer.writeln('  ),');
  }
  buffer.writeln('};');
  File(embeddedPath).writeAsStringSync(buffer.toString());
}

// ---------------------------------------------------------------------------
// check
// ---------------------------------------------------------------------------

bool _check() {
  final manifest = json.decode(File(manifestPath).readAsStringSync()) as Map<String, Object?>;
  var ok = true;
  for (final entry in (manifest['files']! as List).cast<Map<String, Object?>>()) {
    final name = entry['name']! as String;
    final file = File('$planarPaletteDir/$name');
    if (!file.existsSync()) {
      stdout.writeln('missing: $name');
      ok = false;
      continue;
    }
    final digest = sha256.convert(file.readAsBytesSync()).toString();
    if (digest != entry['sha256']) {
      stdout.writeln('hash mismatch: $name');
      ok = false;
    }
  }
  stdout.writeln(
    ok ? 'planar/palette corpus matches its manifest' : 'planar/palette corpus drifted',
  );
  return ok;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

void _requireTool(final String executable, final List<String> probe) {
  final result = Process.runSync(executable, probe);
  if (result.exitCode != 0 && result.exitCode != 1 && result.exitCode != 2) {
    throw StateError('$executable is required to regenerate the planar/palette corpus.');
  }
}

void _buildEncoder() {
  Directory('build/oracle').createSync(recursive: true);
  _runOrThrow([
    'cc',
    '-O2',
    '-o',
    encoderBinary,
    encoderSource,
    '-I/opt/homebrew/include',
    '-L/opt/homebrew/lib',
    '-ltiff',
  ]);
}

void _runOrThrow(final List<String> argv) {
  final result = Process.runSync(argv.first, argv.sublist(1));
  if (result.exitCode != 0) {
    stderr.write(result.stdout);
    stderr.write(result.stderr);
    throw StateError('command failed: ${argv.join(' ')}');
  }
}
