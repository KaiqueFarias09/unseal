// Benchmarks for the public text and image utilities:
// [extractPlainText], [countWords], [imageSize] and [sniffImageType].

import 'dart:typed_data';

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'package:unseal/unseal.dart';

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

/// Synthetic CJK sample (built once, untimed): Japanese, Chinese and
/// Korean sentences with full-width punctuation, interleaved with
/// Latin words so both counting rules stay mixed.
const String _cjkParagraph =
    '吾輩は猫である。名前はまだ無い。これはベンチマーク用の日本語の文章です。'
    '这是一段用于基准测试的中文文本，包含全角标点符号！'
    '이것은 벤치마크용 한국어 문장입니다. '
    'Mixed latin words keep the two counting rules interleaved. ';

/// Repeats [_cjkParagraph] to a chapter-sized sample (~28 KB).
final String cjkTextSample = List.filled(200, _cjkParagraph).join();

/// Runs the text and image utility benchmarks.
void runUtilityBenchmarks() {
  final group = BenchmarkGroup('Text & image utilities');
  group.add('extractPlainText — small HTML snippet', () => extractPlainText(_smallHtml));
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
  // Derived untimed: the fixtures are all-Latin, but the word counter
  // runs one rule per CJK code point, so its cost is only visible on a
  // CJK-heavy input.
  group.add(
    'countWords — CJK sample (${formatBytes(cjkTextSample.length)})',
    () => countWords(cjkTextSample),
    inputBytes: cjkTextSample.length,
  );

  _addImageBenchmark(group, ImageType.jpeg);
  _addImageBenchmark(group, ImageType.png);
  group.add(
    'sniffImageType — unknown bytes',
    () => sniffImageType(Uint8List.fromList(List<int>.filled(64, 0x0A))),
  );
}

void _addImageBenchmark(final BenchmarkGroup group, final ImageType type) {
  final bytes = imageSample(type);
  if (bytes == null) return;

  final label = '${type.name} (${formatBytes(bytes.length)})';
  group.add('imageSize — $label', () => imageSize(bytes));
  group.add('sniffImageType — $label', () => sniffImageType(bytes));
}
