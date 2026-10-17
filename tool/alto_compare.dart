import 'dart:convert';
import 'dart:io';

import 'package:unseal/alto.dart';

/// Differential comparator between Unseal's ALTO parse and the standard
/// library reference dump.
///
/// Usage:
/// ```
/// dart run tool/alto_compare.dart <alto.xml> <reference.json> [--json <report.json>]
/// ```
///
/// `<reference.json>` comes from `tool/alto_reference_dump.py` (stdlib
/// xml.etree only). The comparator diffs the document header, page
/// declarations, and every nested text block's lines and strings —
/// content and coordinates verbatim, confidences as parsed doubles.
///
/// Exit code 0 means every comparison matched; 1 reports mismatches and
/// writes them to the JSON report when `--json` is given.

Map<String, Object?> compareAltoDocument({
  required final String altoPath,
  required final String referencePath,
}) {
  final document = parseAltoDocument(File(altoPath).readAsBytesSync());
  final reference = jsonDecode(File(referencePath).readAsStringSync()) as Map<String, Object?>;
  final mismatches = <String>[];

  void expect(final Object? actual, final Object? expected, final String what) {
    final matches = expected == null || actual == null
        ? (expected == null) == (actual == null)
        : _sameNumber(actual, expected) || expected.toString() == actual.toString();
    if (!matches) {
      mismatches.add('$what: unseal $actual != reference $expected');
    }
  }

  expect(document.version, reference['version'], 'version');
  expect(document.unit.name, _unitName(reference['unit'] as String?), 'unit');
  expect(document.softwareName, reference['softwareName'], 'softwareName');
  expect(document.softwareVersion, reference['softwareVersion'], 'softwareVersion');
  expect(document.pages.length, (reference['pages'] as List<Object?>).length, 'page count');

  var stringsCompared = 0;
  final pages = reference['pages'] as List<Object?>;
  for (
    var pageIndex = 0;
    pageIndex < pages.length && pageIndex < document.pages.length;
    pageIndex++
  ) {
    final page = pages[pageIndex] as Map<String, Object?>;
    final parsed = document.pages[pageIndex];
    expect(parsed.width, page['width'], 'page ${pageIndex + 1} width');
    expect(parsed.height, page['height'], 'page ${pageIndex + 1} height');
    expect(parsed.printedImageNumber, page['printed'], 'page ${pageIndex + 1} printed');
    expect(parsed.confidence, page['pc'], 'page ${pageIndex + 1} pc');

    // The reference walks every block in document order, flattened
    // through composed children; Unseal's model keeps the same order.
    final flat = <Map<String, Object?>>[];
    void flatten(final Map<String, Object?> block) {
      final lines = block['lines'] as List<Object?>;
      if (lines.isNotEmpty) flat.add(block);
      for (final child in (block['children'] as List<Object?>)) {
        flatten(child as Map<String, Object?>);
      }
    }

    for (final block in (page['blocks'] as List<Object?>)) {
      flatten(block as Map<String, Object?>);
    }
    final parsedBlocks = <AltoBlock>[];
    void collect(final AltoBlock block) {
      if (block.lines.isNotEmpty) parsedBlocks.add(block);
      block.children.forEach(collect);
    }

    for (final block in parsed.blocks) {
      collect(block);
    }
    expect(parsedBlocks.length, flat.length, 'page ${pageIndex + 1} text-block count');
    for (var b = 0; b < flat.length && b < parsedBlocks.length; b++) {
      final expected = flat[b];
      final block = parsedBlocks[b];
      final expectedLines = expected['lines'] as List<Object?>;
      expect(block.lines.length, expectedLines.length, 'page ${pageIndex + 1} block $b line count');
      for (var l = 0; l < expectedLines.length && l < block.lines.length; l++) {
        final expectedLine = expectedLines[l] as Map<String, Object?>;
        final line = block.lines[l];
        expect(line.confidence, expectedLine['wc'], 'page ${pageIndex + 1} block $b line $l wc');
        final expectedStrings = expectedLine['strings'] as List<Object?>;
        expect(
          line.strings.length,
          expectedStrings.length,
          'page ${pageIndex + 1} block $b line $l string count',
        );
        for (var s = 0; s < expectedStrings.length && s < line.strings.length; s++) {
          final expectedString = expectedStrings[s] as Map<String, Object?>;
          final string = line.strings[s];
          expect(
            string.content,
            expectedString['content'],
            'page ${pageIndex + 1} block $b line $l string $s content',
          );
          expect(string.rect.x, expectedString['hpos'], 'string $s hpos');
          expect(string.rect.y, expectedString['vpos'], 'string $s vpos');
          expect(string.rect.width, expectedString['width'], 'string $s width');
          expect(string.rect.height, expectedString['height'], 'string $s height');
          expect(string.confidence, expectedString['wc'], 'string $s wc');
          stringsCompared++;
        }
      }
    }
  }

  return <String, Object?>{
    'tool': 'alto_compare',
    'alto': altoPath,
    'stringsCompared': stringsCompared,
    'pagesCompared': document.pages.length,
    'mismatches': mismatches,
    'verdict': mismatches.isEmpty ? 'pass' : 'fail',
  };
}

void main(final List<String> args) {
  final report = compareAltoDocument(altoPath: args[0], referencePath: args[1]);
  final jsonIndex = args.indexOf('--json');
  if (jsonIndex >= 0) {
    File(args[jsonIndex + 1]).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  }
  final mismatches = report['mismatches']! as List<String>;
  if (mismatches.isNotEmpty) {
    for (final mismatch in mismatches.take(20)) {
      stderr.writeln(mismatch);
    }
    stderr.writeln('${report['verdict']}: ${mismatches.length} mismatches');
    exitCode = 1;
  } else {
    stdout.writeln('pass: ${report['pagesCompared']} pages, ${report['stringsCompared']} strings');
  }
}

String? _unitName(final String? referenceUnit) => switch (referenceUnit) {
  'pixel' => 'pixel',
  'mm10' => 'millimeter10',
  'inch1200' => 'inch1200',
  _ => null,
};

bool _sameNumber(final Object a, final Object b) {
  final left = a is num ? a.toDouble() : double.tryParse('$a');
  final right = b is num ? b.toDouble() : double.tryParse('$b');

  return left != null && right != null && left == right;
}
