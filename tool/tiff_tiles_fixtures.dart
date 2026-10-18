/// Builds the tiled TIFF fixture corpus under `test/resources/tiff/tiled/`.
///
/// `dart run tool/tiff_tiles_fixtures.dart generate [--libtiffpic=<dir>]`
/// writes deterministic source images (this repository's patterns, via
/// `tool/tiff_fixtures.dart`), derives every tracked tiled fixture with
/// libtiff 4.7.2 (`tiffcp`, and `tool/reference/tiff_oracle_encode` for
/// the layouts `tiffcp` cannot write), copies the independent
/// `libtiffpic` files when a directory is given, regenerates
/// `test/support/tiff_tiled_embedded.dart` for the browser lane, and
/// rewrites `test/resources/tiff/tiled/manifest.json` with the SHA-256,
/// producer, arguments, and expected outcome of every file.
///
/// `dart run tool/tiff_tiles_fixtures.dart check` verifies that every
/// tracked file still matches the manifest.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'tiff_fixtures.dart'
    show buildUncompressedTiff, gray16Ramp, grayGradient, rgbGradient, textPage;

const tiledDir = 'test/resources/tiff/tiled';
const manifestPath = '$tiledDir/manifest.json';
const embeddedPath = 'test/support/tiff_tiled_embedded.dart';
const stagingDir = 'build/tiff-tiles-fixtures/sources';
const encoderBinary = 'build/oracle/tiff_oracle_encode';
const encoderSource = 'tool/reference/tiff_oracle_encode/tiff_oracle_encode.c';

String get tiffcp => Platform.environment['TIFFCP_PATH'] ?? '/opt/homebrew/bin/tiffcp';

/// The independent files copied verbatim from libtiff's `pics-3.8.0`
/// set (written by the Silicon Graphics Image Library, not libtiff).
const independentFiles = <String, (String, String)>{
  'cramps-tile.tif': (
    'compare',
    'SGI Image Library; gray 8-bit min-is-white, uncompressed, 800x607 in 256x256 tiles '
        'addressed by StripOffsets/StripByteCounts (edge tiles on both axes)',
  ),
  'quad-tile.tif': (
    'compare',
    'SGI Image Library; RGB 8-bit LZW, 512x384 in 128x128 tiles addressed by '
        'StripOffsets/StripByteCounts',
  ),
  'zackthecat.tif': (
    'reject:TiffUnsupportedCodecException',
    'tiled old-style JPEG YCbCr 234x213 (typed rejection)',
  ),
  'cramps.tif': ('compare', 'strip PackBits twin of cramps-tile.tif, gray 8-bit 800x607'),
  'ladoga.tif': ('compare', 'gray 16-bit Deflate strips 158x118 (real 16-bit source)'),
  'fax2d.tif': (
    'reject:TiffUnsupportedCodecException',
    'Group 3 2D bilevel 1728x1082 with FillOrder 2 (typed rejection; derivation source)',
  ),
};

