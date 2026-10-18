/// C02 benchmark: parse and bind costs over the real licensed GT
/// sidecars, with process RSS before and after the measured work.
///
/// Usage:
///
/// ```
/// dart run tool/page_xml_bench.dart [--iterations=20] \
///   [--out=build/c02/outputs/bench.json]
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/unseal.dart';

Future<void> main(final List<String> arguments) async {
  var iterations = 20;
  var outPath = 'build/c02/outputs/bench.json';
  for (var i = 0; i < arguments.length - 1; i++) {
    if (arguments[i] == '--iterations') iterations = int.parse(arguments[i + 1]);
    if (arguments[i] == '--out') outPath = arguments[i + 1];
  }

  final fixtures = <String, Uint8List>{
    for (final name in [
      'kant-aufklaerung-1784-0017.xml',
      'clauren-mimil-1815-0023.xml',
      'petrarca-psalmi-1506-0016.xml',
    ])
      name: File('test/resources/page/$name').readAsBytesSync(),
  };
  // The binding target a host would prepare: the sidecar's own
  // transcription as the reading text, one word per line.
  final kantDocument = parsePageXmlDocument(fixtures['kant-aufklaerung-1784-0017.xml']!);
  final targetText = StringBuffer();
  for (final region in kantDocument.page.regionsInReadingOrder()) {
    for (final line in region.lines) {
      for (final word in line.words) {
        final text = word.text?.text;
        if (text == null || text.isEmpty) continue;
        targetText.writeln(text);
      }
    }
  }
  final target = pageSnapshotOf(targetText.toString());

  final results = <String, Object?>{};
  final rssBefore = ProcessInfo.currentRss;

  for (final entry in fixtures.entries) {
    final parseTimes = <int>[];
    final bindTimes = <int>[];
    PageXmlDocument document = parsePageXmlDocument(entry.value);
    // Warmup.
    for (var i = 0; i < 3; i++) {
      document = parsePageXmlDocument(entry.value);
    }
    for (var i = 0; i < iterations; i++) {
      final watch = Stopwatch()..start();
      document = parsePageXmlDocument(entry.value);
      parseTimes.add(watch.elapsedMicroseconds);
    }
    final bound = bindPageToSnapshot(document: document, target: target);
    for (var i = 0; i < iterations; i++) {
      final watch = Stopwatch()..start();
      bindPageToSnapshot(document: document, target: target);
      bindTimes.add(watch.elapsedMicroseconds);
    }
    int median(final List<int> values) {
      final sorted = List<int>.of(values)..sort();

      return sorted[sorted.length ~/ 2];
    }

    results[entry.key] = {
      'bytes': entry.value.length,
      'words': bound.wordsResolved + bound.wordsAmbiguous + bound.wordsMissing,
      'parseMedianMs': median(parseTimes) / 1000,
      'bindMedianMs': median(bindTimes) / 1000,
    };
  }

  final rssAfter = ProcessInfo.currentRss;
  final report = {
    'iterations': iterations,
    'rssBeforeBytes': rssBefore,
    'rssAfterBytes': rssAfter,
    'rssDeltaBytes': rssAfter - rssBefore,
    'fixtures': results,
  };
  final out = File(outPath);
  if (out.parent.existsSync()) {
    out.writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(report)}\n');
  }
  stdout.writeln(const JsonEncoder.withIndent(' ').convert(report));
}

/// A snapshot over arbitrary text with a bench identity.
CanonicalTextSnapshot pageSnapshotOf(final String text) => CanonicalTextSnapshot(
  identity: PublicationRevision(publicationId: 'bench:page'),
  occurrence: SectionOccurrence(
    sectionIndex: 0,
    resourcePath: 'bench.html',
    readingOrderRevision: 'sha256:${'b' * 64}',
  ),
  profile: TextProfile.of(
    algorithm: 'bench.target',
    options: const <String, String>{},
    planRevision: 'sha256:${'c' * 64}',
  ),
  text: text,
);
