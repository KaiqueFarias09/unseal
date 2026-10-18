/// JPEG 2000 precision corpus mutation campaign (tag: fuzz).
///
/// Runs the seeded mutation campaign of doc/jpeg2000-precision.md over
/// every precision fixture: truncations and multi-byte mutations must
/// either decode or fail with the codec's typed errors, decoded output
/// must stay consistent, and PDF wrappers must never crash the parse.
/// The regular CI lane excludes this tag; run it explicitly with
/// `dart test --tags fuzz test/fuzz/jpx_precision_fuzz_test.dart`.
@Tags(<String>['fuzz'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_decoder.dart';
import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_exception.dart';
import 'package:unseal/unseal.dart';

import '../../tool/jpx_precision/lanes.dart';
import '../tests/pdf/pdf_fixture_builder.dart';

/// Mutation rounds per fixture (the VM CI suite already runs 96).
const int _rounds = 512;

/// Mutations per round.
const int _flips = 1;

void main() {
  final corpus = loadPrecisionCorpus();

  test('the precision corpus survives truncations and mutations typed', () {
    final failures = <String>[];
    var decoded = 0;
    var rejected = 0;
    for (final fixture in corpus) {
      final base = File('$kJpxPrecisionCorpusDir/${fixture.file}').readAsBytesSync();
      final generator = Random(fixture.name.hashCode ^ 0xC0400000);

      // Deterministic truncation stride: a quarter of the rounds cut the
      // payload, the rest mutate bytes.
      for (var round = 0; round < _rounds; round++) {
        final Uint8List mutated;
        if (round % 4 == 3) {
          mutated = base.sublist(0, 2 + generator.nextInt(base.length - 2));
        } else {
          mutated = Uint8List.fromList(base);
          for (var flip = 0; flip < _flips; flip++) {
            mutated[generator.nextInt(mutated.length)] = generator.nextInt(256);
          }
        }
        try {
          final image = decodeJpxImage(mutated);
          decoded++;
          if (image.outputPlanes.length != image.outputComponentCount) {
            failures.add('${fixture.name}#$round: output plane count');
          }
          if (image.outputPlanes.first.length != image.width * image.height) {
            failures.add('${fixture.name}#$round: output plane size');
          }
          image.toPngBytes();
        } on JpxException {
          rejected++;
        } catch (error) {
          failures.add('${fixture.name}#$round: ${error.runtimeType}: $error');
        }
      }
    }
    expect(failures, isEmpty, reason: 'untyped failures: ${failures.take(8)}');
    expect(decoded + rejected, corpus.length * _rounds);
    expect(decoded, greaterThan(0), reason: 'the campaign exercises the decode path');
    expect(rejected, greaterThan(0), reason: 'the campaign exercises the typed rejection path');
  });

  test('mutated PDFs around precision codestreams never crash the parse', () {
    final failures = <String>[];
    for (final fixture in corpus.where((final f) => f.precision >= 12).take(12)) {
      final base = File('$kJpxPrecisionCorpusDir/${fixture.file}').readAsBytesSync();
      final generator = Random(fixture.name.hashCode ^ 0xC0400Df);
      final width = fixture.width;
      final height = fixture.height;
      for (var round = 0; round < 48; round++) {
        final mutated = Uint8List.fromList(base);
        for (var flip = 0; flip < 2; flip++) {
          mutated[generator.nextInt(mutated.length)] = generator.nextInt(256);
        }
        final pdf = Uint8List.fromList(
          jpxImagePageFixture(
            mutated,
            width: width,
            height: height,
            components: fixture.components.length,
          ).build(),
        );
        try {
          // The parse itself must never throw; undecodable images
          // degrade to geometry-only placements.
          Unseal.parse(pdf);
        } catch (error) {
          failures.add('${fixture.name}#$round: ${error.runtimeType}: $error');
        }
      }
    }
    expect(failures, isEmpty, reason: 'parse crashes: ${failures.take(8)}');
  });
}
