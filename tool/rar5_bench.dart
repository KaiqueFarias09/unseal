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
/// - hot per-page loads (decode each time, cache permitting);
/// - solid chains against the same-shape non-solid baseline: the open
///   is a full sequential decode of every entry (documented, not lazy),
///   reverse walks replay through bounded checkpoints, and the memory
///   column reports the process RSS growth of one open.
///
/// Usage: `dart run tool/rar5_bench.dart [--pages=12] [--reps=7] [--solid]`
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
  Uint8List archive({required final int method, final bool solid = false}) => buildRar5Archive(
    entries: [
      for (var p = 0; p < pages; p++)
        FixtureEntry('page-${p.toString().padLeft(3, '0')}.jpg', page),
    ],
    method: method,
    dictExp: 0,
    archiveSolid: solid,
  );
  final compressed = archive(method: 3);
  final stored = archive(method: 0);
  final solid = archive(method: 3, solid: true);

  stdout.writeln(
    'pages=$pages pageBytes=${page.length} '
    'compressedArchive=${compressed.length} storedArchive=${stored.length} '
    'solidArchive=${solid.length} reps=$reps',
  );
  stdout.writeln();

  _report('eager parse (compressed)', () => Unseal.parse(Uint8List.fromList(compressed)), reps);
  _report('eager parse (stored)      ', () => Unseal.parse(Uint8List.fromList(stored)), reps);
  _report('eager parse (solid)       ', () => Unseal.parse(Uint8List.fromList(solid)), reps);
  _report('session open (compressed) ', () {
    final engine = SessionEngine.openBytes(Uint8List.fromList(compressed));
    engine.close();
  }, reps);
  _report('session open (stored)     ', () {
    final engine = SessionEngine.openBytes(Uint8List.fromList(stored));
    engine.close();
  }, reps);
  // The solid open sniffs every page through the sequential chain — the
  // documented cost, directly comparable with the non-solid open.
  _report('session open (solid)      ', () {
    final engine = SessionEngine.openBytes(Uint8List.fromList(solid));
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

  // Solid walks over one session: forward hits the open-time cache;
  // reverse replays through bounded checkpoints, one re-decode per
  // step; repeated reverse passes measure the checkpointed steady
  // state against the non-solid hot baseline.
  final solidEngine = SessionEngine.openBytes(Uint8List.fromList(solid));
  final solidPaths = [for (final p in (solidEngine.book as ComicBook).pages) p.path];
  _report('solid forward walk (cache)', () {
    for (final p in solidPaths) {
      solidEngine.resource(p);
    }
  }, reps);
  _report('solid reverse walk (1st)  ', () {
    for (final p in solidPaths.reversed) {
      solidEngine.resource(p);
    }
  }, 1);
  _report('solid reverse walk (again)', () {
    for (final p in solidPaths.reversed) {
      solidEngine.resource(p);
    }
  }, reps);
  _report('solid repeat decode (revo)', () {
    for (final p in solidPaths.reversed) {
      solidEngine.resource(p);
    }
  }, reps);
  solidEngine.close();

  // Replay steady state: a minimal cache forces every load through the
  // chain — backward steps replay through the bounded checkpoints.
  final replayEngine = SessionEngine.openBytes(
    Uint8List.fromList(solid),
    policy: const SessionPolicy(cacheBytes: 1 << 20),
  );
  final replayPaths = [for (final p in (replayEngine.book as ComicBook).pages) p.path];
  _report('solid reverse walk (cold) ', () {
    for (final p in replayPaths.reversed) {
      replayEngine.resource(p);
    }
  }, reps);
  _report('solid zig-zag walk (cold) ', () {
    for (var i = 0; i < replayPaths.length; i++) {
      replayEngine.resource(replayPaths[replayPaths.length - 1 - i]);
      replayEngine.resource(replayPaths[i]);
    }
  }, reps);
  replayEngine.close();

  // Memory: RSS growth of one solid session open over the baseline of
  // the same-shape non-solid open.
  final solidRss = _rssGrowth(() {
    final one = SessionEngine.openBytes(Uint8List.fromList(solid));
    one.close();
  });
  final plainRss = _rssGrowth(() {
    final one = SessionEngine.openBytes(Uint8List.fromList(compressed));
    one.close();
  });
  stdout.writeln(
    'memory: solid open maxRss growth=${(solidRss / 1024 / 1024).toStringAsFixed(1)}MiB '
    'non-solid=${(plainRss / 1024 / 1024).toStringAsFixed(1)}MiB',
  );
}

int _rssGrowth(final void Function() body) {
  final before = ProcessInfo.currentRss;
  body();

  return ProcessInfo.currentRss - before;
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
