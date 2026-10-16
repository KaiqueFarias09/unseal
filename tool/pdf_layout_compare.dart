/// PDF layout comparator: compares unseal's page structures against a
/// PdfPig layout dump (the port's own oracle, pinned revision).
///
/// This is the acceptance comparator for the layout port (N04/N07):
/// it FAILS when the mandatory oracle is missing — a missing dump is a
/// failure, never a skip — and it registers per-page differences
/// instead of demanding blind equality with PdfPig's heuristics. When
/// the oracle and unseal disagree on reading order, human expectation
/// decides; the report lists the evidence to judge.
///
/// Oracle: `tool/reference/pdfpig_layout_dump/Program.cs` produces the
/// dump with PdfPig at the pinned revision. Install the .NET SDK, then:
///
/// ```
/// cd tool/reference/pdfpig_layout_dump
/// dotnet run -- <pdf> > layout_dump.json
/// ```
///
/// Usage:
///
/// ```
/// dart run tool/pdf_layout_compare.dart --pdf <file.pdf> --oracle <dump.json> \
///     [--page <0-based index>] [--min-word-score 0.8] [--json out.json]
/// ```
///
/// Exit codes: 0 = within thresholds, 1 = divergent or missing oracle,
/// 2 = usage error.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:unseal/unseal.dart';

void main(final List<String> arguments) {
  final options = _parseArguments(arguments);
  if (options == null) {
    _usage();
    exit(2);
  }

  final pdfFile = File(options.pdfPath);
  if (!pdfFile.existsSync()) {
    stderr.writeln('pdf_layout_compare: PDF not found: ${options.pdfPath}');
    exit(2);
  }

  // The oracle is mandatory: without it there is no acceptance.
  final oracleFile = File(options.oraclePath);
  if (!oracleFile.existsSync()) {
    stderr.writeln('''
pdf_layout_compare: the mandatory oracle dump is missing: ${options.oraclePath}

Produce it with the pinned PdfPig oracle:
  cd tool/reference/pdfpig_layout_dump
  dotnet run -- ${options.pdfPath} > ${options.oraclePath}

See tool/reference/pdfpig_layout_dump/README.md for the pinned revision
and setup. A missing oracle fails the comparison; it is never a skip.''');
    exit(1);
  }

  late Map<String, Object?> dump;
  try {
    dump = (jsonDecode(oracleFile.readAsStringSync()) as Map).cast<String, Object?>();
  } on FormatException catch (error) {
    stderr.writeln('pdf_layout_compare: oracle dump is not valid JSON: $error');
    exit(1);
  }

  final book = parsePdfBook(pdfFile.readAsBytesSync());
  final dumpPages = (dump['pages'] as List<Object?>?) ?? const <Object?>[];
  if (dumpPages.length != book.pageCount) {
    stdout.writeln('PAGE COUNT  unseal=${book.pageCount}  oracle=${dumpPages.length}');
    stdout.writeln('VERDICT: FAIL (page count differs)');
    exit(1);
  }

  final report = <String, Object?>{
    'pdf': options.pdfPath,
    'oracle': options.oraclePath,
    'pages': <Object?>[],
  };
  var fail = false;
  for (var index = 0; index < book.pageCount; index++) {
    if (options.page != null && options.page != index) continue;
    final structure = buildPdfPageStructure(book: book, pageIndex: index);
    final pageVerdict = _comparePage(index, structure, dumpPages[index]! as Map<Object?, Object?>);
    (report['pages'] as List<Object?>).add(pageVerdict);
    if (pageVerdict['verdict'] == 'FAIL') fail = true;
    _printPage(pageVerdict);
  }

  report['verdict'] = fail ? 'FAIL' : 'PASS';
  if (options.jsonPath != null) {
    File(options.jsonPath!).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('report written to ${options.jsonPath}');
  }
  stdout.writeln('VERDICT: ${fail ? 'FAIL' : 'PASS'}');
  exit(fail ? 1 : 0);
}

