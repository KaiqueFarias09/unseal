import 'dart:convert' as convert;

import 'dart:io' as io;

import 'package:unseal/unseal.dart';

/// Size/time/peak-RSS benchmark for the OPDS 2.0 parser (acceptance OJ08).
///
/// Generates synthetic feeds at increasing sizes from the committed
/// fixture shapes, measures parse wall time and process RSS delta, and
/// writes a JSON record for the acceptance evidence. Run:
///
///   dart run tool/opds2_bench.dart --out build/evidence/C05/bench.json
void main(final List<String> arguments) {
  var output = 'build/evidence/C05/bench.json';
  int? single;
  for (var index = 0; index < arguments.length - 1; index++) {
    if (arguments[index] == '--out') output = arguments[index + 1];
    if (arguments[index] == '--single') single = int.parse(arguments[index + 1]);
  }
  if (single != null) {
    // AOT single-size mode: run once under an external time reporter so a
    // parent process can capture the peak resident set size for this
    // exact size.
    final source = _feedWithPublications(single);
    final bytes = convert.utf8.encode(source);
    final watch = Stopwatch()..start();
    final feed = parseOpds2FeedBytes(bytes);
    watch.stop();
    io.stderr.writeln(
      'opds2 single: $single publications, ${bytes.length} bytes, '
      '${watch.elapsedMicroseconds} micros, '
      'title=${feed.metadata.title.resolve()}',
    );

    return;
  }

  final rows = <Object?>[];
  for (final size in const <int>[10, 50, 200, 500, 2000]) {
    final source = _feedWithPublications(size);
    final bytes = convert.utf8.encode(source);

    // Warm-up, then measure.
    parseOpds2Feed(source);
    final rssBefore = io.ProcessInfo.currentRss;
    final watch = Stopwatch()..start();
    Opds2Feed? last;
    for (var index = 0; index < 5; index++) {
      last = parseOpds2FeedBytes(bytes);
    }
    watch.stop();
    final rssAfter = io.ProcessInfo.currentRss;

    rows.add(<Object?, Object?>{
      'publications': size,
      'bytes': bytes.length,
      'meanMillisPerParse': watch.elapsedMilliseconds / 5,
      'rssDeltaKib': (rssAfter - rssBefore) ~/ 1024,
      'sanityTitle': last!.metadata.title.resolve(),
      'sanityPublications': last.publications.length,
    });
    io.stderr.writeln(
      'opds2 bench: ${size.toString().padLeft(5)} publications, '
      '${(bytes.length / 1024).toStringAsFixed(0).padLeft(7)} KiB, '
      '${(watch.elapsedMilliseconds / 5).toStringAsFixed(2)} ms/parse, '
      'rssDelta ${(rssAfter - rssBefore) ~/ 1024} KiB',
    );
  }

  // The real corpus feeds keep the benchmark anchored to actual catalogs.
  final corpusRows = <Object?>[];
  for (final name in const <String>[
    'feedbooks-home.json',
    'feedbooks-navigation.json',
    'feedbooks-publications.json',
    'synthetic-acquisition-detail.json',
    'synthetic-facets-groups.json',
    'synthetic-unicode-escapes.json',
  ]) {
    final source = io.File('test/resources/opds/feeds/$name').readAsStringSync();
    parseOpds2Feed(source);
    final watch = Stopwatch()..start();
    final feed = parseOpds2Feed(source);
    watch.stop();
    corpusRows.add(<Object?, Object?>{
      'fixture': name,
      'bytes': convert.utf8.encode(source).length,
      'microsPerParse': watch.elapsedMicroseconds,
      'publications':
          feed.publications.length +
          feed.groups.fold<int>(0, (final sum, final group) => sum + group.publications.length),
    });
  }

  final report = <Object?, Object?>{
    'benchmark': 'opds2_parse_by_size',
    'dartVersion': io.Platform.version,
    'sizes': rows,
    'corpusFixtures': corpusRows,
  };
  final target = io.File(output);
  target.parent.createSync(recursive: true);
  target.writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(report)}\n');
  io.stdout.writeln('wrote $output');
}

String _feedWithPublications(final int count) {
  final publications = StringBuffer();
  for (var index = 0; index < count; index++) {
    if (index > 0) publications.write(',');
    publications
      ..write('{"metadata": {"title": "Benchmark book number $index')
      ..write('", "author": {"name": "Author ')
      ..write(index % 97)
      ..write('", "sortAs": "Author, "}, "identifier": "urn:bench:')
      ..write(index)
      ..write(
        '", "language": ["en"], "description": "A generated publication used to size the parser."},',
      )
      ..write('"links": [')
      ..write(
        '{"rel": "self", "href": "https://bench.example/pub/$index.json", "type": "application/opds-publication+json"},',
      )
      ..write(
        '{"rel": ["buy", "http://opds-spec.org/acquisition/buy"], "href": "https://bench.example/buy/$index", "type": "text/html", "properties": {"price": {"value": 9.9, "currency": "BRL"}}}],',
      )
      ..write('"images": [')
      ..write(
        '{"href": "https://bench.example/covers/$index-small.png", "type": "image/png", "width": 200, "height": 300},',
      )
      ..write(
        '{"href": "https://bench.example/covers/$index.jpg", "type": "image/jpeg", "width": 1200, "height": 1800}]}',
      );
  }

  return '{"metadata": {"title": "OPDS 2.0 benchmark feed", "identifier": "https://bench.example/feed",'
      '"modified": "2026-10-18T00:00:00Z", "numberOfItems": $count, "itemsPerPage": $count, "currentPage": 1},'
      '"links": ['
      '{"rel": "self", "href": "https://bench.example/feed", "type": "application/opds+json"},'
      '{"rel": "next", "href": "https://bench.example/feed?page=2", "type": "application/opds+json"},'
      '{"rel": "search", "href": "https://bench.example/search{?query}", "type": "application/opds+json", "templated": true}],'
      '"navigation": ['
      '{"href": "https://bench.example/by-title", "title": "By title", "type": "application/opds+json"},'
      '{"href": "https://bench.example/by-author", "title": "By author", "type": "application/opds+json"}],'
      '"publications": [$publications]}';
}
