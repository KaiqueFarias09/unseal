import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_decoder.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_exception.dart';

/// The precision/subsampling corpus and its three comparison lanes
/// (doc/jpeg2000-precision.md), shared by the VM test suite and the
/// acceptance tool so both apply one comparator.
const String kJpxPrecisionCorpusDir = 'test/resources/pdf/jpeg2000/precision';

/// One component grid of a fixture as `corpus.json` declares it.
final class PrecisionComponent {
  const PrecisionComponent(this.dx, this.dy, this.width, this.height);

  final int dx;
  final int dy;
  final int width;
  final int height;
}

/// One corpus entry.
final class PrecisionFixture {
  PrecisionFixture.fromJson(final Map<String, Object?> json)
    : name = json['name']! as String,
      file = json['file']! as String,
      producer = json['producer']! as String,
      precision = json['precision']! as int,
      x0 = json['x0']! as int,
      y0 = json['y0']! as int,
      width = json['width']! as int,
      height = json['height']! as int,
      colr = json['colr'] as int?,
      lossless = json['lossless']! as bool,
      lanes = (json['lanes']! as List<Object?>).cast<String>(),
      components = <PrecisionComponent>[
        for (final component in json['components']! as List<Object?>)
          PrecisionComponent(
            (component! as Map<String, Object?>)['dx']! as int,
            (component as Map<String, Object?>)['dy']! as int,
            component['width']! as int,
            component['height']! as int,
          ),
      ];

  final String name;
  final String file;
  final String producer;
  final int precision;
  final int x0;
  final int y0;
  final int width;
  final int height;
  final int? colr;
  final bool lossless;
  final List<String> lanes;
  final List<PrecisionComponent> components;

  int get bytesPerSample => precision <= 8 ? 1 : 2;

  /// Whether the output contract converts this fixture to RGB.
  bool get isSycc => lanes.contains('rgb');
}

/// Lossy ceilings per lane.
final class PrecisionTolerances {
  PrecisionTolerances.fromJson(final Map<String, Object?> json)
    : globalMaxAbsError = json['globalMaxAbsError']! as int,
      globalRmse = (json['globalRmse']! as num).toDouble(),
      lanes = <String, (int, double)>{
        for (final entry in (json['lanes']! as Map<String, Object?>).entries)
          entry.key: (
            (entry.value! as Map<String, Object?>)['maxAbsError']! as int,
            ((entry.value as Map<String, Object?>)['rmse']! as num).toDouble(),
          ),
      };

  final int globalMaxAbsError;
  final double globalRmse;
  final Map<String, (int, double)> lanes;

  /// `(maxAbsError, rmse)` ceiling of [lane]; the globals cap it.
  (int, double) ceiling(final String lane) {
    final (max, rmse) = lanes[lane]!;
    return (min(max, globalMaxAbsError), min(rmse, globalRmse));
  }
}

/// Reads `corpus.json`.
List<PrecisionFixture> loadPrecisionCorpus({final String dir = kJpxPrecisionCorpusDir}) {
  final json = jsonDecode(File('$dir/corpus.json').readAsStringSync()) as Map<String, Object?>;
  return <PrecisionFixture>[
    for (final entry in json['fixtures']! as List<Object?>)
      PrecisionFixture.fromJson(entry! as Map<String, Object?>),
  ];
}

/// Reads `tolerances.json`.
PrecisionTolerances loadPrecisionTolerances({final String dir = kJpxPrecisionCorpusDir}) =>
    PrecisionTolerances.fromJson(
      jsonDecode(File('$dir/tolerances.json').readAsStringSync()) as Map<String, Object?>,
    );

/// Decodes a planar payload (`.bin`/`.rawl`): one byte per sample up to
/// 8 bits, two little-endian bytes above.
List<int> readPrecisionPayload(final Uint8List bytes, final int bytesPerSample) {
  if (bytesPerSample == 1) {
    return bytes;
  }
  if (bytes.length.isOdd) {
    throw const FormatException('16-bit payload has an odd byte count');
  }
  final out = Uint16List(bytes.length ~/ 2);
  for (var index = 0; index < out.length; index++) {
    out[index] = bytes[2 * index] | (bytes[2 * index + 1] << 8);
  }
  return out;
}

/// Sample statistics of one lane.
final class LaneStats {
  const LaneStats({
    required this.samples,
    required this.differing,
    required this.maxAbsError,
    required this.rmse,
    this.sizeMismatch = false,
  });

  final int samples;
  final int differing;
  final int maxAbsError;
  final double rmse;
  final bool sizeMismatch;

  bool get exact => !sizeMismatch && differing == 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'samples': samples,
    'differing': differing,
    'maxAbsError': maxAbsError,
    'rmse': rmse.isFinite ? double.parse(rmse.toStringAsFixed(6)) : null,
    if (sizeMismatch) 'sizeMismatch': true,
  };
}

/// Compares two payloads sample by sample.
LaneStats comparePrecisionSamples(final List<int> actual, final List<int> expected) {
  if (actual.length != expected.length) {
    return LaneStats(
      samples: expected.length,
      differing: expected.length,
      maxAbsError: 1 << 16,
      rmse: double.infinity,
      sizeMismatch: true,
    );
  }
  var max = 0;
  var differing = 0;
  var sumSquares = 0;
  for (var index = 0; index < actual.length; index++) {
    final delta = (actual[index] - expected[index]).abs();
    if (delta != 0) {
      differing++;
    }
    if (delta > max) {
      max = delta;
    }
    sumSquares += delta * delta;
  }
  return LaneStats(
    samples: actual.length,
    differing: differing,
    maxAbsError: max,
    rmse: actual.isEmpty ? 0 : sqrt(sumSquares / actual.length),
  );
}

