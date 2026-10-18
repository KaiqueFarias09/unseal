/// Compares Unseal's TIFF page images against the libtiff reference dumps
/// recorded by `tool/tiff_planar_palette_reference.py`.
///
/// Every case opens through the public API (`Unseal.parse`). Four lanes
/// run per comparable page (contract in `doc/tiff-planar-palette.md`):
///
/// - pixels: the RGB888 page image against the native dump under the
///   fixed projection rules, zero tolerance;
/// - native samples: planar band samples through the production segment
///   observer, 16 bits at full precision including the low byte;
/// - indices: palette indices through the segment observer, compared
///   against the native index raster before any projection;
/// - colormap: the parsed ColorMap against the dumped native 16-bit
///   tables, entry by entry;
/// - rgba: libtiff's own conversion, where the expectation demands it.
///
/// Expected rejections must fail with the declared typed exception.
/// Negative self-checks run at the end (missing reference, altered dump,
/// flipped planar low bit, flipped palette index, flipped ColorMap low
/// byte, failed reference command) and the run fails unless each of them
/// is reported as a divergence.
///
/// Usage:
///
///     dart run tool/tiff_planar_palette_compare.dart \
///       --reference=build/evidence/D03/reference.json \
///       --out=build/evidence/D03/compare
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:unseal/src/features/tiff/tiff_container.dart';
import 'package:unseal/src/features/tiff/tiff_limits.dart';
import 'package:unseal/src/features/tiff/tiff_page_decoder.dart';
import 'package:unseal/unseal.dart';

