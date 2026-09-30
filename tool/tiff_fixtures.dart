/// Builds and verifies the TIFF fixture corpus under
/// `test/resources/tiff/`.
///
/// `dart run tool/tiff_fixtures.dart generate` writes deterministic
/// source images as uncompressed TIFFs (this file's writer), transcodes
/// them with the local libtiff `tiffcp` into the tracked fixtures, and
/// prints the SHA-256 of every output for PROVENANCE.md.
///
/// `dart run tool/tiff_fixtures.dart parity` decodes every tracked
/// fixture with the library and writes an uncompressed TIFF twin of
/// each page under `/tmp/unseal-tiff-parity/` so the pixels can be
/// compared against libtiff with `tiffcmp -t`:
///
/// ```sh
/// dart run tool/tiff_fixtures.dart parity
/// for f in test/resources/tiff/*.tif; do
///   n=$(basename "$f" .tif)
///   tiffcp -c none "$f" "/tmp/unseal-tiff-parity/$n.ref.tif"
///   tiffcmp -t "/tmp/unseal-tiff-parity/$n.ref.tif" "/tmp/unseal-tiff-parity/$n.mine.tif"
/// done
/// ```
///
/// The 16-bit fixture is verified against its source ramp instead (the
/// display model truncates samples to 8 bits, so a byte-equal twin is
/// impossible): `tiffcmp -t gray16-src.tif fixture` must be silent.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:unseal/src/features/tiff/parse_tiff_book.dart';
import 'package:unseal/src/features/tiff/tiff_book.dart';

const resourceDir = 'test/resources/tiff';
const stagingDir = '/tmp/unseal-tiff-src';
const parityDir = '/tmp/unseal-tiff-parity';

Future<void> main(final List<String> arguments) async {
  final mode = arguments.isEmpty ? 'generate' : arguments.first;
  if (mode == 'generate') {
    await _generate();
  } else if (mode == 'parity') {
    await _parity();
  } else {
    stderr.writeln('usage: dart run tool/tiff_fixtures.dart [generate|parity]');
    exitCode = 64;
  }
}

// ---------------------------------------------------------------------------
// Source images
// ---------------------------------------------------------------------------

/// Deterministic gray-8 gradient: `v = (x*3 + y*5) & 0xFF`.
Uint8List grayGradient(final int width, final int height, {final int shift = 0}) {
  final pixels = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      pixels[y * width + x] = (x * 3 + y * 5 + shift) & 0xFF;
    }
  }
  return pixels;
}

/// Deterministic RGB-8 gradient.
Uint8List rgbGradient(final int width, final int height, {final int shift = 0}) {
  final pixels = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final base = (y * width + x) * 3;
      pixels[base] = (x * 2 + shift) & 0xFF;
      pixels[base + 1] = (y * 2 + shift) & 0xFF;
      pixels[base + 2] = (x + y + shift) & 0xFF;
    }
  }
  return pixels;
}

/// Deterministic gray-16 ramp: `v = (x*13 + y*97) & 0xFFFF`.
Uint8List gray16Ramp(final int width, final int height, {final Endian endian = Endian.little}) {
  final pixels = Uint8List(width * height * 2);
  final view = ByteData.sublistView(pixels);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      view.setUint16((y * width + x) * 2, (x * 13 + y * 97) & 0xFFFF, endian);
    }
  }
  return pixels;
}

/// A minimal 5x7 glyph font (1 = ink, rows top to bottom) for the
/// text-like bilevel pages.
const _glyphs = <String, List<String>>{
  'U': ['10001', '10001', '10001', '10001', '10001', '10001', '01110'],
  'N': ['10001', '11001', '11001', '10101', '10011', '10011', '10001'],
  'S': ['01110', '10001', '10000', '01110', '00001', '10001', '01110'],
  'E': ['11111', '10000', '10000', '11110', '10000', '10000', '11111'],
  'A': ['01110', '10001', '10001', '11111', '10001', '10001', '10001'],
  'L': ['10000', '10000', '10000', '10000', '10000', '10000', '11111'],
  'T': ['11111', '00100', '00100', '00100', '00100', '00100', '00100'],
  'I': ['11111', '00100', '00100', '00100', '00100', '00100', '11111'],
  'F': ['11111', '10000', '10000', '11110', '10000', '10000', '10000'],
  'G': ['01110', '10001', '10000', '10111', '10001', '10001', '01110'],
  '4': ['00010', '00110', '01010', '10010', '11111', '00010', '00010'],
  ' ': ['00000', '00000', '00000', '00000', '00000', '00000', '00000'],
};