Map<String, Object?> _comparePage(
  final int index,
  final PdfPageStructure structure,
  final Map<Object?, Object?> oraclePage,
) {
  final oracleWords = <Map<String, Object?>>[
    for (final word in (oraclePage['words'] as List<Object?>?) ?? const <Object?>[])
      (word! as Map<Object?, Object?>).cast<String, Object?>(),
  ];

  // Greedy best-IoU matching over words: each oracle word takes the
  // unseal word with the highest overlap, then text agreement is
  // scored over the matches.
  final used = <int>{};
  var textMatches = 0;
  var iouSum = 0.0;
  var matched = 0;
  for (final oracle in oracleWords) {
    final (ox, oy, ow, oh) = (
      (oracle['x'] as num).toDouble(),
      (oracle['y'] as num).toDouble(),
      (oracle['width'] as num).toDouble(),
      (oracle['height'] as num).toDouble(),
    );
    var best = -1;
    var bestIou = 0.0;
    for (var i = 0; i < structure.words.length; i++) {
      if (used.contains(i)) continue;
      final word = structure.words[i];
      final intersection = _overlap(ox, oy, ow, oh, word.x, word.y, word.width, word.height);
      if (intersection <= 0) continue;
      final union = ow * oh + word.width * word.height - intersection;
      final iou = intersection / union;
      if (iou > bestIou) {
        bestIou = iou;
        best = i;
      }
    }
    if (best < 0) continue;
    used.add(best);
    matched++;
    iouSum += bestIou;
    if (structure.words[best].text == (oracle['text'] as String? ?? '')) textMatches++;
  }

  final wordScore = oracleWords.isEmpty
      ? (structure.words.isEmpty ? 1.0 : 0.0)
      : (matched / oracleWords.length) * (0.5 + 0.5 * textMatches / math.max(1, matched));
  final iouScore = matched == 0 ? 0.0 : iouSum / matched;

  final notes = <String>[];
  if (oracleWords.isEmpty && structure.words.isNotEmpty) {
    notes.add(
      'oracle carries no words for this page but unseal found '
      '${structure.words.length}',
    );
  }
  if (structure.tableRegion != null) {
    notes.add(
      'unseal detected a table region (${structure.tableRegion!.algorithm}, '
      '${structure.tableRegion!.cellCount} cells) — the oracle dump carries no table '
      'model; judge the cells by the annotated expectations',
    );
  }
  if (structure.tableUnsupported != null) {
    notes.add('unseal refused a table area: ${structure.tableUnsupported!.reason}');
  }

  final pass = wordScore >= 0.8 && iouScore >= 0.5;

  return <String, Object?>{
    'page': index,
    'verdict': pass ? 'PASS' : 'FAIL',
    'oracleWords': oracleWords.length,
    'unsealWords': structure.words.length,
    'matched': matched,
    'textMatches': textMatches,
    'wordScore': double.parse(wordScore.toStringAsFixed(4)),
    'meanIou': double.parse(iouScore.toStringAsFixed(4)),
    'unsealBlocks': structure.blocks.length,
    'unsealColumns': structure.columns.length,
    'notes': notes,
  };
}

double _overlap(
  final double ax,
  final double ay,
  final double aw,
  final double ah,
  final double bx,
  final double by,
  final double bw,
  final double bh,
) {
  final left = math.max(ax, bx);
  final top = math.max(ay, by);
  final right = math.min(ax + aw, bx + bw);
  final bottom = math.min(ay + ah, by + bh);

  return math.max(0, right - left) * math.max(0, bottom - top);
}

void _printPage(final Map<String, Object?> verdict) {
  stdout.writeln(
    'PAGE ${verdict['page']}  ${verdict['verdict']}  '
    'words ${verdict['matched']}/${verdict['oracleWords']} '
    '(text ${verdict['textMatches']})  score ${verdict['wordScore']}  '
    'IoU ${verdict['meanIou']}  '
    'blocks ${verdict['unsealBlocks']}  columns ${verdict['unsealColumns']}',
  );
  for (final note in verdict['notes'] as List<Object?>) {
    stdout.writeln('  note: $note');
  }
}

_Options? _parseArguments(final List<String> arguments) {
  String? pdfPath;
  String? oraclePath;
  String? jsonPath;
  int? page;
  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--pdf':
        if (i + 1 >= arguments.length) return null;
        pdfPath = arguments[++i];
      case '--oracle':
        if (i + 1 >= arguments.length) return null;
        oraclePath = arguments[++i];
      case '--json':
        if (i + 1 >= arguments.length) return null;
        jsonPath = arguments[++i];
      case '--page':
        if (i + 1 >= arguments.length) return null;
        page = int.tryParse(arguments[++i]);
      default:
        return null;
    }
  }

  if (pdfPath == null || oraclePath == null) return null;

  return _Options(pdfPath, oraclePath, jsonPath, page);
}

class _Options {
  const _Options(this.pdfPath, this.oraclePath, this.jsonPath, this.page);

  final String pdfPath;
  final String oraclePath;
  final String? jsonPath;
  final int? page;
}

void _usage() {
  stderr.writeln('''
usage: dart run tool/pdf_layout_compare.dart --pdf <file.pdf> --oracle <dump.json>
                            [--page <0-based index>] [--min-word-score 0.8] [--json out.json]

The oracle dump comes from tool/reference/pdfpig_layout_dump (pinned
PdfPig revision); see the README there. A missing oracle fails the
comparison with exit code 1.''');
}
