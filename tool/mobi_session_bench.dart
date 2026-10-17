/// Measures eager and progressive reads in separate Dart VM processes.
/// RSS is a process-wide high-water mark, including JIT and VM overhead.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:unseal/unseal.dart';

String? _option(final List<String> arguments, final String key) {
  final index = arguments.indexOf(key);
  return index < 0 || index + 1 == arguments.length ? null : arguments[index + 1];
}

Future<void> main(final List<String> arguments) async {
  final inputPath = _option(arguments, '--input');
  final mode = _option(arguments, '--measure');
  if (inputPath == null) {
    stderr.writeln(
      'usage: dart run tool/mobi_session_bench.dart --input <file> --out <report.json>',
    );
    exit(2);
  }
  if (mode != null) {
    stdout.writeln(jsonEncode(await _measure(inputPath, mode)));
    exit(0);
  }
  final outPath = _option(arguments, '--out');
  if (outPath == null) exit(2);
  final measurements = <String, Object?>{};
  final commands = <Map<String, Object?>>[];
  for (final lane in ['eager', 'session']) {
    final argv = [
      Platform.resolvedExecutable,
      'run',
      Platform.script.toFilePath(),
      '--measure',
      lane,
      '--input',
      inputPath,
    ];
    final result = await Process.run(argv.first, argv.sublist(1));
    commands.add({'argv': argv, 'exitCode': result.exitCode});
    if (result.exitCode != 0) {
      stderr.writeln(result.stderr);
      exit(result.exitCode);
    }
    measurements[lane] = (jsonDecode(result.stdout as String) as Map).cast<String, Object?>();
  }
  final eager = measurements['eager']! as Map<String, Object?>;
  final session = measurements['session']! as Map<String, Object?>;
  if (eager['pid'] == session['pid']) throw StateError('Memory lanes must use separate VMs.');
  final bytes = File(inputPath).readAsBytesSync();
  final report = <String, Object?>{
    'schemaVersion': 2,
    'input': {'path': inputPath, 'bytes': bytes.length, 'sha256': sha256.convert(bytes).toString()},
    'measurementMode': {
      'execution':
          'one fresh VM per lane; bytes loaded before timing; no retained eager book in session VM',
      'wallClock': 'Stopwatch microseconds; session includes isolate startup',
      'rss': 'ProcessInfo.maxRss process-wide high-water mark at checkpoints',
      'note':
          'Includes VM, compiler, allocator and isolate memory; not exact heap allocation or a proof of bounded retention',
    },
    ...measurements,
    'commands': commands,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
  };
  final output = File(outPath);
  await output.parent.create(recursive: true);
  await output.writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln('isolated baseline written to $outPath');
}

Future<Map<String, Object?>> _measure(final String inputPath, final String mode) async {
  final bytes = File(inputPath).readAsBytesSync();
  final report = <String, Object?>{
    'pid': pid,
    'mode': mode,
    'rssBeforeOpenBytes': ProcessInfo.currentRss,
    'peakRssBeforeOpenBytes': ProcessInfo.maxRss,
  };
  final watch = Stopwatch()..start();
  if (mode == 'eager') {
    final book = Unseal.parse(bytes);
    report['openMicros'] = watch.elapsedMicroseconds;
    report['peakRssAfterOpenBytes'] = ProcessInfo.maxRss;
    watch.reset();
    var characters = 0;
    for (final item in book.readingOrder) {
      final file = book.files.html.where((file) => file.path == item.name).firstOrNull;
      if (file != null) characters += documentTextOf(file).length;
    }
    report['walkMicros'] = watch.elapsedMicroseconds;
    report['walkedCharacters'] = characters;
  } else if (mode == 'session') {
    final session = await BookSession.open(bytes);
    try {
      report['openMicros'] = watch.elapsedMicroseconds;
      report['peakRssAfterOpenBytes'] = ProcessInfo.maxRss;
      report['metricsAfterOpen'] = (await session.metrics()).toWire();
      watch.reset();
      final first = session.book.readingOrder.first.name;
      final text = await session.loadDocumentText(first) ?? '';
      report['firstSectionMicros'] = watch.elapsedMicroseconds;
      report['firstSectionCharacters'] = text.length;
      report['peakRssAfterFirstSectionBytes'] = ProcessInfo.maxRss;
      watch.reset();
      var characters = 0;
      for (final item in session.book.readingOrder) {
        characters += (await session.loadDocumentText(item.name) ?? '').length;
      }
      report['walkMicros'] = watch.elapsedMicroseconds;
      report['walkedCharacters'] = characters;
      report['metricsAfterWalk'] = (await session.metrics()).toWire();
    } finally {
      session.dispose();
    }
  } else {
    throw ArgumentError.value(mode, 'mode');
  }
  report['peakRssAfterWalkBytes'] = ProcessInfo.maxRss;
  return report;
}