/// Draws text-like content on a bilevel canvas (photometric 0:
/// WhiteIsZero, so ink is the stored `1` bit).
Uint8List textPage(final int width, final int height, {required final int variant}) {
  final rowStride = (width + 7) ~/ 8;
  final pixels = Uint8List(rowStride * height); // 0 = white
  void ink(final int x, final int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) return;
    pixels[y * rowStride + (x >> 3)] |= 0x80 >> (x & 7);
  }

  void drawText(final String text, final int startX, final int startY) {
    var cursor = startX;
    for (final char in text.split('')) {
      final glyph = _glyphs[char] ?? _glyphs[' ']!;
      for (var row = 0; row < 7; row++) {
        for (var column = 0; column < 5; column++) {
          if (glyph[row].codeUnitAt(column) == 0x31) ink(cursor + column, startY + row);
        }
      }
      cursor += 6;
    }
  }

  void drawBox(final int left, final int top, final int boxWidth, final int boxHeight) {
    for (var x = left; x < left + boxWidth; x++) {
      ink(x, top);
      ink(x, top + boxHeight - 1);
    }
    for (var y = top; y < top + boxHeight; y++) {
      ink(left, y);
      ink(left + boxWidth - 1, y);
    }
  }

  drawText('UNSEAL TIFF G4', 8, 12);
  drawText(variant == 0 ? 'G4 LINE A' : 'G4 LINE B', 20, 34);
  drawBox(12, 56, width - 24, 30);
  return pixels;
}

// ---------------------------------------------------------------------------
// Minimal uncompressed classic TIFF writer (dev/parity only)
// ---------------------------------------------------------------------------

/// Writes one uncompressed classic TIFF with a single strip.
///
/// [pixels] holds packed rows: interleaved samples in file byte order
/// for 8/16-bit depths, MSB-first bit-packed rows for 1-bit.
Uint8List buildUncompressedTiff({
  required final int width,
  required final int height,
  required final int bitsPerSample,
  required final int samplesPerPixel,
  required final int photometric,
  required final Uint8List pixels,
  final Endian endian = Endian.little,
}) {
  const tags = 11;
  final ifdSize = 2 + tags * 12 + 4;
  var extraLength = 8; // XResolution rational
  if (samplesPerPixel * 2 > 4) extraLength += samplesPerPixel * 2;
  var stripOffset = 8 + ifdSize + extraLength;
  if (stripOffset.isOdd) stripOffset++;

  final output = Uint8List(stripOffset + pixels.length);
  final view = ByteData.sublistView(output);
  output[0] = endian == Endian.little ? 0x49 : 0x4D;
  output[1] = output[0];
  view.setUint16(2, 42, endian);
  view.setUint32(4, 8, endian);

  const ifd = 8;
  view.setUint16(ifd, tags, endian);
  var entry = ifd + 2;
  void tag(
    final int id,
    final int type,
    final int count,
    final int value, {
    final int? extraOffset,
  }) {
    view.setUint16(entry, id, endian);
    view.setUint16(entry + 2, type, endian);
    view.setUint32(entry + 4, count, endian);
    if (extraOffset != null) {
      view.setUint32(entry + 8, extraOffset, endian);
    } else {
      // Inline values are left-justified in the value field.
      if (type == 3) {
        view.setUint16(entry + 8, value, endian);
      } else {
        view.setUint32(entry + 8, value, endian);
      }
    }
    entry += 12;
  }

  final bitsOffset = 8 + ifdSize;
  final rationalOffset = bitsOffset + (samplesPerPixel * 2 > 4 ? samplesPerPixel * 2 : 0);
  final extra = bitsOffset;
  if (samplesPerPixel > 1) {
    for (var i = 0; i < samplesPerPixel; i++) {
      view.setUint16(extra + i * 2, bitsPerSample, endian);
    }
  }
  tag(256, 4, 1, width); // ImageWidth
  tag(257, 4, 1, height); // ImageLength
  tag(
    258,
    3,
    samplesPerPixel,
    bitsPerSample,
    extraOffset: samplesPerPixel > 1 ? bitsOffset : null,
  ); // BitsPerSample
  tag(259, 3, 1, 1); // Compression: none
  tag(262, 3, 1, photometric);
  tag(273, 4, 1, stripOffset); // StripOffsets
  tag(277, 3, 1, samplesPerPixel);
  tag(278, 4, 1, height); // RowsPerStrip
  tag(279, 4, 1, pixels.length); // StripByteCounts
  tag(282, 5, 1, 0, extraOffset: rationalOffset); // XResolution
  tag(296, 3, 1, 2); // ResolutionUnit: inch
  view.setUint16(entry, 0, endian); // next IFD
  view.setUint32(rationalOffset, 72, endian);
  view.setUint32(rationalOffset + 4, 1, endian);
  output.setRange(stripOffset, stripOffset + pixels.length, pixels);
  return output;
}

