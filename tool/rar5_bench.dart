import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/unseal.dart';

import 'rar5_stream_encoder.dart';

/// Measures RAR 5 handling costs with the session/eager paths:
///
/// - eager parse of a compressed book versus the same pages stored;
/// - session open (header build sniffs every entry: one decode per
///   compressed page — the documented opening cost);
/// - hot per-page loads (decode each time, cache permitting).
///
/// Usage: `dart run tool/rar5_bench.dart [--pages=12] [--reps=7]`
///
/// Numbers are wall-clock on the host running the tool; treat them as
/// relative evidence between the measured modes, not absolute claims.
void main(final List<String> arguments) {
  var pages = 12;
  var reps = 7;
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i].startsWith('--pages=')) {
      pages = int.parse(arguments[i].substring('--pages='.length));
    } else if (arguments[i].startsWith('--reps=')) {
      reps = int.parse(arguments[i].substring('--reps='.length));
    }
  }

  final page = _repeatingPage(64 * 1024);
  final compressed = buildRar5Archive(
    entries: [
      for (var p = 0; p < pages; p++)
        FixtureEntry('page-${p.toString().padLeft(3, '0')}.jpg', page),
    ],
    method: 3,
    dictExp: 0,
  );
  final stored = buildRar5Archive(
    entries: [
      for (var p = 0; p < pages; p++)
        FixtureEntry('page-${p.toString().padLeft(3, '0')}.jpg', page),
    ],
    method: 0,
    dictExp: 0,
  );

  stdout.writeln(
    'pages=$pages pageBytes=${page.length} '
    'compressedArchive=${compressed.length} storedArchive=${stored.length} reps=$reps',
  );
  stdout.writeln();

  _report('eager parse (compressed)', () => Unseal.parse(Uint8List.fromList(compressed)), reps);
  _report('eager parse (stored)      ', () => Unseal.parse(Uint8List.fromList(stored)), reps);
  _report('session open (compressed) ', () {
    final engine = SessionEngine.openBytes(Uint8List.fromList(compressed));
    engine.close();
  }, reps);
  _report('session open (stored)     ', () {
    final engine = SessionEngine.openBytes(Uint8List.fromList(stored));
    engine.close();
  }, reps);

  // Hot page load: one engine, repeated loads of the same page.
  final engine = SessionEngine.openBytes(Uint8List.fromList(compressed));
  final path = (engine.book as ComicBook).pages.first.path;
  _report('hot load page 0 (cache)   ', () => engine.resource(path), reps);
  engine.close();

  // Cold decode: one engine per load, so the cache never serves it.
  _report('cold open + load (cached) ', () {
    final one = SessionEngine.openBytes(Uint8List.fromList(compressed));
    one.resource(path);
    one.close();
  }, reps);
}

Uint8List _repeatingPage(final int length) {
  // Structured content that compresses like real page images do.
  final data = Uint8List(length);
  for (var i = 0; i < length; i++) {
    data[i] = ((i ~/ 96) * 13) & 0xFF;
  }
  data[0] = 0xFF;
  data[1] = 0xD8;
  data[2] = 0xFF;
  data[3] = 0xE0;
  data[length - 2] = 0xFF;
  data[length - 1] = 0xD9;

  return data;
}

void _report(final String label, final void Function() body, final int reps) {
  // Warm-up outside the sample.
  body();
  final samples = <double>[];
  for (var i = 0; i < reps; i++) {
    final watch = Stopwatch()..start();
    body();
    watch.stop();
    samples.add(watch.elapsedMicroseconds / 1000);
  }
  samples.sort();
  final p50 = samples[samples.length ~/ 2];
  final p95 = samples[(samples.length * 0.95).floor().clamp(0, samples.length - 1)];

  stdout.writeln('$label p50=${p50.toStringAsFixed(2)}ms p95=${p95.toStringAsFixed(2)}ms');
}
