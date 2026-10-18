/// D02 benchmark: parse and bind costs over the real corpus, with process
/// RSS before and after the measured work.
///
/// Usage:
///
/// ```
/// dart run tool/hocr_bench.dart [--iterations=20] \
///   [--out=build/d02/outputs/bench.json]
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/unseal.dart';

Future<void> main(final List<String> arguments) async {
  var iterations = 20;
  var outPath = 'build/d02/outputs/bench.json';
  for (var i = 0; i < arguments.length - 1; i++) {
    if (arguments[i] == '--iterations') iterations = int.parse(arguments[i + 1]);
    if (arguments[i] == '--out') outPath = arguments[i + 1];
  }

  final fixtures = <String, Uint8List>{
    'phototest': File('test/resources/hocr/tesseract/phototest.hocr').readAsBytesSync(),
    'unlv-8071': File('test/resources/hocr/tesseract/unlv-8071.hocr').readAsBytesSync(),
    'jp_vert': File('test/resources/hocr/external/jp_vert.hocr').readAsBytesSync(),
    'features': File('test/resources/hocr/derived/features.hocr').readAsBytesSync(),
  };

  // The binding target a host would prepare: each sidecar's own word
  // sequence, one word per line — the sidecar transcribes itself.
  final targets = <String, CanonicalTextSnapshot>{};
  for (final entry in fixtures.entries) {
    final document = parseHocrDocument(entry.value);
    final buffer = StringBuffer();
    for (final page in document.pages) {
      for (final word in page.words) {
        final text = word.text.trim();
        if (text.isEmpty) continue;
        buffer.writeln(text);
      }
    }
    targets[entry.key] = CanonicalTextSnapshot(
      identity: PublicationRevision(publicationId: 'bench:hocr-${entry.key}'),
      occurrence: SectionOccurrence(
        sectionIndex: 0,
        resourcePath: '${entry.key}.txt',
        readingOrderRevision: 'sha256:${'1' * 64}',
      ),
      profile: TextProfile.of(
        algorithm: 'bench.target',
        options: const <String, String>{},
        planRevision: 'sha256:${'0' * 64}',
      ),
      text: buffer.toString(),
    );
  }

  Duration median(final List<Duration> samples) {
    final sorted = List<Duration>.of(samples)..sort();

    return sorted[sorted.length ~/ 2];
  }

  final results = <String, Object?>{};
  final rssBefore = ProcessInfo.currentRss;
  for (final entry in fixtures.entries) {
    final parseSamples = <Duration>[];
    final bindSamples = <Duration>[];
    HocrDocument? document;
    for (var i = 0; i < iterations; i++) {
      final parseStart = Stopwatch()..start();
      document = parseHocrDocument(entry.value);
      parseStart.stop();
      parseSamples.add(parseStart.elapsed);
      final bindStart = Stopwatch()..start();
      final binding = bindHocrToSnapshot(document: document, target: targets[entry.key]!);
      bindStart.stop();
      bindSamples.add(bindStart.elapsed);
      if (i == iterations - 1) {
        results['${entry.key}.words'] = document.pages.fold<int>(
          0,
          (final sum, final page) => sum + page.words.length,
        );
        results['${entry.key}.lines'] = document.pages.fold<int>(
          0,
          (final sum, final page) => sum + page.lines.length,
        );
        results['${entry.key}.pages'] = document.pages.length;
        results['${entry.key}.bytes'] = entry.value.length;
        results['${entry.key}.resolved'] = binding.wordsResolved;
        results['${entry.key}.ambiguous'] = binding.wordsAmbiguous;
        results['${entry.key}.missing'] = binding.wordsMissing;
        results['${entry.key}.zones'] = binding.pages.fold<int>(
          0,
          (final sum, final page) => sum + page.zones.length,
        );
      }
    }
    results['${entry.key}.parseMedianMs'] = median(parseSamples).inMicroseconds / 1000.0;
    results['${entry.key}.bindMedianMs'] = median(bindSamples).inMicroseconds / 1000.0;
  }
  final rssAfter = ProcessInfo.currentRss;
  results['iterations'] = iterations;
  results['rssBeforeBytes'] = rssBefore;
  results['rssAfterBytes'] = rssAfter;
  results['rssDeltaBytes'] = rssAfter - rssBefore;

  final file = File(outPath)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(results)}\n');
  stdout.writeln('bench: ${results.length} measurements -> ${file.path}');
}