// ---------------------------------------------------------------------------
// generate
// ---------------------------------------------------------------------------

Future<void> _generate() async {
  final tiffcp = await _requireTool('tiffcp');
  final tiffset = await _requireTool('tiffset');
  await Directory(stagingDir).create(recursive: true);
  await Directory(resourceDir).create(recursive: true);

  void transcode(final String name, final List<String> sources, final List<String> options) {
    final result = Process.runSync(tiffcp, [...options, ...sources, '$resourceDir/$name']);
    if (result.exitCode != 0) {
      stderr.write(result.stdout);
      stderr.write(result.stderr);
      throw StateError('tiffcp failed for $name');
    }
  }

  void writeSource(final String name, final Uint8List bytes) {
    File('$stagingDir/$name').writeAsBytesSync(bytes);
  }

  // Deterministic sources.
  final gray = buildUncompressedTiff(
    width: 96,
    height: 64,
    bitsPerSample: 8,
    samplesPerPixel: 1,
    photometric: 1,
    pixels: grayGradient(96, 64),
  );
  final grayVariant = buildUncompressedTiff(
    width: 96,
    height: 64,
    bitsPerSample: 8,
    samplesPerPixel: 1,
    photometric: 1,
    pixels: grayGradient(96, 64, shift: 37),
  );
  final rgb = buildUncompressedTiff(
    width: 128,
    height: 96,
    bitsPerSample: 8,
    samplesPerPixel: 3,
    photometric: 2,
    pixels: rgbGradient(128, 96),
  );
  final rgbVariant = buildUncompressedTiff(
    width: 64,
    height: 48,
    bitsPerSample: 8,
    samplesPerPixel: 3,
    photometric: 2,
    pixels: rgbGradient(64, 48, shift: 91),
  );
  final gray16 = buildUncompressedTiff(
    width: 96,
    height: 64,
    bitsPerSample: 16,
    samplesPerPixel: 1,
    photometric: 1,
    pixels: gray16Ramp(96, 64),
  );
  Uint8List text(final int variant) => buildUncompressedTiff(
    width: 128,
    height: 96,
    bitsPerSample: 1,
    samplesPerPixel: 1,
    photometric: 0,
    pixels: textPage(128, 96, variant: variant),
  );
  writeSource('gray-src.tif', gray);
  writeSource('gray2-src.tif', grayVariant);
  writeSource('rgb-src.tif', rgb);
  writeSource('rgb2-src.tif', rgbVariant);
  writeSource('gray16-src.tif', gray16);
  writeSource('text1-src.tif', text(0));
  writeSource('text2-src.tif', text(1));

  // Tracked fixtures.
  transcode(
    'gray-none-2page-le.tif',
    ['$stagingDir/gray-src.tif', '$stagingDir/gray2-src.tif'],
    ['-L', '-c', 'none'],
  );
  transcode('rgb-packbits.tif', ['$stagingDir/rgb-src.tif'], ['-L', '-c', 'packbits']);
  transcode('rgb-lzw-predictor.tif', ['$stagingDir/rgb-src.tif'], ['-L', '-c', 'lzw:2']);
  transcode('gray16-deflate-predictor.tif', ['$stagingDir/gray16-src.tif'], ['-L', '-c', 'zip:2']);
  transcode(
    'g4-text-2page-be.tif',
    ['$stagingDir/text1-src.tif', '$stagingDir/text2-src.tif'],
    ['-B', '-c', 'g4'],
  );
  transcode('g3-text-le.tif', ['$stagingDir/text2-src.tif'], ['-L', '-c', 'g3']);
  transcode(
    'bigtiff-rgb-2page.tif',
    ['$stagingDir/rgb-src.tif', '$stagingDir/rgb2-src.tif'],
    ['-8', '-L', '-c', 'none'],
  );
  // libtiff always externalizes JPEG tables into the JPEGTables
  // tag, so this fixture exercises the typed-unsupported
  // abbreviated-stream rejection rather than the passthrough.
  transcode(
    'jpeg-external-tables.tif',
    ['$stagingDir/gray-src.tif'],
    ['-L', '-c', 'jpeg', '-r', '64'],
  );

  // Metadata fixture: a copy of the gray source with IFD 0 tags set.
  File('$stagingDir/gray-src.tif').copySync('$stagingDir/metadata.tif');
  for (final (tag, value) in const [
    ('270', 'Generated gradient for the unseal TIFF corpus'),
    ('306', '2026:09:30 12:00:00'),
    ('305', 'tool/tiff_fixtures.dart'),
    ('315', 'Unseal fixture tooling'),
  ]) {
    final result = Process.runSync(tiffset, ['-s', tag, value, '$stagingDir/metadata.tif']);
    if (result.exitCode != 0) {
      stderr.write(result.stderr);
      throw StateError('tiffset failed for tag $tag');
    }
  }
  transcode('metadata-gray.tif', ['$stagingDir/metadata.tif'], ['-L', '-c', 'none']);

  await _report();
}

