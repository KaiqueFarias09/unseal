import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_decoder.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_exception.dart';

const String _fixturesDir = 'test/resources/pdf/jpeg2000';

/// Compares the Dart JPEG 2000 decoder against the committed OpenJPEG
/// oracle payloads (JPX02 acceptance).
///
/// Every fixture codestream under `test/resources/pdf/jpeg2000/` must
/// have a Release oracle payload in `oracle/`; a missing oracle is a
/// hard failure, not a skip. Lossless fixtures must match byte-exact.
/// Lossy fixtures must stay inside the ceilings that
/// `tolerances.json` fixed before the first Dart comparison —
/// loosening them invalidates acceptance, so this tool only reads.
///
/// Exits 0 when every fixture passes, 1 on any mismatch and 2 on
/// misuse (missing oracle, unreadable tolerances).
void main() {
  final tolerancesFile = File('$_fixturesDir/tolerances.json');
  if (!tolerancesFile.existsSync()) {
    stderr.writeln('Missing $_fixturesDir/tolerances.json.');
    exitCode = 2;
    return;
  }
  final tolerances =
      const JsonDecoder().convert(tolerancesFile.readAsStringSync()) as Map<String, Object?>;
  final globalMax = tolerances['globalMaxAbsError']! as int;
  final globalRmse = (tolerances['globalRmse']! as num).toDouble();
  final ceilings = (tolerances['fixtures']! as Map<String, Object?>)
      .cast<String, Map<String, Object?>>();

  final fixtures = <String>[
    for (final entry in Directory(_fixturesDir).listSync())
      if (entry is File && (entry.path.endsWith('.j2k') || entry.path.endsWith('.jp2'))) entry.path,
  ]..sort();

  var failures = 0;
  for (final path in fixtures) {
    final name = path.split(Platform.pathSeparator).last.replaceFirst(RegExp(r'\.(j2k|jp2)$'), '');
    final oracleFile = File('$_fixturesDir/oracle/$name.raw');
    if (!oracleFile.existsSync()) {
      stderr.writeln(
        '$name: FAIL (no oracle payload — run '
        'tool/generate_jpx_fixtures.dart first)',
      );
      failures++;
      continue;
    }
    final oracle = oracleFile.readAsBytesSync();
    try {
      final image = decodeJpxImage(Uint8List.fromList(File(path).readAsBytesSync()));
      final actual = <int>[for (final plane in image.components) ...plane.samples];
      if (actual.length != oracle.length) {
        stderr.writeln('$name: FAIL (size ${actual.length} vs oracle ${oracle.length})');
        failures++;
        continue;
      }
      final ceiling = ceilings[name];
      if (ceiling == null) {
        var differing = 0;
        for (var index = 0; index < oracle.length; index++) {
          if (actual[index] != oracle[index]) differing++;
        }
        if (differing != 0) {
          stderr.writeln('$name: FAIL (lossless, $differing samples differ from oracle)');
          failures++;
        } else {
          stdout.writeln('$name: EXACT');
        }
        continue;
      }
      final maxAllowed = (ceiling['maxAbsError']! as num).toDouble();
      final rmseAllowed = (ceiling['rmse']! as num).toDouble();
      if (maxAllowed > globalMax || rmseAllowed > globalRmse) {
        stderr.writeln('$name: FAIL (tolerances.json ceiling exceeds the globals)');
        failures++;
        continue;
      }
      var max = 0;
      var sumSquares = 0;
      for (var index = 0; index < oracle.length; index++) {
        final delta = actual[index] - oracle[index];
        if (delta.abs() > max) max = delta.abs();
        sumSquares += delta * delta;
      }
      final rmse = _sqrt(sumSquares / oracle.length.toDouble());
      if (max > maxAllowed || rmse > rmseAllowed) {
        stderr.writeln(
          '$name: FAIL (max |err| $max > $maxAllowed or '
          'rmse ${rmse.toStringAsFixed(3)} > ${rmseAllowed.toStringAsFixed(3)})',
        );
        failures++;
      } else {
        stdout.writeln(
          '$name: WITHIN TOLERANCE (max |err| $max/$maxAllowed, '
          'rmse ${rmse.toStringAsFixed(3)}/${rmseAllowed.toStringAsFixed(3)})',
        );
      }
    } on JpxUnsupportedException catch (error) {
      // Fixtures whose name carries `-bypass` pin the documented
      // rejection of arithmetic coding bypass: a typed refusal, never
      // invented pixels.
      if (name.contains('-bypass')) {
        stdout.writeln('$name: REJECTED AS DESIGNED (${error.message})');
      } else {
        stderr.writeln('$name: FAIL (unexpected unsupported feature: ${error.message})');
        failures++;
      }
    } on JpxException catch (error) {
      stderr.writeln('$name: FAIL (decode raised: ${error.message})');
      failures++;
    }
  }
  if (failures != 0) {
    stderr.writeln('$failures fixture(s) failed.');
    exitCode = 1;
  } else {
    stdout.writeln('All ${fixtures.length} fixtures passed.');
  }
}

double _sqrt(final double value) {
  if (value <= 0) {
    return 0;
  }
  var guess = value;
  for (var i = 0; i < 40; i++) {
    guess = 0.5 * (guess + value / guess);
  }
  return guess;
}
