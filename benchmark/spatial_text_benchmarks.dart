// Benchmarks for the spatial text layer: DjVu zone decoding during the
// parse, the shared spatial projection, range lookups, index-aligned
// queries, ALTO parsing and snapshot binding.

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'dart:io';

import 'package:unseal/unseal.dart';

import 'benchmark_harness.dart';

/// Runs the spatial text benchmarks over the real corpus fixtures when
/// present.
Future<void> runSpatialTextBenchmarks() async {
  final group = BenchmarkGroup('Spatial text');

  final goodyFile = File('test/resources/djvu/goody-twoshoes.djvu');
  final altoFile = File('test/resources/alto/goody-page2-tesseract.xml');
  if (!goodyFile.existsSync() || !altoFile.existsSync()) {
    stdout.writeln('[Spatial text] skipped — corpus fixtures missing.');

    return;
  }

  final goody = goodyFile.readAsBytesSync();
  final alto = altoFile.readAsBytesSync();
  final identity = PublicationRevision(
    publicationId: 'benchmark:spatial',
    sourceRevision: 'bench:${goody.length}',
    sourceEvidence: SourceEvidence.host,
  );

  group.add(
    'parseDjvuBook (zones decoded) — goody-twoshoes',
    () => parseDjvuBook(goody),
    inputBytes: goody.length,
    note: '16 pages, TXTz zone trees decoded during parse',
  );

  final book = parseDjvuBook(goody);
  final structures = book.pageStructures;
  group.add(
    'spatial projection — goody-twoshoes (all pages)',
    () {
      for (final structure in structures) {
        structure.spatialPage;
        structure.lookup;
      }
      return;
    },
    inputBytes: goody.length,
    note: 'native tree -> top-left SpatialTextPage + zone lookup',
  );

  var cursor = 0;
  group.add(
    'zone lookup.wordAt sweep — goody-twoshoes',
    () {
      final structure = structures[cursor % structures.length];
      final lookup = structure.lookup!;
      final text = structure.canonicalText;
      if (text.isEmpty) {
        cursor++;
        return;
      }
      final offset = cursor * 7 % text.length;
      lookup.wordAt(offset);
      lookup.regionAt(offset);
      lookup.zonesIn(offset, (offset + 24).clamp(0, text.length));
      cursor++;
      return;
    },
    inputBytes: goody.length,
    note: 'word/region/range queries over the projected zones',
  );

  group.add(
    'page snapshot capture — goody-twoshoes (page 2)',
    () => structures.first.snapshot(identity: identity),
    inputBytes: goody.length,
    note: 'CanonicalTextSnapshot with the hidden-text profile digest',
  );

  group.add(
    'parseAltoDocument — tesseract goody page 2',
    () => parseAltoDocument(alto),
    inputBytes: alto.length,
    note: '14 blocks, 291 strings with confidence',
  );

  final document = parseAltoDocument(alto);
  final target = book.pageStructureAt(1)!.snapshot(identity: identity);
  group.add(
    'bindAltoToSnapshot — tesseract ALTO onto page 2 hidden text',
    () => bindAltoToSnapshot(document: document, target: target),
    inputBytes: alto.length,
    note: 'word mapping with cursor, ambiguity scan and ranges',
  );

  // Registration measures immediately; nothing else to run here.
}