Future<String> _requireTool(final String tool) async {
  final result = await Process.run(
    Platform.environment['TIFFCP_PATH'] ?? '/opt/homebrew/bin/$tool',
    ['--help'],
  );
  if (result.exitCode != 0 && result.exitCode != 1 && result.exitCode != 2) {
    throw StateError('$tool is required to regenerate the TIFF corpus.');
  }
  return '/opt/homebrew/bin/$tool';
}

Future<void> _report() async {
  final manifest = <Map<String, Object?>>[];
  for (final entity in Directory(
    resourceDir,
  ).listSync().whereType<File>().toList()..sort((final a, final b) => a.path.compareTo(b.path))) {
    if (!_isTiff(entity.path)) continue;
    final bytes = entity.readAsBytesSync();
    manifest.add({
      'name': entity.uri.pathSegments.last,
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    });
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(manifest));
}

String _sha256(final List<int> bytes) => sha256.convert(bytes).toString();

// ---------------------------------------------------------------------------
// parity
// ---------------------------------------------------------------------------

/// The fixtures whose pages decode to 1-bit rasters; their twins are
/// re-packed to bilevel (photometric 0) so libtiff compares sample
/// values, not display levels.
const _bilevelFixtures = <String>{
  'g4-text-2page-be.tif',
  'g3-text-le.tif',
  'testfax4.tiff',
  'testfax3_bug54_1dnoEOL.tif',
};

/// The real-corpus fixtures expected to fail typed (palette, SGILOG,
/// old JPEG, tiled JPEG, hostile IFD loop); parity reports them without
/// failing.
const _expectedUnsupported = <String>{
  'minisblack-2c-8b-alpha.tiff',
  'palette-1c-8b.tiff',
  'logluv-3c-16b.tiff',
  'ojpeg_zackthecat_subsamp22_single_strip.tiff',
  'quad-tile.jpg.tiff',
  'test_ifd_loop_to_self.tif',
};

