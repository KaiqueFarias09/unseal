// Benchmarks for the public text and image utilities:
// [extractPlainText], [countWords], [imageSize] and [sniffImageType].

import 'dart:typed_data';

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'package:e_livre/e_livre.dart';

import 'benchmark_harness.dart';
import 'fixtures.dart';

const String _smallHtml = '''
<html><head><title>Benchmark</title>
<style>body { color: #333; }</style></head>
<body><h1 class="title">Chapter &amp; One</h1>
<p>It was a bright cold day in April, and the clocks were striking
thirteen. &#8212; <em>1984</em>, &quot;Opening&quot;</p>
<script>console.log("ignored");</script></body></html>
''';

/// Runs the text and image utility benchmarks.
void runUtilityBenchmarks() {
  final group = BenchmarkGroup('Text & image utilities');

  group.add(
    'extractPlainText — small HTML snippet',
    () => extractPlainText(_smallHtml),
  );
  final html = largestHtmlFile;
  if (html != null) {
    group.add(
      'extractPlainText — chapter (${formatBytes(html.content.length)})',
      () => extractPlainText(html.content),
      inputBytes: html.content.length,
    );
  }
  final plainText = plainTextSample;
  if (plainText != null) {
    group.add(
      'countWords — plain text (${formatBytes(plainText.length)})',
      () => countWords(plainText),
      inputBytes: plainText.length,
    );
  }

  _addImageBenchmark(group, ImageType.jpeg);
  _addImageBenchmark(group, ImageType.png);
  group.add(
    'sniffImageType — unknown bytes',
    () => sniffImageType(Uint8List.fromList(List<int>.filled(64, 0x0A))),
  );
}

void _addImageBenchmark(final BenchmarkGroup group, final ImageType type) {
  final bytes = imageSample(type);
  if (bytes == null) {
    return;
  }
  final label = '${type.name} (${formatBytes(bytes.length)})';
  group.add('imageSize — $label', () => imageSize(bytes));
  group.add('sniffImageType — $label', () => sniffImageType(bytes));
}