void main(final List<String> arguments) {
  String? referencePath;
  var outDir = 'build/evidence/D03/compare';
  for (final argument in arguments) {
    if (argument.startsWith('--reference=')) referencePath = argument.substring(12);
    if (argument.startsWith('--out=')) outDir = argument.substring(6);
  }
  if (referencePath == null) {
    stderr.writeln('usage: --reference=<reference.json> [--out=<dir>]');
    exitCode = 64;
    return;
  }
  Directory(outDir).createSync(recursive: true);
  final reference = json.decode(File(referencePath).readAsStringSync()) as Map<String, Object?>;
  final cases = (reference['cases']! as List).cast<Map<String, Object?>>();
  final log = StringBuffer();
  final results = <Map<String, Object?>>[];
  for (final record in cases) {
    final result = _compareCase(record);
    results.add(result);
    log.writeln(
      '${result['verdict']}\t${result['id']}\t${result['pagesCompared']} pages\t'
      '${result['pixelsCompared']} px\t${result['detail']}',
    );
  }

  final selfChecks = _selfChecks(cases, outDir);
  for (final check in selfChecks) {
    log.writeln(
      'self-check\t${check['name']}\t${check['behaved'] == true ? 'behaved' : 'FAILED'}\t${check['detail']}',
    );
  }

  final totals = <String, int>{
    'cases': results.length,
    'pass': results.where((final r) => r['verdict'] == 'pass').length,
    'expectedRejection': results.where((final r) => r['verdict'] == 'expected-rejection').length,
    'expectedDifference': results.where((final r) => r['verdict'] == 'expected-difference').length,
    'diverged': results.where((final r) => r['verdict'] == 'diverged').length,
    'pagesCompared': results.fold(0, (final sum, final r) => sum + (r['pagesCompared']! as int)),
    'pixelsCompared': results.fold(0, (final sum, final r) => sum + (r['pixelsCompared']! as int)),
    'nativeSamplesCompared': results.fold(
      0,
      (final sum, final r) => sum + (r['nativeSamplesCompared'] as int? ?? 0),
    ),
    'indicesCompared': results.fold(
      0,
      (final sum, final r) => sum + (r['indicesCompared'] as int? ?? 0),
    ),
    'colormapEntriesCompared': results.fold(
      0,
      (final sum, final r) => sum + (r['colormapEntriesCompared'] as int? ?? 0),
    ),
    'rgbaPixelsCompared': results.fold(
      0,
      (final sum, final r) => sum + (r['rgbaPixelsCompared']! as int),
    ),
  };
  final selfChecksBehaved = selfChecks.every((final check) => check['behaved'] == true);
  final head = Process.runSync('git', ['rev-parse', 'HEAD']).stdout.toString().trim();
  final report = <String, Object?>{
    'schemaVersion': 1,
    'mission': 'D03',
    'head': head,
    'reference': referencePath,
    'referenceSha256': sha256.convert(File(referencePath).readAsBytesSync()).toString(),
    'referenceHead': reference['head'],
    'libtiff': reference['libtiff'],
    'normalization': {
      'unit': 'RGB888 pixel of the BMP page image, rows top-down',
      'tolerance': 0,
      'planar16': 'native16 samples exact; projected RGB high byte; libtiff RGBA rounds',
      'palette':
          'native indices and 16-bit ColorMap exact; display projection follows '
          'libtiff 4.7.2: byte-range tables used directly, full-range tables take v >> 8',
      'orientation': 'native raster flipped for 2/3/4; 5-8 are expected rejections',
    },
    'totals': totals,
    'selfChecks': selfChecks,
    'selfChecksBehaved': selfChecksBehaved,
    'cases': results,
  };
  File(
    '$outDir/report.json',
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  File('$outDir/cases.log').writeAsStringSync(log.toString());
  stdout.writeln(json.encode({'totals': totals, 'selfChecksBehaved': selfChecksBehaved}));
  exitCode = totals['diverged'] == 0 && selfChecksBehaved && totals['cases']! > 0 ? 0 : 1;
}

Map<String, Object?> _compareCase(
  final Map<String, Object?> record, {
  final Map<String, Object?>? referenceOverride,
}) {
  final id = record['id'] as String? ?? record['name'] as String;
  final expectation = record['expectation']! as String;
  final result = <String, Object?>{
    'id': id,
    'name': record['name'],
    'group': record['group'],
    'expectation': expectation,
    'layout': record['layout'],
    'producer': record['producer'],
    'pagesCompared': 0,
    'pixelsCompared': 0,
    'rgbaPixelsCompared': 0,
    'nativeSamplesCompared': 0,
    'indicesCompared': 0,
    'colormapEntriesCompared': 0,
    'pages': <Map<String, Object?>>[],
  };
  final path = record['path']! as String;
  final file = File(path);
  if (!file.existsSync()) {
    return result..addAll({'verdict': 'diverged', 'detail': 'input missing'});
  }
  final bytes = Uint8List.fromList(file.readAsBytesSync());
  final digest = sha256.convert(bytes).toString();
  if (digest != record['sha256']) {
    return result
      ..addAll({'verdict': 'diverged', 'detail': 'input hash differs from the reference record'});
  }
  final dump = record['dump'] as Map<String, Object?>?;
  final reference = referenceOverride ?? record['reference'] as Map<String, Object?>?;
  final referenceStatus = reference == null
      ? 'missing'
      : (reference['directories'] as List?)
                ?.map((final d) => (d as Map)['nativeStatus'])
                .join(',') ??
            'empty';
  result['libtiffStatus'] = referenceStatus;

  TiffBook book;
  try {
    book = Unseal.parse(bytes) as TiffBook;
  } on Object catch (error) {
    final type = error.runtimeType.toString();
    if (expectation.startsWith('reject:')) {
      final wanted = expectation.substring(7);
      final accepted = switch (wanted) {
        'TiffUnsupportedCodecException' => {
          'TiffUnsupportedCodecException',
          'FormatNotSupportedException',
        },
        'TiffException' => {'TiffException', 'InvalidBookException'},
        _ => {wanted},
      };
      final matched = accepted.contains(type);
      return result..addAll({
        'verdict': matched ? 'expected-rejection' : 'diverged',
        'detail': matched
            ? 'rejected typed as $type: $error'
            : 'rejected as $type, expected $wanted: $error',
        'exception': type,
      });
    }
    return result..addAll({
      'verdict': 'diverged',
      'detail': 'unexpected failure $type: $error',
      'exception': type,
    });
  }
  if (expectation.startsWith('reject:')) {
    return result..addAll({
      'verdict': 'diverged',
      'detail': 'decoded ${book.pageCount} pages but a typed rejection was expected',
    });
  }
  if (dump != null && dump['exitCode'] != 0) {
    return result..addAll({
      'verdict': 'diverged',
      'detail': 'reference dump command failed (exit ${dump['exitCode']})',
    });
  }
  if (reference == null) {
    return result..addAll({'verdict': 'diverged', 'detail': 'reference dump missing'});
  }
  final directories = (reference['directories']! as List).cast<Map<String, Object?>>();
  if (directories.length != book.pageCount) {
    return result..addAll({
      'verdict': 'diverged',
      'detail':
          'Unseal decoded ${book.pageCount} pages, libtiff read ${directories.length} directories',
    });
  }
  final compareRgba = expectation == 'compare';
  final container = TiffContainer(bytes);
  final nativeBudget = TiffDecodeBudget();
  var verdict = 'pass';
  var sawExpectedDifference = false;
  final details = <String>[];
  for (var index = 0; index < book.pageCount; index++) {
    final page = book.pages[index];
    final directory = directories[index];
    // The pre-projection lanes run first: the production decoder is
    // driven once, observing samples, indices, and the ColorMap.
    final native = _compareNativeSamples(
      container,
      container.pageDirectories[index],
      directory,
      nativeBudget,
    );
    final pageResult = _comparePage(page, directory, compareRgba: compareRgba);
    pageResult['native'] = native;
    if (native['colormapCompared'] != null) {
      pageResult['colormap'] = {
        'compared': native['colormapCompared'],
        'differences': native['colormapDifferences'],
      };
      result['colormapEntriesCompared'] =
          (result['colormapEntriesCompared']! as int) + (native['colormapCompared']! as int);
      if (native['colormapDifferences'] != 0 || native['colormapCompared'] == 0) {
        verdict = 'diverged';
        details.add('page ${index + 1}: ColorMap comparison $native');
      }
    }
    if (directory['photometric'] == 3) {
      pageResult['indices'] = {
        'compared': native['indicesCompared'],
        'differences': native['indexDifferences'],
      };
      result['indicesCompared'] =
          (result['indicesCompared']! as int) + (native['indicesCompared']! as int);
      if (native['indexDifferences'] != 0 || native['indicesCompared'] == 0) {
        verdict = 'diverged';
        details.add('page ${index + 1}: index comparison $native');
      }
    }
    result['nativeSamplesCompared'] =
        (result['nativeSamplesCompared']! as int) + (native['samplesCompared']! as int);
    (result['pages']! as List).add(pageResult);
    if (pageResult['status'] != 'ok') {
      verdict = 'diverged';
      details.add('page ${index + 1}: ${pageResult['status']}');
      continue;
    }
    if (native['differences'] != 0) {
      verdict = 'diverged';
      details.add('page ${index + 1}: native sample comparison $native');
    }
    result['pagesCompared'] = (result['pagesCompared']! as int) + 1;
    result['pixelsCompared'] = (result['pixelsCompared']! as int) + (pageResult['pixels']! as int);
    if (pageResult['nativeDiffs'] != 0) {
      verdict = 'diverged';
      details.add('page ${index + 1}: ${pageResult['nativeDiffs']} native pixel differences');
    }
    if (compareRgba) {
      result['rgbaPixelsCompared'] =
          (result['rgbaPixelsCompared']! as int) + (pageResult['pixels']! as int);
      if (pageResult['rgbaDiffs'] != 0) {
        verdict = 'diverged';
        details.add('page ${index + 1}: ${pageResult['rgbaDiffs']} RGBA pixel differences');
      }
    } else if (pageResult['rgbaDiffs'] != 0 && verdict == 'pass') {
      sawExpectedDifference = true;
      details.add(
        'page ${index + 1}: RGBA lane differs in ${pageResult['rgbaDiffs']} pixels (libtiff rounds 16-bit RGB)',
      );
    }
  }
  if (sawExpectedDifference && verdict == 'pass') verdict = 'expected-difference';
  result['verdict'] = verdict;
  result['detail'] = details.isEmpty ? 'every pixel matches libtiff' : details.join('; ');
  return result;
}

/// Compares the production decoder's post-predictor output against the
/// native dump before any RGB projection: planar band samples (16-bit at
/// full precision including the low byte), palette indices, and the
/// parsed ColorMap tables.
Map<String, Object?> _compareNativeSamples(
  final TiffContainer container,
  final TiffIfd ifd,
  final Map<String, Object?> directory,
  final TiffDecodeBudget budget,
) {
  final width = directory['width']! as int;
  final height = directory['height']! as int;
  final spp = directory['samplesPerPixel']! as int;
  final bits = directory['bitsPerSample']! as int;
  final photometric = directory['photometric']! as int;
  final native = ByteData.sublistView(File(directory['nativeFile']! as String).readAsBytesSync());
  var compared = 0;
  var differences = 0;
  var indicesCompared = 0;
  var indexDifferences = 0;
  var colormapCompared = 0;
  var colormapDifferences = 0;
  var colormapMissing = false;

  void compareAgainstNative(
    final int actual, {
    required final int y,
    required final int x,
    required final int channel,
    final bool indexLane = false,
  }) {
    final expectedAt = ((y * width + x) * spp + channel) * (bits == 16 ? 2 : 1);
    final expected = bits == 16
        ? native.getUint16(expectedAt, Endian.little)
        : native.getUint8(expectedAt);
    compared++;
    if (indexLane) {
      indicesCompared++;
      if (actual != expected) indexDifferences++;
    } else if (actual != expected) {
      differences++;
    }
  }

  try {
    decodeTiffPage(
      container,
      ifd,
      budget: budget,
      onDecodedSegment: (final segment) {
        if (segment.bits != bits || segment.endian != container.endian) {
          throw StateError('Native sample layout differs from libtiff');
        }
        final actual = ByteData.sublistView(segment.bytes);
        for (var y = 0; y < segment.height; y++) {
          for (var x = 0; x < segment.width; x++) {
            final at = y * segment.rowBytes + x * segment.samplesPerPixel * (bits ~/ 8);
            if (photometric == 3) {
              // Palette page: one index per pixel.
              final value = bits == 8 ? segment.bytes[at] : _subByte(segment.bytes, at, x, bits);
              compareAgainstNative(
                value,
                y: segment.rowStart + y,
                x: segment.columnStart + x,
                channel: 0,
                indexLane: true,
              );
            } else if (segment.samplesPerPixel == 1) {
              // Planar band: one sample per pixel of plane [sample].
              final value = bits == 16 ? actual.getUint16(at, segment.endian) : segment.bytes[at];
              compareAgainstNative(
                value,
                y: segment.rowStart + y,
                x: segment.columnStart + x,
                channel: segment.sample,
              );
            } else {
              for (var channel = 0; channel < segment.samplesPerPixel; channel++) {
                final value = bits == 16
                    ? actual.getUint16(at + channel * 2, segment.endian)
                    : segment.bytes[at + channel];
                compareAgainstNative(
                  value,
                  y: segment.rowStart + y,
                  x: segment.columnStart + x,
                  channel: channel,
                );
              }
            }
          }
        }
      },
      onDecodedPalette: (final palette) {
        final colormapFile = directory['colormapFile'];
        if (colormapFile is! String) {
          colormapMissing = true;
          return;
        }
        final expected = ByteData.sublistView(File(colormapFile).readAsBytesSync());
        var entries = 0;
        var wrong = 0;
        for (final table in [palette.red, palette.green, palette.blue]) {
          for (final value in table) {
            if (expected.getUint16(entries * 2, Endian.little) != value) wrong++;
            entries++;
          }
        }
        if (entries != 3 * (1 << palette.bits)) {
          throw StateError('ColorMap holds $entries entries, expected ${3 * (1 << palette.bits)}');
        }
        colormapCompared += entries;
        colormapDifferences += wrong;
      },
    );
  } on StateError catch (error) {
    return {
      'samplesCompared': compared,
      'differences': differences + 1,
      'indicesCompared': indicesCompared,
      'indexDifferences': indexDifferences,
      if (photometric == 3) 'colormapCompared': colormapCompared,
      if (photometric == 3) 'colormapDifferences': colormapDifferences + 1,
      'error': '$error',
    };
  }
  if (photometric != 3 && compared != width * height * spp) {
    throw StateError('Native sample coverage $compared != ${width * height * spp}');
  }
  if (photometric == 3 && indicesCompared != width * height) {
    throw StateError('Index coverage $indicesCompared != ${width * height}');
  }
  if (photometric == 3 && colormapMissing) {
    throw StateError('libtiff dumped no ColorMap for a palette page');
  }
  return {
    'samplesCompared': compared,
    'differences': differences,
    'indicesCompared': indicesCompared,
    'indexDifferences': indexDifferences,
    if (photometric == 3) 'colormapCompared': colormapCompared,
    if (photometric == 3) 'colormapDifferences': colormapDifferences,
  };
}

/// Compares one decoded page image against the native dump and libtiff's
/// RGBA conversion under the fixed normalization.
Map<String, Object?> _comparePage(
  final TiffPage page,
  final Map<String, Object?> directory, {
  required final bool compareRgba,
}) {
  final width = directory['width']! as int;
  final height = directory['height']! as int;
  final bits = directory['bitsPerSample']! as int;
  final samplesPerPixel = directory['samplesPerPixel']! as int;
  final photometric = directory['photometric']! as int;
  final orientation = directory['orientation']! as int;
  final result = <String, Object?>{
    'width': width,
    'height': height,
    'bitsPerSample': bits,
    'samplesPerPixel': samplesPerPixel,
    'photometric': photometric,
    'orientation': orientation,
    'tiled': directory['tiled'],
    'compression': directory['compression'],
    'pixels': 0,
    'nativeDiffs': 0,
    'rgbaDiffs': 0,
  };
  if (directory['nativeStatus'] != 'ok') {
    return result..['status'] = 'libtiff native dump unavailable (${directory['nativeStatus']})';
  }
  if (compareRgba && directory['rgbaStatus'] != 'ok') {
    return result..['status'] = 'libtiff RGBA dump unavailable (${directory['rgbaStatus']})';
  }
  if (page.width != width || page.height != height) {
    return result
      ..['status'] = 'dimensions ${page.width}x${page.height} differ from libtiff ${width}x$height';
  }
  if (page.image.type != 'bmp') {
    return result..['status'] = 'page is not a BMP raster (${page.image.type})';
  }
  final nativePath = directory['nativeFile'] as String?;
  final rgbaPath = directory['rgbaFile'] as String?;
  if (nativePath == null || !File(nativePath).existsSync()) {
    return result..['status'] = 'native dump file missing';
  }
  final native = File(nativePath).readAsBytesSync();
  final expectedNativeBytes = width * height * samplesPerPixel * (bits == 16 ? 2 : 1);
  if (native.length != expectedNativeBytes) {
    return result
      ..['status'] =
          'native dump holds ${native.length} bytes, geometry needs $expectedNativeBytes';
  }
  Uint8List? rgba;
  if (compareRgba || rgbaPath != null) {
    if (rgbaPath == null || !File(rgbaPath).existsSync()) {
      if (compareRgba) return result..['status'] = 'RGBA dump file missing';
    } else {
      rgba = File(rgbaPath).readAsBytesSync();
      if (rgba.length != width * height * 4) {
        return result
          ..['status'] =
              'RGBA dump holds ${rgba.length} bytes, geometry needs ${width * height * 4}';
      }
    }
  }
  // Palette pages project through the dumped ColorMap with libtiff's
  // fixed rule; the production palette observation is checked lane by
  // lane in _compareNativeSamples.
  List<int> paletteLut = const <int>[];
  if (photometric == 3) {
    final colormapFile = directory['colormapFile'];
    if (colormapFile is! String || !File(colormapFile).existsSync()) {
      return result..['status'] = 'ColorMap dump file missing';
    }
    final raw = File(colormapFile).readAsBytesSync();
    final entries = raw.length ~/ 2;
    if (entries != 3 * (1 << bits)) {
      return result
        ..['status'] = 'ColorMap dump holds $entries entries, geometry needs ${3 * (1 << bits)}';
    }
    final view = ByteData.sublistView(raw);
    var legacy = true;
    for (var i = 0; i < entries; i++) {
      if (view.getUint16(i * 2, Endian.little) > 255) legacy = false;
    }
    paletteLut = [
      for (var i = 0; i < entries; i++)
        legacy ? view.getUint16(i * 2, Endian.little) : view.getUint16(i * 2, Endian.little) >> 8,
    ];
  }
  final bmp = page.image.content;
  final header = ByteData.sublistView(bmp).getUint32(10, Endian.little);
  final stride = (width * 3 + 3) & ~3;
  if (bmp.length < header + stride * height) {
    return result..['status'] = 'BMP shorter than its geometry';
  }
  final nativeView = ByteData.sublistView(native);
  int sample(final int x, final int y, final int channel) {
    final index = (y * width + x) * samplesPerPixel + channel;
    return bits == 16 ? nativeView.getUint16(index * 2, Endian.little) : native[index];
  }

  int gray(final int value) {
    var level = bits == 16
        ? value >> 8
        : bits == 8
        ? value
        : value * 255 ~/ ((1 << bits) - 1);
    if (photometric == 0) level = 255 - level;
    return level;
  }

  var nativeDiffs = 0;
  var rgbaDiffs = 0;
  var pixels = 0;
  for (var y = 0; y < height; y++) {
    final rowBase = header + (height - 1 - y) * stride;
    for (var x = 0; x < width; x++) {
      var sourceX = x;
      var sourceY = y;
      if (orientation == 2 || orientation == 3) sourceX = width - 1 - x;
      if (orientation == 3 || orientation == 4) sourceY = height - 1 - y;
      final at = rowBase + x * 3;
      final blue = bmp[at];
      final green = bmp[at + 1];
      final red = bmp[at + 2];
      int expectedRed;
      int expectedGreen;
      int expectedBlue;
      if (photometric == 3) {
        final index = sample(sourceX, sourceY, 0) & ((1 << bits) - 1);
        expectedRed = paletteLut[index];
        expectedGreen = paletteLut[index + (1 << bits)];
        expectedBlue = paletteLut[index + 2 * (1 << bits)];
      } else if (photometric == 2) {
        expectedRed = sample(sourceX, sourceY, 0);
        expectedGreen = sample(sourceX, sourceY, 1);
        expectedBlue = sample(sourceX, sourceY, 2);
        if (bits == 16) {
          expectedRed >>= 8;
          expectedGreen >>= 8;
          expectedBlue >>= 8;
        }
      } else {
        expectedRed = expectedGreen = expectedBlue = gray(sample(sourceX, sourceY, 0));
      }
      if (red != expectedRed || green != expectedGreen || blue != expectedBlue) nativeDiffs++;
      if (rgba != null) {
        final rgbaAt = (y * width + x) * 4;
        if (red != rgba[rgbaAt] || green != rgba[rgbaAt + 1] || blue != rgba[rgbaAt + 2]) {
          rgbaDiffs++;
        }
      }
      pixels++;
    }
  }
  result['pixels'] = pixels;
  result['nativeDiffs'] = nativeDiffs;
  result['rgbaDiffs'] = rgbaDiffs;
  result['status'] = 'ok';
  return result;
}

/// Reads one 1/2/4-bit sample at pixel [x] of a packed row starting at
/// [base], most significant bit first.
int _subByte(final Uint8List source, final int base, final int x, final int bits) {
  final bitOffset = x * bits;
  final byte = source[base + (bitOffset >> 3)];
  final shift = 8 - bits - (bitOffset & 7);
  return (byte >> shift) & ((1 << bits) - 1);
}

/// The first libtiff directory record of a case, or null when the case
/// carries no reference.
Map<String, Object?>? _firstDirectory(final Map<String, Object?> c) {
  final reference = c['reference'];
  if (reference is! Map) return null;
  final directories = reference['directories'];
  if (directories is! List || directories.isEmpty) return null;
  return Map<String, Object?>.from(directories.first as Map);
}

/// Proves the comparator refuses when it must: a reference that is
/// missing, a dump whose bytes were altered, a flipped planar low bit
/// invisible after projection, a flipped palette index, a flipped
/// ColorMap low byte invisible in the RGBA lane, and a reference command
/// that failed all have to come back as `diverged`.
List<Map<String, Object?>> _selfChecks(
  final List<Map<String, Object?>> cases,
  final String outDir,
) {
  final checks = <Map<String, Object?>>[];
  Map<String, Object?>? firstWhere(
    final bool Function(Map<String, Object?>, Map<String, Object?>) test,
  ) {
    for (final c in cases) {
      final directory = _firstDirectory(c);
      if (directory != null && test(c, directory)) return Map<String, Object?>.from(c);
    }
    return null;
  }

  final comparable = firstWhere(
    (final c, _) => c['expectation'] == 'compare' && c['reference'] != null,
  );
  if (comparable == null) {
    return [
      {'name': 'self-checks', 'behaved': false, 'detail': 'no comparable case available'},
    ];
  }

  void add(final String name, final bool behaved, final String detail) {
    checks.add({'name': name, 'behaved': behaved, 'detail': detail});
  }

  final missing = _compareCase(Map<String, Object?>.from(comparable)..['reference'] = null);
  add(
    'missing-reference',
    missing['verdict'] == 'diverged',
    'a case without a libtiff dump must diverge (${missing['detail']})',
  );

  final reference = Map<String, Object?>.from(comparable['reference']! as Map<String, Object?>);
  final directories = (reference['directories']! as List).cast<Map<String, Object?>>();
  final altered = Map<String, Object?>.from(directories.first);
  final original = File(altered['nativeFile']! as String).readAsBytesSync();
  final tampered = Uint8List.fromList(original);
  tampered[tampered.length ~/ 2] ^= 0x55;
  final tamperedPath = '$outDir/self-check-altered.native';
  File(tamperedPath).writeAsBytesSync(tampered);
  altered['nativeFile'] = tamperedPath;
  final alteredReference = Map<String, Object?>.from(reference)
    ..['directories'] = [altered, ...directories.skip(1)];
  final alteredResult = _compareCase(
    Map<String, Object?>.from(comparable),
    referenceOverride: alteredReference,
  );
  add(
    'altered-dump',
    alteredResult['verdict'] == 'diverged',
    'one flipped byte in the libtiff dump must diverge (${alteredResult['detail']})',
  );

  final failedCommand = Map<String, Object?>.from(comparable)
    ..['dump'] = <String, Object?>{
      'exitCode': 1,
      'argv': <String>['tiff_oracle_dump'],
      'log': 'synthetic',
    };
  final failedResult = _compareCase(failedCommand);
  add(
    'failed-reference-command',
    failedResult['verdict'] == 'diverged',
    'a reference command with a non-zero exit must diverge (${failedResult['detail']})',
  );

  // A flipped low bit of a 16-bit planar sample is invisible after the
  // high-byte projection but must diverge in the native lane.
  final planar16 = firstWhere(
    (final c, final d) =>
        (c['expectation']! as String).startsWith('compare') &&
        d['bitsPerSample'] == 16 &&
        d['samplesPerPixel'] == 3,
  );
  if (planar16 != null) {
    final reference16 = Map<String, Object?>.from(planar16['reference']! as Map<String, Object?>);
    final directories16 = (reference16['directories']! as List).cast<Map<String, Object?>>();
    final directory16 = Map<String, Object?>.from(directories16.first);
    final lowBit = Uint8List.fromList(File(directory16['nativeFile']! as String).readAsBytesSync());
    lowBit[0] ^= 1; // little-endian native dump: the discarded low bit
    final lowBitPath = '$outDir/self-check-planar16-low-bit.native';
    File(lowBitPath).writeAsBytesSync(lowBit);
    directory16['nativeFile'] = lowBitPath;
    reference16['directories'] = [directory16, ...directories16.skip(1)];
    final lowBitResult = _compareCase(planar16, referenceOverride: reference16);
    final page = (lowBitResult['pages']! as List).first as Map;
    final native = page['native']! as Map;
    add(
      'planar16-low-bit-altered',
      lowBitResult['verdict'] == 'diverged' &&
          page['nativeDiffs'] == 0 &&
          native['differences'] == 1,
      'a low-bit change invisible in RGB888 must diverge in the pre-projection '
          'sample lane (${lowBitResult['detail']})',
    );
  } else {
    add('planar16-low-bit-altered', false, 'no 16-bit planar case available');
  }

  // A flipped palette index must diverge in the index lane.
  final palette4 = firstWhere(
    (final c, final d) =>
        (c['expectation']! as String).startsWith('compare') &&
        d['photometric'] == 3 &&
        d['bitsPerSample'] == 4,
  );
  if (palette4 != null) {
    final referenceP = Map<String, Object?>.from(palette4['reference']! as Map<String, Object?>);
    final directoriesP = (referenceP['directories']! as List).cast<Map<String, Object?>>();
    final directoryP = Map<String, Object?>.from(directoriesP.first);
    final indexDump = Uint8List.fromList(
      File(directoryP['nativeFile']! as String).readAsBytesSync(),
    );
    indexDump[0] ^= 0x1; // flips one low bit of the first 4-bit index
    final indexPath = '$outDir/self-check-palette-index.native';
    File(indexPath).writeAsBytesSync(indexDump);
    directoryP['nativeFile'] = indexPath;
    referenceP['directories'] = [directoryP, ...directoriesP.skip(1)];
    final indexResult = _compareCase(palette4, referenceOverride: referenceP);
    final page = (indexResult['pages']! as List).first as Map;
    final indices = page['indices']! as Map;
    add(
      'palette-index-altered',
      indexResult['verdict'] == 'diverged' && (indices['differences']! as int) >= 1,
      'a flipped palette index must diverge in the index lane (${indexResult['detail']})',
    );
  } else {
    add('palette-index-altered', false, 'no 4-bit palette case available');
  }

  // A flipped low byte of a full-range ColorMap entry is invisible after
  // the >>8 projection but must diverge in the ColorMap lane.
  final palette8 = firstWhere(
    (final c, final d) =>
        (c['expectation']! as String).startsWith('compare') &&
        d['photometric'] == 3 &&
        d['bitsPerSample'] == 8,
  );
  if (palette8 != null) {
    final referenceC = Map<String, Object?>.from(palette8['reference']! as Map<String, Object?>);
    final directoriesC = (referenceC['directories']! as List).cast<Map<String, Object?>>();
    final directoryC = Map<String, Object?>.from(directoriesC.first);
    final cmapBytes = Uint8List.fromList(
      File(directoryC['colormapFile']! as String).readAsBytesSync(),
    );
    var flippedLowByte = false;
    for (var i = 0; i + 1 < cmapBytes.length && !flippedLowByte; i += 2) {
      if (cmapBytes[i + 1] != 0) {
        cmapBytes[i] ^= 0x01; // low byte of a 16-bit LE entry
        flippedLowByte = true;
      }
    }
    final cmapPath = '$outDir/self-check-colormap-low-byte.colormap';
    File(cmapPath).writeAsBytesSync(cmapBytes);
    directoryC['colormapFile'] = cmapPath;
    referenceC['directories'] = [directoryC, ...directoriesC.skip(1)];
    final cmapResult = _compareCase(palette8, referenceOverride: referenceC);
    final page = (cmapResult['pages']! as List).first as Map;
    final cmap = page['colormap']! as Map;
    add(
      'colormap-low-byte-altered',
      cmapResult['verdict'] == 'diverged' && (cmap['differences']! as int) >= 1,
      'a ColorMap low-byte change invisible in RGB888 must diverge in the '
          'ColorMap lane (${cmapResult['detail']})',
    );
  } else {
    add('colormap-low-byte-altered', false, 'no 8-bit palette case available');
  }
  return checks;
}