/// The 16-bit fixture is skipped (the display model keeps the high
/// byte) and verified against its source ramp instead.
const _skippedFixtures = <String>{'gray16-deflate-predictor.tif'};

/// For every tracked fixture: decode with the library and write an
/// uncompressed TIFF twin per page.
Future<void> _parity() async {
  final directory = Directory(parityDir);
  if (directory.existsSync()) directory.deleteSync(recursive: true);
  directory.createSync(recursive: true);

  for (final entity in Directory(
    resourceDir,
  ).listSync().whereType<File>().toList()..sort((final a, final b) => a.path.compareTo(b.path))) {
    if (!_isTiff(entity.path)) continue;
    final name = entity.uri.pathSegments.last;
    if (_skippedFixtures.contains(name)) {
      stdout.writeln('$name: skip twin (16-bit; verified against gray16-src.tif)');
      continue;
    }
    final bytes = entity.readAsBytesSync();
    final TiffBook book;
    try {
      book = parseTiffBook(bytes);
    } on Object catch (error) {
      if (_expectedUnsupported.contains(name)) {
        stdout.writeln('$name: typed unsupported as expected: $error');
        continue;
      }
      stdout.writeln('$name: DECODE FAILED: $error');
      continue;
    }
    final bilevel = _bilevelFixtures.contains(name);
    for (var page = 0; page < book.pageCount; page++) {
      final tiffPage = book.pages[page];
      final rgb = tiffPage.image.type == 'bmp' ? tiffPage.image.content : null;
      if (rgb == null) {
        stdout.writeln('$name page ${page + 1}: JPEG passthrough (no raster twin)');
        continue;
      }
      final width = tiffPage.width;
      final height = tiffPage.height;
      final Uint8List pixels;
      final int bitsPerSample;
      final int samplesPerPixel;
      final int photometric;
      if (bilevel) {
        bitsPerSample = 1;
        samplesPerPixel = 1;
        photometric = 0;
        final stride = (width + 7) ~/ 8;
        pixels = Uint8List(stride * height);
        final header = bmpHeaderSize(rgb);
        for (var y = 0; y < height; y++) {
          // BMP rows are bottom-up BGR; ink displays as 0.
          final sourceRow = header + (height - 1 - y) * (width * 3 + _padding(width * 3));
          for (var x = 0; x < width; x++) {
            if (rgb[sourceRow + x * 3] == 0) pixels[y * stride + (x >> 3)] |= 0x80 >> (x & 7);
          }
        }
      } else {
        bitsPerSample = 8;
        samplesPerPixel = 3;
        photometric = 2;
        final header = bmpHeaderSize(rgb);
        final stride = width * 3 + _padding(width * 3);
        pixels = Uint8List(width * height * 3);
        for (var y = 0; y < height; y++) {
          final sourceRow = header + (height - 1 - y) * stride;
          for (var x = 0; x < width; x++) {
            final source = sourceRow + x * 3;
            final target = (y * width + x) * 3;
            pixels[target] = rgb[source + 2];
            pixels[target + 1] = rgb[source + 1];
            pixels[target + 2] = rgb[source];
          }
        }
      }
      final twin = buildUncompressedTiff(
        width: width,
        height: height,
        bitsPerSample: bitsPerSample,
        samplesPerPixel: samplesPerPixel,
        photometric: photometric,
        pixels: pixels,
      );
      final suffix = book.pageCount > 1 ? '.p${page + 1}' : '';
      File('$parityDir/$name$suffix.mine.tif').writeAsBytesSync(twin);
    }
    final rasterHashes = [for (final page in book.pages) _sha256(page.image.content)];
    stdout.writeln('$name: ${book.pageCount} pages; raster sha256 per page: $rasterHashes');
  }
}

bool _isTiff(final String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.tif') || lower.endsWith('.tiff');
}

int bmpHeaderSize(final Uint8List bmp) {
  final view = ByteData.sublistView(bmp);
  return view.getUint32(10, Endian.little);
}

int _padding(final int rowBytes) => (4 - (rowBytes % 4)) % 4;
