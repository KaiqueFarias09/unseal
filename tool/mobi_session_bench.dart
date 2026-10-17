/// B04 baseline measurement: eager parse versus progressive session
/// over the same file, in the same process, on the Dart VM.
///
/// Reports wall time and peak RSS at checkpoints (open, first content
/// load, whole-book walk), plus the session's own instrumentation
/// counters. The output is the MS04 evidence; content parity is the
/// comparator's job, not this tool's.
///
/// ```
/// dart run tool/mobi_session_bench.dart --input book.mobi \
///   --out build/evidence/b04/baseline.json
/// ```
library;

import 'dart:convert';
import 'dart:io';

import 'package:unseal/unseal.dart';

int _rss() => ProcessInfo.currentRss;

Future<void> main(final List<String> arguments) async {
  final inputIndex = arguments.indexOf('--input');
  final outIndex = arguments.indexOf('--out');
  if (inputIndex < 0 || outIndex < 0 || inputIndex + 1 >= arguments.length) {
    stderr.writeln(
      'usage: dart run tool/mobi_session_bench.dart --input <file> --out <report.json>',
    );
    exit(2);
  }
  final inputPath = arguments[inputIndex + 1];
  final outPath = arguments[outIndex + 1];
  final bytes = File(inputPath).readAsBytesSync();

  String walkEager(final Book book) {
    var characters = 0;
    for (final item in book.readingOrder) {
      final file = book.files.html.where((final file) => file.path == item.name).firstOrNull;
      if (file != null) characters += documentTextOf(file).length;
    }

    return '$characters';
  }

  // Warm-up run so JIT noise stays out of the first measurement.
  walkEager(Unseal.parse(bytes));

  // -- eager ----------------------------------------------------------------
  final rssBefore = _rss();
  final watch = Stopwatch()..start();
  final eager = Unseal.parse(bytes);
  final eagerOpenUs = watch.elapsedMicroseconds;
  final rssAfterEagerOpen = _rss();
  watch.reset();
  final eagerWalked = walkEager(eager);
  final eagerWalkUs = watch.elapsedMicroseconds;
  final rssAfterEagerWalk = _rss();

  // -- session --------------------------------------------------------------
  watch.reset();
  final session = await BookSession.open(bytes);
  final sessionOpenUs = watch.elapsedMicroseconds;
  final rssAfterSessionOpen = _rss();
  final metricsAfterOpen = await session.metrics();
  watch.reset();
  final firstName = session.book.readingOrder.first.name;
  final firstText = (await session.loadDocumentText(firstName)) ?? '';
  final firstSectionUs = watch.elapsedMicroseconds;
  final rssAfterFirstSection = _rss();
  watch.reset();
  var sessionCharacters = 0;
  for (final item in session.book.readingOrder) {
    sessionCharacters += ((await session.loadDocumentText(item.name)) ?? '').length;
  }
  final sessionWalkUs = watch.elapsedMicroseconds;
  final rssAfterSessionWalk = _rss();
  final finalMetrics = await session.metrics();
  session.dispose();

  final report = <String, Object?>{
    'schemaVersion': 1,
    'input': {'path': inputPath, 'bytes': bytes.length},
    'measurementMode': {
      'wallClock': 'Stopwatch, microsecond precision, one warmed eager run first',
      'rss': 'ProcessInfo.currentRss sampled at checkpoints (VM process, same run)',
      'note': 'RSS deltas include allocator behavior; treat as bounds, not exact heaps',
    },
    'eager': {
      'openMicros': eagerOpenUs,
      'walkMicros': eagerWalkUs,
      'walkedCharacters': int.parse(eagerWalked),
      'rssAfterOpenBytes': rssAfterEagerOpen,
      'rssDeltaFromBeforeOpenBytes': rssAfterEagerOpen - rssBefore,
      'rssAfterWalkBytes': rssAfterEagerWalk,
    },
    'session': {
      'openMicros': sessionOpenUs,
      'firstSectionMicros': firstSectionUs,
      'firstSectionName': firstName,
      'firstSectionCharacters': firstText.length,
      'walkMicros': sessionWalkUs,
      'walkedCharacters': sessionCharacters,
      'rssAfterOpenBytes': rssAfterSessionOpen,
      'rssAfterFirstSectionBytes': rssAfterFirstSection,
      'rssAfterWalkBytes': rssAfterSessionWalk,
      'metricsAfterOpen': metricsAfterOpen.toWire(),
      'metricsAfterWalk': finalMetrics.toWire(),
    },
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
  };

  final outFile = File(outPath);
  await outFile.parent.create(recursive: true);
  await outFile.writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  stdout.writeln('baseline written to $outPath');
}