/// The fixtures embedded for the browser lane (small files only).
const embeddedFixtures = <String>[
  'gray8-lzw2-t32-be.tif',
  'rgb8-zip2-t32-big-be.tif',
  'bilevel-g4-t32x16.tif',
  'bilevel-mh-t32x16.tif',
  'gray16-zip2-t16-big-be.tif',
  'gray8-o3-t16.tif',
  'mixed-strip-tile-3page.tif',
  'gray8-tiny-7x5-t16.tif',
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
  String? libtiffpic;
  for (final argument in arguments) {
    if (argument.startsWith('--libtiffpic=')) libtiffpic = argument.substring(13);
  }
  if (mode == 'generate') {
    await _generate(libtiffpic);
  } else if (mode == 'check') {
    exitCode = _check() ? 0 : 1;
  } else {
    stderr.writeln(
      'usage: dart run tool/tiff_tiles_fixtures.dart [generate [--libtiffpic=DIR]|check]',
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

Map<String, Uint8List> _sources() {
  Uint8List gray(final int width, final int height, {final int shift = 0}) => buildUncompressedTiff(
    width: width,
    height: height,
    bitsPerSample: 8,
    samplesPerPixel: 1,
    photometric: 1,
    pixels: grayGradient(width, height, shift: shift),
  );
  Uint8List rgb(final int width, final int height, {final int shift = 0}) => buildUncompressedTiff(
    width: width,
    height: height,
    bitsPerSample: 8,
    samplesPerPixel: 3,
    photometric: 2,
    pixels: rgbGradient(width, height, shift: shift),
  );
  return {
    'gray8-100x75.tif': gray(100, 75),
    'gray8-96x64.tif': gray(96, 64),
    'gray8-7x5.tif': gray(7, 5, shift: 11),
    'gray8-1x1.tif': gray(1, 1, shift: 200),
    'rgb8-100x75.tif': rgb(100, 75),
    'rgb8-32x32.tif': rgb(32, 32, shift: 50),
    'gray16-96x64.tif': buildUncompressedTiff(
      width: 96,
      height: 64,
      bitsPerSample: 16,
      samplesPerPixel: 1,
      photometric: 1,
      pixels: gray16Ramp(96, 64),
    ),
    'rgb16-48x40.tif': buildUncompressedTiff(
      width: 48,
      height: 40,
      bitsPerSample: 16,
      samplesPerPixel: 3,
      photometric: 2,
      pixels: _rgb16Ramp(48, 40),
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
      photometric: 0,
      pixels: _packedGray(100, 75, 2, (final x, final y) => x + y),
    ),
    'bilevel-128x96.tif': buildUncompressedTiff(
      width: 128,
      height: 96,
      bitsPerSample: 1,
      samplesPerPixel: 1,
      photometric: 0,
      pixels: textPage(128, 96, variant: 0),
    ),
    'bilevel-100x75.tif': buildUncompressedTiff(
      width: 100,
      height: 75,
      bitsPerSample: 1,
      samplesPerPixel: 1,
      photometric: 0,
      pixels: textPage(100, 75, variant: 1),
    ),
  };
}

// ---------------------------------------------------------------------------
// Derivations
// ---------------------------------------------------------------------------

List<_Derived> _derivations() {
  const compare = 'compare';
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
    // gray 8-bit, edge tiles on both axes (100 = 6x16+4, 75 = 4x16+11).
    cp('gray8-none-t16-le.tif', 'gray8-100x75.tif', [
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'none',
    ], 'gray8 none 16x16 LE'),
    cp('gray8-packbits-t16-be.tif', 'gray8-100x75.tif', [
      '-B',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'packbits',
    ], 'gray8 PackBits 16x16 BE'),
    cp('gray8-lzw-t32.tif', 'gray8-100x75.tif', [
      '-L',
      '-t',
      '-w',
      '32',
      '-l',
      '32',
      '-c',
      'lzw:1',
    ], 'gray8 LZW 32x32'),
    cp('gray8-lzw2-t32-be.tif', 'gray8-100x75.tif', [
      '-B',
      '-t',
      '-w',
      '32',
      '-l',
      '32',
      '-c',
      'lzw:2',
    ], 'gray8 LZW predictor 2, 32x32 BE'),
    cp('gray8-zip-t16.tif', 'gray8-100x75.tif', [
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'zip:1',
    ], 'gray8 Deflate 16x16'),
    cp('gray8-zip2-t16-big.tif', 'gray8-100x75.tif', [
      '-8',
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'zip:2',
    ], 'gray8 Deflate predictor 2, 16x16 BigTIFF'),
    // RGB 8-bit.
    cp('rgb8-none-t16.tif', 'rgb8-100x75.tif', [
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'none',
    ], 'RGB8 none 16x16'),
    cp('rgb8-packbits-t32-be.tif', 'rgb8-100x75.tif', [
      '-B',
      '-t',
      '-w',
      '32',
      '-l',
      '32',
      '-c',
      'packbits',
    ], 'RGB8 PackBits 32x32 BE'),
    cp('rgb8-lzw2-t16.tif', 'rgb8-100x75.tif', [
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'lzw:2',
    ], 'RGB8 LZW predictor 2, 16x16'),
    cp('rgb8-zip2-t32-big-be.tif', 'rgb8-100x75.tif', [
      '-8',
      '-B',
      '-t',
      '-w',
      '32',
      '-l',
      '32',
      '-c',
      'zip:2',
    ], 'RGB8 Deflate predictor 2, 32x32 BigTIFF BE'),
    // gray 16-bit: byte order matters for the samples and the predictor.
    cp('gray16-none-t16-be.tif', 'gray16-96x64.tif', [
      '-B',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'none',
    ], 'gray16 none 16x16 BE'),
    cp('gray16-lzw2-t16-le.tif', 'gray16-96x64.tif', [
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'lzw:2',
    ], 'gray16 LZW predictor 2, 16x16 LE'),
    cp('gray16-zip2-t16-big-be.tif', 'gray16-96x64.tif', [
      '-8',
      '-B',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'zip:2',
    ], 'gray16 Deflate predictor 2, 16x16 BigTIFF BE'),
    // RGB 16-bit (native lane; libtiff rounds in its RGBA conversion).
    cp(
      'rgb16-zip2-t16.tif',
      'rgb16-48x40.tif',
      ['-L', '-t', '-w', '16', '-l', '16', '-c', 'zip:2'],
      'RGB16 Deflate predictor 2, 16x16',
      'compare-native',
    ),
    // Sub-byte gray depths.
    cp('gray4-none-t16.tif', 'gray4-100x75.tif', [
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'none',
    ], 'gray4 none 16x16'),
    cp('gray2-lzw-t16-be.tif', 'gray2-100x75.tif', [
      '-B',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'lzw',
    ], 'gray2 min-is-white LZW 16x16 BE'),
    // Bilevel: generic codecs and the CCITT family.
    cp('bilevel-none-t32.tif', 'bilevel-128x96.tif', [
      '-L',
      '-t',
      '-w',
      '32',
      '-l',
      '32',
      '-c',
      'none',
    ], 'bilevel none 32x32'),
    cp('bilevel-packbits-t16.tif', 'bilevel-100x75.tif', [
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'packbits',
    ], 'bilevel PackBits 16x16 (edge tiles)'),
    cp('bilevel-lzw-t64-be.tif', 'bilevel-100x75.tif', [
      '-B',
      '-t',
      '-w',
      '64',
      '-l',
      '64',
      '-c',
      'lzw',
    ], 'bilevel LZW 64x64 BE (edge tiles)'),
    cp('bilevel-g4-t32x16.tif', 'bilevel-128x96.tif', [
      '-L',
      '-t',
      '-w',
      '32',
      '-l',
      '16',
      '-c',
      'g4',
    ], 'bilevel Group 4, 32x16 tiles'),
    cp('bilevel-g4-t16-edge-be.tif', 'bilevel-100x75.tif', [
      '-B',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'g4',
    ], 'bilevel Group 4, 16x16 BE (edge tiles)'),
    cp('bilevel-g3-t32x16-be.tif', 'bilevel-128x96.tif', [
      '-B',
      '-t',
      '-w',
      '32',
      '-l',
      '16',
      '-c',
      'g3',
    ], 'bilevel Group 3 1D, 32x16 BE'),
    cp('bilevel-g3-2d-fill-t32x16.tif', 'bilevel-128x96.tif', [
      '-L',
      '-t',
      '-w',
      '32',
      '-l',
      '16',
      '-c',
      'g3:2d:fill',
    ], 'bilevel Group 3 2D with EOL padding, 32x16'),
    enc('bilevel-mh-t32x16.tif', 'bilevel-128x96.tif', [
      '--tile',
      '32x16',
      '--compression',
      'ccittrle',
    ], 'bilevel modified Huffman (2), 32x16 tiles'),
    enc('bilevel-mh-t16-edge.tif', 'bilevel-100x75.tif', [
      '--tile',
      '16x16',
      '--compression',
      'ccittrle',
      '--big-endian',
    ], 'bilevel modified Huffman (2), 16x16 BE (edge tiles)'),
    enc('bilevel-mh-strips.tif', 'bilevel-128x96.tif', [
      '--rows',
      '8',
      '--compression',
      'ccittrle',
    ], 'bilevel modified Huffman (2) strips of 8 rows'),
    enc(
      'bilevel-none-fill2-t32.tif',
      'bilevel-128x96.tif',
      ['--tile', '32x32', '--compression', 'none', '--fillorder', '2'],
      'bilevel none with FillOrder 2 (typed rejection)',
      unsupported,
    ),
    // Orientation on tiled pages.
    enc('gray8-o2-t16.tif', 'gray8-100x75.tif', [
      '--tile',
      '16x16',
      '--compression',
      'lzw',
      '--orientation',
      '2',
    ], 'gray8 LZW 16x16, Orientation 2'),
    enc('gray8-o3-t16.tif', 'gray8-100x75.tif', [
      '--tile',
      '16x16',
      '--compression',
      'zip',
      '--predictor',
      '2',
      '--orientation',
      '3',
    ], 'gray8 Deflate predictor 2, 16x16, Orientation 3'),
    enc('gray8-o4-t16-be.tif', 'gray8-100x75.tif', [
      '--tile',
      '16x16',
      '--compression',
      'packbits',
      '--orientation',
      '4',
      '--big-endian',
    ], 'gray8 PackBits 16x16 BE, Orientation 4'),
    enc('rgb8-o3-t32.tif', 'rgb8-100x75.tif', [
      '--tile',
      '32x32',
      '--compression',
      'lzw',
      '--predictor',
      '2',
      '--orientation',
      '3',
    ], 'RGB8 LZW predictor 2, 32x32, Orientation 3'),
    enc('bilevel-g4-o2-t32x16.tif', 'bilevel-128x96.tif', [
      '--tile',
      '32x16',
      '--compression',
      'g4',
      '--orientation',
      '2',
    ], 'bilevel Group 4 32x16, Orientation 2'),
    enc(
      'gray8-o5-t16.tif',
      'gray8-100x75.tif',
      ['--tile', '16x16', '--compression', 'none', '--orientation', '5'],
      'gray8 Orientation 5 (typed rejection)',
      unsupported,
    ),
    enc(
      'gray8-o6-t16.tif',
      'gray8-100x75.tif',
      ['--tile', '16x16', '--compression', 'none', '--orientation', '6'],
      'gray8 Orientation 6 (typed rejection)',
      unsupported,
    ),
    enc(
      'gray8-o7-t16.tif',
      'gray8-100x75.tif',
      ['--tile', '16x16', '--compression', 'none', '--orientation', '7'],
      'gray8 Orientation 7 (typed rejection)',
      unsupported,
    ),
    enc(
      'gray8-o8-t16.tif',
      'gray8-100x75.tif',
      ['--tile', '16x16', '--compression', 'none', '--orientation', '8'],
      'gray8 Orientation 8 (typed rejection)',
      unsupported,
    ),
    // Geometry corner cases.
    cp('gray8-tiny-7x5-t16.tif', 'gray8-7x5.tif', [
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'lzw',
    ], 'gray8 7x5 image inside one 16x16 tile'),
    cp('gray8-1x1-t16-big.tif', 'gray8-1x1.tif', [
      '-8',
      '-B',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'zip',
    ], 'gray8 1x1 image inside one 16x16 tile, BigTIFF BE'),
    cp('rgb8-exact-32x32-t32.tif', 'rgb8-32x32.tif', [
      '-L',
      '-t',
      '-w',
      '32',
      '-l',
      '32',
      '-c',
      'packbits',
    ], 'RGB8 32x32 image equal to its single tile'),
    cp('gray8-t16x64.tif', 'gray8-100x75.tif', [
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '64',
      '-c',
      'lzw',
    ], 'gray8 rectangular 16x64 tiles'),
    // Derived from the independent files (tiffcp re-emits their SGI DataType as SampleFormat 4).
    cp('cramps-lzw2-t64.tif', 'cramps-tile.tif', [
      '-L',
      '-t',
      '-w',
      '64',
      '-l',
      '64',
      '-c',
      'lzw:2',
    ], 'cramps gray8 min-is-white LZW predictor 2, 64x64, SampleFormat 4'),
    cp('quad-zip2-t32-big.tif', 'quad-tile.tif', [
      '-8',
      '-L',
      '-t',
      '-w',
      '32',
      '-l',
      '32',
      '-c',
      'zip:2',
    ], 'quad RGB8 Deflate predictor 2, 32x32 BigTIFF, SampleFormat 4'),
    cp('ladoga-zip2-t16.tif', 'ladoga.tif', [
      '-L',
      '-t',
      '-w',
      '16',
      '-l',
      '16',
      '-c',
      'zip:2',
    ], 'ladoga gray16 Deflate predictor 2, 16x16 (edge tiles)'),
    cp('ladoga-lzw2-t32-be.tif', 'ladoga.tif', [
      '-B',
      '-t',
      '-w',
      '32',
      '-l',
      '32',
      '-c',
      'lzw:2',
    ], 'ladoga gray16 LZW predictor 2, 32x32 BE'),
    enc('fax2d-g4-t64.tif', 'fax2d.tif', [
      '--tile',
      '64x64',
      '--compression',
      'g4',
    ], 'fax2d bilevel Group 4, 64x64 tiles (real fax content, FillOrder 1)'),
    enc('fax2d-mh-t128x64-be.tif', 'fax2d.tif', [
      '--tile',
      '128x64',
      '--compression',
      'ccittrle',
      '--big-endian',
    ], 'fax2d bilevel modified Huffman, 128x64 BE'),
    enc('fax2d-g3-2d-t64.tif', 'fax2d.tif', [
      '--tile',
      '64x64',
      '--compression',
      'g3-2d',
    ], 'fax2d bilevel Group 3 2D, 64x64'),
  ];
}

/// Multi-IFD files concatenated from single-page outputs; tiffcp keeps
/// each input's layout when neither -s nor -t is given.
List<(String, List<String>, List<String>, String)> _concatenations() => [
  (
    'mixed-strip-tile-3page.tif',
    <String>[],
    ['gray8-96x64.tif', 'rgb8-lzw2-t16.tif', 'bilevel-g4-t32x16.tif'],
    'page 1 gray8 strips, page 2 RGB8 LZW 16x16 tiles, page 3 bilevel Group 4 32x16 tiles',
  ),
  (
    'mixed-big-be-2page.tif',
    ['-8', '-B'],
    ['gray16-zip2-t16-big-be.tif', 'rgb8-100x75.tif'],
    'BigTIFF BE: page 1 gray16 Deflate tiles, page 2 RGB8 strips',
  ),
];

// ---------------------------------------------------------------------------
// generate
// ---------------------------------------------------------------------------

Future<void> _generate(final String? libtiffpic) async {
  _requireTool(tiffcp, ['-h']);
  _buildEncoder();
  Directory(stagingDir).createSync(recursive: true);
  Directory(tiledDir).createSync(recursive: true);

  final entries = <Map<String, Object?>>[];
  if (libtiffpic != null) {
    for (final name in independentFiles.keys) {
      File('$libtiffpic/$name').copySync('$tiledDir/$name');
    }
  }
  for (final name in independentFiles.keys) {
    final file = File('$tiledDir/$name');
    if (!file.existsSync()) {
      throw StateError('$name is missing; pass --libtiffpic=<dir> with the pics-3.8.0 files.');
    }
    final (expectation, layout) = independentFiles[name]!;
    entries.add(
      _entry(name, 'libtiffpic pics-3.8.0 (independent)', const <String>[], expectation, layout),
    );
  }

  final sources = _sources();
  sources.forEach((final name, final bytes) => File('$stagingDir/$name').writeAsBytesSync(bytes));
  for (final name in ['cramps-tile.tif', 'quad-tile.tif', 'ladoga.tif', 'fax2d.tif']) {
    File('$tiledDir/$name').copySync('$stagingDir/$name');
  }

  for (final derived in _derivations()) {
    final output = '$tiledDir/${derived.name}';
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
  for (final (name, options, inputs, layout) in _concatenations()) {
    final argv = [
      tiffcp,
      ...options,
      ...inputs.map((final input) => '$stagingDir/$input'),
      '$tiledDir/$name',
    ];
    _runOrThrow(argv);
    entries.add(
      _entry(
        name,
        'tiffcp (libtiff 4.7.2) concatenating ${inputs.join(', ')}',
        options,
        'compare',
        layout,
      ),
    );
  }

  entries.sort((final a, final b) => (a['name']! as String).compareTo(b['name']! as String));
  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'tiff-tiled-corpus',
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
  final bytes = File('$tiledDir/$name').readAsBytesSync();
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
    ..writeln('// Generated by tool/tiff_tiles_fixtures.dart; do not edit.')
    ..writeln('//')
    ..writeln('// Small tiled fixtures embedded for the browser lane, where tests')
    ..writeln('// cannot read test/resources from disk. Bytes are identical to the')
    ..writeln('// tracked files of the same name under test/resources/tiff/tiled/.')
    ..writeln("import 'dart:convert';")
    ..writeln("import 'dart:typed_data';")
    ..writeln()
    ..writeln('/// The embedded tiled fixtures by file name.')
    ..writeln('final Map<String, Uint8List> embeddedTiledTiffFixtures = <String, Uint8List>{');
  for (final name in embeddedFixtures) {
    final encoded = base64.encode(File('$tiledDir/$name').readAsBytesSync());
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
    final file = File('$tiledDir/$name');
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
  stdout.writeln(ok ? 'tiled corpus matches its manifest' : 'tiled corpus drifted');
  return ok;
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

void _requireTool(final String executable, final List<String> probe) {
  final result = Process.runSync(executable, probe);
  if (result.exitCode != 0 && result.exitCode != 1 && result.exitCode != 2) {
    throw StateError('$executable is required to regenerate the tiled corpus.');
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