/// Outcome of one lane of one fixture.
final class LaneOutcome {
  const LaneOutcome({
    required this.lane,
    required this.stats,
    required this.passed,
    required this.reason,
    required this.reference,
  });

  final String lane;
  final LaneStats stats;
  final bool passed;
  final String reason;
  final String reference;

  Map<String, Object?> toJson() => <String, Object?>{
    'lane': lane,
    'reference': reference,
    'passed': passed,
    'reason': reason,
    ...stats.toJson(),
  };
}

/// Outcome of one fixture: geometry check, colour model and lanes.
final class FixtureOutcome {
  const FixtureOutcome({
    required this.fixture,
    required this.lanes,
    required this.geometryProblems,
    required this.colorModel,
    this.decodeError,
  });

  final PrecisionFixture fixture;
  final List<LaneOutcome> lanes;
  final List<String> geometryProblems;
  final String? colorModel;
  final String? decodeError;

  bool get passed =>
      decodeError == null && geometryProblems.isEmpty && lanes.every((final lane) => lane.passed);

  Map<String, Object?> toJson() => <String, Object?>{
    'fixture': fixture.name,
    'file': fixture.file,
    'producer': fixture.producer,
    'precision': fixture.precision,
    'lossless': fixture.lossless,
    'colorModel': colorModel,
    if (decodeError != null) 'decodeError': decodeError,
    if (geometryProblems.isNotEmpty) 'geometryProblems': geometryProblems,
    'lanes': <Object?>[for (final lane in lanes) lane.toJson()],
    'passed': passed,
  };
}

/// Runs the native, upsample and rgb lanes of [fixture] against the
/// reference payloads under [oracleDir] (default `<dir>/oracle`).
FixtureOutcome comparePrecisionFixture(
  final PrecisionFixture fixture,
  final PrecisionTolerances tolerances, {
  final String dir = kJpxPrecisionCorpusDir,
  final String? oracleDir,
}) {
  final oracles = oracleDir ?? '$dir/oracle';
  final JpxImage image;
  try {
    image = decodeJpxImage(File('$dir/${fixture.file}').readAsBytesSync());
  } on JpxException catch (error) {
    return FixtureOutcome(
      fixture: fixture,
      lanes: const <LaneOutcome>[],
      geometryProblems: const <String>[],
      colorModel: null,
      decodeError: error.message,
    );
  }
  final geometry = <String>[];
  if (image.width != fixture.width ||
      image.height != fixture.height ||
      image.x0 != fixture.x0 ||
      image.y0 != fixture.y0 ||
      image.precision != fixture.precision) {
    geometry.add(
      'image ${image.width}x${image.height}@${image.x0},${image.y0} p${image.precision} '
      'differs from corpus.json',
    );
  }
  if (image.componentCount != fixture.components.length) {
    geometry.add('component count ${image.componentCount} differs from corpus.json');
  } else {
    for (var index = 0; index < fixture.components.length; index++) {
      final declared = fixture.components[index];
      final plane = image.components[index];
      if (plane.dx != declared.dx ||
          plane.dy != declared.dy ||
          plane.width != declared.width ||
          plane.height != declared.height) {
        geometry.add('component $index grid differs from corpus.json');
      }
    }
  }
  final expectedModel = fixture.isSycc
      ? JpxColorModel.sycc
      : (fixture.components.length == 1 ? JpxColorModel.gray : JpxColorModel.rgb);
  if (image.colorModel != expectedModel) {
    geometry.add('colour model ${image.colorModel.name} differs from the lanes declared');
  }

  final lanes = <LaneOutcome>[];
  for (final lane in fixture.lanes) {
    final referenceFile = lane == 'native'
        ? '$oracles/${fixture.name}.native.bin'
        : '$oracles/${fixture.name}.$lane.rawl';
    final reference = File(referenceFile);
    if (!reference.existsSync()) {
      lanes.add(
        LaneOutcome(
          lane: lane,
          stats: const LaneStats(
            samples: 0,
            differing: 0,
            maxAbsError: 0,
            rmse: 0,
            sizeMismatch: true,
          ),
          passed: false,
          reason: 'reference payload missing',
          reference: referenceFile,
        ),
      );
      continue;
    }
    final expected = readPrecisionPayload(reference.readAsBytesSync(), fixture.bytesPerSample);
    final actual = lane == 'native'
        ? <int>[for (final plane in image.components) ...plane.samples]
        : <int>[for (final plane in image.outputPlanes) ...plane];
    final stats = comparePrecisionSamples(actual, expected);
    final bool passed;
    final String reason;
    if (fixture.lossless) {
      passed = stats.exact;
      reason = passed ? 'exact' : 'lossless fixture differs from the reference';
    } else {
      final (maxAllowed, rmseAllowed) = tolerances.ceiling(lane);
      passed = !stats.sizeMismatch && stats.maxAbsError <= maxAllowed && stats.rmse <= rmseAllowed;
      reason = passed
          ? 'within the ceiling (max |err| ${stats.maxAbsError}/$maxAllowed, '
                'rmse ${stats.rmse.toStringAsFixed(3)}/$rmseAllowed)'
          : 'beyond the ceiling (max |err| ${stats.maxAbsError}/$maxAllowed, '
                'rmse ${stats.rmse.toStringAsFixed(3)}/$rmseAllowed)';
    }
    lanes.add(
      LaneOutcome(
        lane: lane,
        stats: stats,
        passed: passed,
        reason: reason,
        reference: referenceFile,
      ),
    );
  }
  return FixtureOutcome(
    fixture: fixture,
    lanes: lanes,
    geometryProblems: geometry,
    colorModel: image.colorModel.name,
  );
}
