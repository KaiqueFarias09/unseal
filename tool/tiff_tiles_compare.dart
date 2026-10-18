/// Compares Unseal's TIFF page images against the libtiff reference dumps
/// recorded by `tool/tiff_tiles_reference.py`.
///
/// Every case opens through the public API (`Unseal.parse`). Pages are
/// compared pixel by pixel against the native-sample dump under the
/// normalization fixed in `doc/tiff-tiles.md` and, where declared, against
/// libtiff's own RGBA conversion. Expected rejections must fail with the
/// declared typed exception. Three negative self-checks run at the end
/// (missing reference, altered dump, failed reference command) and the
/// run fails unless each of them is reported as a divergence.
///
/// Usage:
///
///     dart run tool/tiff_tiles_compare.dart \
///       --reference=build/evidence/C03/reference.json \
///       --out=build/evidence/C03/compare
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
  var outDir = 'build/evidence/C03/compare';
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
    'native16SamplesCompared': results.fold(
      0,
      (final sum, final r) => sum + (r['native16SamplesCompared'] as int? ?? 0),
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
    'mission': 'C03',
    'head': head,
    'reference': referencePath,
    'referenceSha256': sha256.convert(File(referencePath).readAsBytesSync()).toString(),
    'referenceHead': reference['head'],
    'libtiff': reference['libtiff'],
    'normalization': {
      'unit': 'RGB888 pixel of the BMP page image, rows top-down',
      'tolerance': 0,
      'gray16': 'high byte (v >> 8), inverted for photometric 0',
      'subByte': 'v * 255 ~/ (2^bits - 1), inverted for photometric 0',
      'rgb16': 'native16 samples exact; projected RGB high byte; libtiff RGBA rounds',
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
    'native16SamplesCompared': 0,
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
  final details = <String>[];
  for (var index = 0; index < book.pageCount; index++) {
    final page = book.pages[index];
    final directory = directories[index];
    final pageResult = _comparePage(page, directory, compareRgba: compareRgba);
    if (directory['bitsPerSample'] == 16) {
      final native16 = _compareNative16(
        container,
        container.pageDirectories[index],
        directory,
        nativeBudget,
      );
      pageResult['native16'] = native16;
      result['native16SamplesCompared'] =
          (result['native16SamplesCompared']! as int) + native16['samplesCompared']!;
      if (native16['differences'] != 0 || native16['samplesCompared'] == 0) {
        verdict = 'diverged';
        details.add('page ${index + 1}: native16 comparison $native16');
      }
    }
    (result['pages']! as List).add(pageResult);
    if (pageResult['status'] != 'ok') {
      verdict = 'diverged';
      details.add('page ${index + 1}: ${pageResult['status']}');
      continue;
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
      verdict = 'expected-difference';
      details.add(
        'page ${index + 1}: RGBA lane differs in ${pageResult['rgbaDiffs']} pixels (libtiff rounds 16-bit RGB)',
      );
    }
  }
  result['verdict'] = verdict;
  result['detail'] = details.isEmpty ? 'every pixel matches libtiff' : details.join('; ');
  return result;
}

/// Observe the production decoder's post-predictor samples before its
/// documented RGB888 projection; every low bit is compared with libtiff.
Map<String, int> _compareNative16(
  final TiffContainer container,
  final TiffIfd ifd,
  final Map<String, Object?> directory,
  final TiffDecodeBudget budget,
) {
  final width = directory['width']! as int;
  final height = directory['height']! as int;
  final spp = directory['samplesPerPixel']! as int;
  final reference = ByteData.sublistView(
    File(directory['nativeFile']! as String).readAsBytesSync(),
  );
  var compared = 0;
  var differences = 0;
  decodeTiffPage(
    container,
    ifd,
    budget: budget,
    onDecodedSegment: (final segment) {
      if (segment.bits != 16 || segment.samplesPerPixel != spp) {
        throw StateError('Native sample layout differs from libtiff');
      }
      final actual = ByteData.sublistView(segment.bytes);
      for (var y = 0; y < segment.height; y++) {
        for (var x = 0; x < segment.width; x++) {
          for (var channel = 0; channel < spp; channel++) {
            final at = y * segment.rowBytes + (x * spp + channel) * 2;
            final expectedAt =
                (((segment.rowStart + y) * width + segment.columnStart + x) * spp + channel) * 2;
            if (actual.getUint16(at, segment.endian) !=
                reference.getUint16(expectedAt, Endian.little)) {
              differences++;
            }
            compared++;
          }
        }
      }
    },
  );
  final expected = width * height * spp;
  if (compared != expected) throw StateError('Native sample coverage $compared != $expected');
  return {'samplesCompared': compared, 'differences': differences};
}

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
      if (photometric == 2) {
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

/// Proves the comparator refuses when it must: a reference that is
/// missing, a dump whose bytes were altered, and a reference command that
/// failed all have to come back as `diverged`.
List<Map<String, Object?>> _selfChecks(
  final List<Map<String, Object?>> cases,
  final String outDir,
) {
  final checks = <Map<String, Object?>>[];
  final sample = cases.cast<Map<String, Object?>?>().firstWhere(
    (final c) => c!['expectation'] == 'compare' && c['reference'] != null,
    orElse: () => null,
  );
  if (sample == null) {
    return [
      {'name': 'self-checks', 'behaved': false, 'detail': 'no comparable case available'},
    ];
  }

  final missing = _compareCase(Map<String, Object?>.from(sample)..['reference'] = null);
  checks.add({
    'name': 'missing-reference',
    'behaved': missing['verdict'] == 'diverged',
    'detail': 'a case without a libtiff dump must diverge (${missing['detail']})',
  });

  final reference = Map<String, Object?>.from(sample['reference']! as Map<String, Object?>);
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
    Map<String, Object?>.from(sample),
    referenceOverride: alteredReference,
  );
  checks.add({
    'name': 'altered-dump',
    'behaved': alteredResult['verdict'] == 'diverged',
    'detail': 'one flipped byte in the libtiff dump must diverge (${alteredResult['detail']})',
  });

  final native16Case = cases.firstWhere((final record) {
    final reference = record['reference'] as Map<String, Object?>?;
    return (record['expectation']! as String).startsWith('compare') &&
        reference != null &&
        ((reference['directories']! as List).first as Map)['bitsPerSample'] == 16;
  });
  final native16Reference = Map<String, Object?>.from(
    native16Case['reference']! as Map<String, Object?>,
  );
  final native16Directories = (native16Reference['directories']! as List)
      .cast<Map<String, Object?>>();
  final native16Directory = Map<String, Object?>.from(native16Directories.first);
  final lowBitChanged = Uint8List.fromList(
    File(native16Directory['nativeFile']! as String).readAsBytesSync(),
  );
  lowBitChanged[0] ^= 1; // little-endian native dump: the discarded low bit.
  final lowBitPath = '$outDir/self-check-low-bit.native';
  File(lowBitPath).writeAsBytesSync(lowBitChanged);
  native16Directory['nativeFile'] = lowBitPath;
  native16Reference['directories'] = [native16Directory, ...native16Directories.skip(1)];
  final lowBitResult = _compareCase(native16Case, referenceOverride: native16Reference);
  final lowBitPage = (lowBitResult['pages']! as List).first as Map;
  checks.add({
    'name': 'native16-low-bit-altered',
    'behaved':
        lowBitResult['verdict'] == 'diverged' &&
        lowBitPage['nativeDiffs'] == 0 &&
        (lowBitPage['native16'] as Map)['differences'] == 1,
    'detail':
        'a low-bit change invisible in RGB888 must diverge in the prequantization sample lane',
  });

  final failedCommand = Map<String, Object?>.from(sample)
    ..['dump'] = <String, Object?>{
      'exitCode': 1,
      'argv': <String>['tiff_oracle_dump'],
      'log': 'synthetic',
    };
  final failedResult = _compareCase(failedCommand);
  checks.add({
    'name': 'failed-reference-command',
    'behaved': failedResult['verdict'] == 'diverged',
    'detail': 'a reference command with a non-zero exit must diverge (${failedResult['detail']})',
  });
  return checks;
}
