// Generates a large synthetic CBZ fixture for the progressive-reading
// benchmarks. Deterministic: the same command on the same SDK writes a
// byte-identical file (seed lives in large_fixture_kit.dart).
//
//     dart run tool/generate_large_cbz.dart [--pages=<n>] [--out=<dir>] [--verify]
//
// 160 PNG pages of ~500 KB each (natural page-001.png naming) plus a
// ComicInfo.xml. `--verify` parses the file back through `Unseal.parse`
// and checks the page count before reporting the manifest. Output goes
// to `build/fixtures/` by default (git-ignored); the manifest JSON on
// stdout records path, bytes and page counts.
//
// This tool writes only inside its output directory; it never touches
// test/resources (tracked fixtures are source data).

import 'dart:convert';
import 'dart:io';

import 'package:unseal/unseal.dart';

import 'large_fixture_kit.dart';

Future<void> main(final List<String> arguments) async {
  final out = _optionValue(arguments, '--out') ?? defaultFixtureDirectory;
  final pages = int.tryParse(_optionValue(arguments, '--pages') ?? '') ?? 160;
  final verify = arguments.contains('--verify');
  if (pages < 1) {
    stderr.writeln(
      'usage: dart run tool/generate_large_cbz.dart [--pages=<n>] '
      '[--out=<dir>] [--verify]',
    );
    exitCode = 64;
    return;
  }

  final watch = Stopwatch()..start();
  // A seed distinct from the EPUB tools so regenerating one fixture
  // never depends on the others having run.
  final random = SplitMix64(fixtureSeed + 2);
  const pixelSize = 416; // 416x416 RGB noise deflates to ~507 KB
  final entries = <String, List<int>>{'ComicInfo.xml': utf8.encode(_comicInfo(pageCount: pages))};
  for (var page = 1; page <= pages; page++) {
    entries['page-${page.toString().padLeft(3, '0')}.png'] = buildNoisePng(
      width: pixelSize,
      height: pixelSize,
      random: random,
    );
  }
  final bytes = buildZip(entries);
  const name = 'large-cbz.cbz';
  final path = '$out/$name';
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes, flush: true);

  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'large-fixture-manifest',
    'generator': 'tool/generate_large_cbz.dart',
    'seed': fixtureSeed + 2,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'files': [
      {
        'path': path,
        'bytes': bytes.length,
        'pages': pages,
        'targetPageImageBytes': 500 * 1024,
        if (verify) 'verification': _verifyBook(path, pages: pages),
      },
    ],
  };
  stdout.writeln('cbz: $name in ${watch.elapsedMilliseconds}ms');
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(manifest));
}

String? _optionValue(final List<String> arguments, final String name) {
  for (final argument in arguments) {
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}

/// Parses [path] back through the public API; comic pages surface as
/// non-HTML reading-order items backed by decodable PNG images.
Map<String, Object?> _verifyBook(final String path, {required final int pages}) {
  final bytes = File(path).readAsBytesSync();
  final book = Unseal.parse(bytes);
  final imageFiles = book.files.images.length;
  if (book.readingOrder.length != pages) {
    throw StateError('verification failed: reading order ${book.readingOrder.length}, want $pages');
  }
  if (book.readingOrder.any((final item) => item.isHtml)) {
    throw StateError('verification failed: comic pages must not be html reading-order items');
  }
  if (imageFiles < pages) {
    throw StateError('verification failed: $imageFiles images, want >= $pages');
  }
  final decodable = book.files.images.where((final i) => imageSize(i.content) != null).length;
  if (decodable != imageFiles) {
    throw StateError('verification failed: generated PNG headers do not round-trip');
  }
  return {
    'format': book.format.name,
    'imageFiles': imageFiles,
    'readingOrderLength': book.readingOrder.length,
    'archiveEntries': book.archiveEntries.length,
    'pngHeadersOk': decodable,
  };
}

String _comicInfo({required final int pageCount}) =>
    '''<?xml version="1.0" encoding="utf-8"?>
<ComicInfo>
  <Title>Large CBZ Benchmark Book</Title>
  <Series>Unseal Bench</Series>
  <Number>1</Number>
  <Count>$pageCount</Count>
  <PageCount>$pageCount</PageCount>
  <LanguageISO>en</LanguageISO>
  <BlackAndWhite>No</BlackAndWhite>
  <Manga>No</Manga>
</ComicInfo>
''';
