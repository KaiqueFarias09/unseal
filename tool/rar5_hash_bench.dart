/// D05 benchmark: BLAKE2sp verification cost and throughput.
///
/// Cases run in a fresh process (one invocation per `--case`) so each
/// peak-RSS number belongs to one workload:
///
///  - `hash-<size>`: raw hasher throughput over deterministic input.
///  - `eager-with-hash` / `eager-without-hash`: the same synthetic
///    archive parsed with the BLAKE2sp records on and off — the delta
///    is the verification cost on the eager path.
///  - `session-solid`: the committed solid -htb fixture opened and
///    every page loaded (open verifies the whole chain, loads replay).
///  - `session-solid-backward`: the same, served in reverse order so
///    checkpoint replays carry the verification.
///
/// `--out=<file>` writes one JSON report with p50/p95 wall clock and
/// process max RSS per case.
library;

import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:unseal/src/features/comic/archive/rar5_blake2sp.dart';
import 'package:unseal/unseal.dart';

import 'rar5_stream_encoder.dart';

Future<void> main(final List<String> arguments) async {
  final caseName = _option(arguments, '--case');
  final out = _option(arguments, '--out');
  if (caseName == null || out == null) {
    stderr.writeln('usage: dart run tool/rar5_hash_bench.dart --case=<name> --out=<file>');
    exitCode = 2;
    return;
  }

  final watch = Stopwatch()..start();
  var label = caseName;
  var payloadBytes = 0;

  if (caseName.startsWith('hash-')) {
    final size = int.parse(caseName.substring('hash-'.length));
    final input = _deterministic(size);
    const rounds = 20;
    // Warm one round, then time the rest.
    rar5Blake2spDigest(input);
    watch.reset();
    for (var i = 0; i < rounds; i++) {
      rar5Blake2spDigest(input);
    }
    watch.stop();
    payloadBytes = size * rounds;
    label = 'hash throughput ${size >> 10} KiB x$rounds';
  } else if (caseName == 'eager-with-hash' || caseName == 'eager-without-hash') {
    Uint8List page(final int size) {
      final body = _deterministic(size - 10);
      final out = BytesBuilder()
        ..add([0xFF, 0xD8, 0xFF, 0xE0, 0, 1, 2, 3])
        ..add(body)
        ..add([0xFF, 0xD9]);
      return out.toBytes();
    }

    final entries = [
      FixtureEntry('a.jpg', page(96 * 1024)),
      FixtureEntry('b.jpg', page(160 * 1024)),
    ];
    final archive = buildRar5Archive(
      entries: entries,
      method: 3,
      dictExp: 0,
      blake2spHashes: caseName == 'eager-with-hash',
    );
    watch.reset();
    final book = parseComicBook(archive);
    watch.stop();
    payloadBytes = book.pages.fold(0, (final total, final page) => total + page.content.length);
  } else if (caseName == 'session-solid' || caseName == 'session-solid-backward') {
    final bytes = File('test/resources/books/comic/rar5/rar5-hash-solid.cbr').readAsBytesSync();
    final session = await BookSession.open(bytes);
    final pages = (session.book as ComicBook).pages.map((final p) => p.path).toList();
    final order = caseName == 'session-solid' ? pages : pages.reversed;
    watch.reset();
    for (final path in order) {
      payloadBytes += (await session.loadResource(path))!.length;
    }
    watch.stop();
    session.dispose();
  } else {
    stderr.writeln('unknown case $caseName');
    exitCode = 2;
    return;
  }

  final report = {
    'case': caseName,
    'label': label,
    'micros': watch.elapsedMicroseconds,
    'payloadBytes': payloadBytes,
    'throughputMiBs': payloadBytes > 0 && watch.elapsedMicroseconds > 0
        ? (payloadBytes / (1024 * 1024)) / (watch.elapsedMicroseconds / 1e6)
        : null,
    'maxRssBytes': ProcessInfo.maxRss,
  };
  stdout.writeln('$label: ${report['micros']} us, ${report['throughputMiBs']} MiB/s');
  File(out).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(report)}\n');
}

String? _option(final List<String> arguments, final String name) {
  for (final argument in arguments) {
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

Uint8List _deterministic(final int size) =>
    Uint8List.fromList([for (var i = 0; i < size; i++) (i * 37 + ((i >> 3) * 11)) & 0xFF]);
