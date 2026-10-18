/// D02 comparator: parses every corpus document with the Dart hOCR parser,
/// emits the same flat records the independent lxml extractor writes
/// (`tool/reference/hocr/extract_hocr.py`), diffs them field by field,
/// joins the Tesseract hOCR against its own TSV under the contract in
/// `doc/hocr.md`, verifies the committed Tesseract fixtures are the fresh
/// outputs, and pins the typed refusals. Any divergence, any missing or
/// empty reference, and any unexpected verdict exits non-zero.
///
/// Usage:
///
/// ```
/// dart run tool/hocr_compare.dart --root build/d02 \
///   --reference build/d02/outputs/reference.json \
///   --out build/d02/outputs/comparison-diff.json
/// ```
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:unseal/unseal.dart';

const int _maxDivergencesListed = 40;

Future<void> main(final List<String> arguments) async {
  var root = 'build/d02';
  var referencePath = 'build/d02/outputs/reference.json';
  var outPath = 'build/d02/outputs/comparison-diff.json';
  for (var i = 0; i < arguments.length - 1; i++) {
    if (arguments[i] == '--root') root = arguments[i + 1];
    if (arguments[i] == '--reference') referencePath = arguments[i + 1];
    if (arguments[i] == '--out') outPath = arguments[i + 1];
  }
  final referenceFile = File(referencePath);
  if (!referenceFile.existsSync() || referenceFile.lengthSync() == 0) {
    stderr.writeln('compare: reference $referencePath is missing or empty');
    exit(1);
  }
  final reference = jsonDecode(referenceFile.readAsStringSync()) as Map<String, Object?>;
  final records = (reference['records'] as Map<String, Object?>?) ?? const <String, Object?>{};
  final divergences = <String>[];
  var fieldsCompared = 0;
  var documentsCompared = 0;

  void diverge(final String message) {
    if (divergences.length < _maxDivergencesListed) divergences.add(message);
    fieldsCompared++;
  }

  // Record comparison: Dart parser versus the independent lxml records.
  final documentKeys = records.keys.where((final key) => !key.endsWith('.tsv')).toList()..sort();
  if (documentKeys.length < 14) {
    diverge('expected at least 14 corpus documents in the reference, found ${documentKeys.length}');
  }
  final producers = <String, String?>{};
  for (final key in documentKeys) {
    final entry = records[key] as Map<String, Object?>;
    final sourcePath = _sourcePathFor(key, root);
    final recordsFile = File(entry['path'] as String);
    if (!recordsFile.existsSync() || recordsFile.lengthSync() == 0) {
      diverge('$key: lxml records file missing or empty');
      continue;
    }
    final bytes = File(sourcePath).readAsBytesSync();
    final expectedSource = entry['sourceSha256'] as String?;
    if (expectedSource != null && _sha256(bytes) != expectedSource) {
      diverge('$key: source bytes differ from the reference run');
    }
    final HocrDocument document;
    try {
      document = parseHocrDocument(bytes);
    } on Object catch (error) {
      diverge('$key: Dart parser refused a corpus document: $error');
      continue;
    }
    producers[key] = document.system;
    final mine = _documentRecords(document);
    final theirs = jsonDecode(recordsFile.readAsStringSync()) as Map<String, Object?>;
    final before = divergences.length;
    fieldsCompared += _compare(key, mine, theirs, divergences);
    if (divergences.length == before) documentsCompared++;
  }

  // TSV join: the Tesseract hOCR against the TSV of the same pass.
  var tsvRuns = 0;
  var tsvWords = 0;
  var tsvLines = 0;
  var tsvBlocks = 0;
  var tsvParagraphs = 0;
  for (final key in records.keys.where((final key) => key.endsWith('.tsv')).toList()..sort()) {
    final name = key.substring(0, key.length - 4);
    final entry = records[key] as Map<String, Object?>;
    final tsvFile = File(entry['path'] as String);
    if (!tsvFile.existsSync() || tsvFile.lengthSync() == 0) {
      diverge('$key: normalized TSV missing or empty');
      continue;
    }
    final tsv = jsonDecode(tsvFile.readAsStringSync()) as Map<String, Object?>;
    final document = parseHocrDocument(File('$root/tesseract/$name.hocr').readAsBytesSync());
    final pages = (tsv['pages'] as List<Object?>).cast<Map<String, Object?>>();
    if (pages.length != document.pages.length) {
      diverge('$name: TSV has ${pages.length} pages, hOCR has ${document.pages.length}');
      continue;
    }
    for (var p = 0; p < pages.length; p++) {
      final tsvPage = pages[p];
      final page = document.pages[p];
      final frame = page.box;
      fieldsCompared += 2;
      if (frame == null || frame.x1 != tsvPage['width'] || frame.y1 != tsvPage['height']) {
        diverge('$name p$p: page bbox $frame vs TSV ${tsvPage['width']}x${tsvPage['height']}');
      }
      final words = <HocrWord>[];
      final lines = <HocrLine>[];
      final paragraphs = <HocrParagraph>[];
      final blocks = <HocrBlock>[];
      void collect(final List<HocrElement> nodes) {
        for (final node in nodes) {
          switch (node) {
            case HocrBlock():
              if (node.words.isNotEmpty) blocks.add(node);
              collect(node.children);
            case HocrParagraph():
              if (node.words.isNotEmpty) paragraphs.add(node);
              collect(node.children);
            case HocrLine():
              if (node.words.isNotEmpty) lines.add(node);
              words.addAll(node.words);
            case HocrPage():
            case HocrWord():
              break;
          }
        }
      }

      collect(page.children);
      final tsvWordList = (tsvPage['words'] as List<Object?>).cast<Map<String, Object?>>();
      if (tsvWordList.length != words.length) {
        diverge('$name p$p: ${tsvWordList.length} TSV words vs ${words.length} hOCR words');
      }
      for (var i = 0; i < tsvWordList.length && i < words.length; i++) {
        final expected = tsvWordList[i];
        final word = words[i];
        tsvWords++;
        fieldsCompared += 3;
        if (word.text != expected['text']) {
          diverge(
            '$name p$p word $i: text ${jsonEncode(word.text)} vs TSV ${jsonEncode(expected['text'])}',
          );
        }
        if (!_boxEquals(word.box, expected['bbox'])) {
          diverge('$name p$p word $i: bbox ${word.box} vs TSV ${expected['bbox']}');
        }
        final declared = word.confidence?.declared;
        if (declared == null || declared.truncate() != expected['conf']) {
          diverge(
            '$name p$p word $i: x_wconf $declared vs TSV ${expected['conf']} (${expected['confRaw']})',
          );
        }
      }
      for (final (label, mine, theirs) in <(String, List<HocrElement>, List<Object?>)>[
        ('line', lines, tsvPage['lines'] as List<Object?>),
        ('paragraph', paragraphs, tsvPage['paragraphs'] as List<Object?>),
        ('block', blocks, tsvPage['blocks'] as List<Object?>),
      ]) {
        if (mine.length != theirs.length) {
          diverge(
            '$name p$p: ${theirs.length} TSV ${label}s vs ${mine.length} hOCR ${label}s with words',
          );
        }
        for (var i = 0; i < mine.length && i < theirs.length; i++) {
          fieldsCompared++;
          switch (label) {
            case 'line':
              tsvLines++;
            case 'paragraph':
              tsvParagraphs++;
            default:
              tsvBlocks++;
          }
          final expected = (theirs[i] as Map<String, Object?>)['bbox'];
          if (!_boxEquals(mine[i].box, expected)) {
            diverge('$name p$p $label $i: bbox ${mine[i].box} vs TSV $expected');
          }
        }
      }
    }
    tsvRuns++;
  }

  // Committed Tesseract fixtures are the fresh outputs of this reference run.
  final fixtures = (reference['fixtures'] as Map<String, Object?>?) ?? const <String, Object?>{};
  var fixturesVerified = 0;
  if (fixtures.length != 10) {
    diverge('expected 10 Tesseract fixture entries, found ${fixtures.length}');
  }
  for (final entry in fixtures.entries) {
    final info = entry.value as Map<String, Object?>;
    fieldsCompared++;
    final committed = File(info['path'] as String);
    final output =
        (reference['outputs'] as Map<String, Object?>)[entry.key] as Map<String, Object?>?;
    if (info['matchesFreshOutput'] != true ||
        output == null ||
        !committed.existsSync() ||
        _sha256(committed.readAsBytesSync()) != output['sha256']) {
      diverge('${entry.key}: committed fixture is not the fresh Tesseract output');
    } else {
      fixturesVerified++;
    }
  }

  // Typed refusals pinned by the comparator.
  final negatives = <String, String>{};
  for (final entry in _negatives.entries) {
    fieldsCompared++;
    String verdict;
    try {
      parseHocrDocument(Uint8List.fromList(utf8.encode(entry.value.$1)));
      verdict = 'accepted';
    } on HocrUnsupportedFeatureException {
      verdict = 'HocrUnsupportedFeatureException';
    } on HocrException {
      verdict = 'HocrException';
    } on Object catch (error) {
      verdict = 'leaked ${error.runtimeType}';
    }
    negatives[entry.key] = verdict;
    if (verdict != entry.value.$2) {
      diverge('negative ${entry.key}: expected ${entry.value.$2}, got $verdict');
    }
  }

  final result = <String, Object?>{
    'documentsCompared': documentsCompared,
    'documentsExpected': documentKeys.length,
    'fieldsCompared': fieldsCompared,
    'failures': divergences.length,
    'divergences': divergences,
    'producers': producers,
    'tsvRuns': tsvRuns,
    'tsvWordsCompared': tsvWords,
    'tsvLinesCompared': tsvLines,
    'tsvParagraphsCompared': tsvParagraphs,
    'tsvBlocksCompared': tsvBlocks,
    'fixturesVerified': fixturesVerified,
    'negatives': negatives,
    'negativesChecked': negatives.length,
  };
  File(outPath)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(result)}\n');
  stdout.writeln(
    'compare: $documentsCompared/${documentKeys.length} documents, $fieldsCompared fields, '
    '${divergences.length} divergences, $tsvRuns TSV runs ($tsvWords words), '
    '$fixturesVerified fixtures verified, ${negatives.length} negatives',
  );
  for (final line in divergences) {
    stderr.writeln('  $line');
  }
  if (divergences.isNotEmpty || documentsCompared != documentKeys.length || tsvRuns != 5) exit(1);
}

String _sourcePathFor(final String key, final String root) {
  if (key.startsWith('tesseract/')) return '$root/tesseract/${key.substring('tesseract/'.length)}';

  return 'test/resources/hocr/$key';
}

String _sha256(final Uint8List bytes) => sha256.convert(bytes).toString();

bool _boxEquals(final HocrBox? box, final Object? expected) {
  if (box == null || expected is! List<Object?> || expected.length != 4) return false;

  return box.x0 == expected[0] &&
      box.y0 == expected[1] &&
      box.x1 == expected[2] &&
      box.y1 == expected[3];
}

Map<String, Object?> _documentRecords(final HocrDocument document) {
  return <String, Object?>{
    'system': document.system,
    'capabilities': document.capabilities,
    'numberOfPages': document.numberOfPages,
    'languages': document.languages,
    'scripts': document.scripts,
    'pages': <Object?>[for (final page in document.pages) _pageRecord(page)],
  };
}

Map<String, Object?> _common(final HocrElement element, final String role) {
  final box = element.box;

  return <String, Object?>{
    'role': role,
    'className': element.className,
    'tag': element.tagName,
    'id': element.id,
    'lang': element.language,
    'xmlLang': element.xmlLanguage,
    'dir': element.direction,
    'bbox': box == null ? null : <int>[box.x0, box.y0, box.x1, box.y1],
    'textangle': element.textAngle,
    'properties': element.properties,
  };
}

Map<String, Object?> _pageRecord(final HocrPage page) {
  final elements = <Object?>[];
  var blocks = 0;
  var paragraphs = 0;
  var lines = 0;
  var words = 0;
  void walk(final List<HocrElement> nodes) {
    for (final node in nodes) {
      switch (node) {
        case HocrBlock():
          blocks++;
          elements.add(_common(node, 'block'));
          walk(node.children);
        case HocrParagraph():
          paragraphs++;
          elements.add(_common(node, 'paragraph'));
          walk(node.children);
        case HocrLine():
          lines++;
          elements.add(<String, Object?>{
            ..._common(node, 'line'),
            'baseline': node.baseline?.coefficients,
            'hardbreak': node.hasHardBreak,
            'text': node.text,
            'alternatives': node.hasAlternativeReadings,
            'wordCount': node.words.length,
          });
          for (final word in node.words) {
            words++;
            final confidence = word.confidence;
            elements.add(<String, Object?>{
              ..._common(word, 'word'),
              'hasWconf': confidence != null,
              'xWconf': confidence?.declared,
              'xWconfToken': confidence?.declaredToken,
              'text': word.text,
              'alternatives': word.hasAlternativeReadings,
            });
          }
        case HocrPage():
        case HocrWord():
          break;
      }
    }
  }

  walk(page.children);
  final frame = page.frame;

  return <String, Object?>{
    ..._common(page, 'page'),
    'ppageno': page.physicalPageNumber,
    'lpageno': page.logicalPageNumber,
    'image': page.imageName,
    'imagemd5': page.imageMd5,
    'scanRes': page.scanResolutionX == null
        ? null
        : <int>[page.scanResolutionX!, page.scanResolutionY!],
    'frame': frame == null ? null : <int>[frame.x0, frame.y0, frame.x1, frame.y1],
    'frameSource': page.frameSource.name,
    'counts': <String, int>{
      'blocks': blocks,
      'paragraphs': paragraphs,
      'lines': lines,
      'words': words,
    },
    'elements': elements,
  };
}

/// Deep comparison counting leaf fields; numbers compare as doubles so the
/// Python and Dart JSON spellings of the same value agree.
int _compare(final String path, final Object? mine, final Object? theirs, final List<String> out) {
  if (mine is Map<String, Object?> && theirs is Map<String, Object?>) {
    var count = 0;
    final keys = <String>{...mine.keys, ...theirs.keys};
    for (final key in keys) {
      if (!mine.containsKey(key) || !theirs.containsKey(key)) {
        if (out.length < _maxDivergencesListed) out.add('$path.$key: present on one side only');
        count++;
        continue;
      }
      count += _compare('$path.$key', mine[key], theirs[key], out);
    }

    return count;
  }
  if (mine is List<Object?> && theirs is List<Object?>) {
    if (mine.length != theirs.length) {
      if (out.length < _maxDivergencesListed) {
        out.add('$path: length ${mine.length} vs ${theirs.length}');
      }

      return 1;
    }
    var count = 0;
    for (var i = 0; i < mine.length; i++) {
      count += _compare('$path[$i]', mine[i], theirs[i], out);
    }

    return count;
  }
  if (mine is num && theirs is num) {
    if (mine.toDouble() != theirs.toDouble() && out.length < _maxDivergencesListed) {
      out.add('$path: $mine vs $theirs');
    }

    return 1;
  }
  if (mine != theirs && out.length < _maxDivergencesListed) {
    out.add('$path: ${jsonEncode(mine)} vs ${jsonEncode(theirs)}');
  }

  return 1;
}

/// Hostile and out-of-subset documents with the verdict the contract fixes.
const Map<String, (String, String)> _negatives = <String, (String, String)>{
  'order-property': (
    '<div class="ocr_page" title="bbox 0 0 10 10"><span class="ocr_line" title="bbox 0 0 5 5; order 2">a</span></div>',
    'HocrUnsupportedFeatureException',
  ),
  'cflow-property': (
    '<div class="ocr_page" title="bbox 0 0 10 10"><div class="ocr_carea" title=\'bbox 0 0 5 5; cflow "a"\'></div></div>',
    'HocrUnsupportedFeatureException',
  ),
  'inverted-bbox': (
    '<div class="ocr_page" title="bbox 0 0 10 10"><span class="ocr_line" title="bbox 9 0 5 5">a</span></div>',
    'HocrException',
  ),
  'negative-bbox': (
    '<div class="ocr_page" title="bbox 0 0 10 10"><span class="ocr_line" title="bbox -1 0 5 5">a</span></div>',
    'HocrException',
  ),
  'duplicate-property': (
    '<div class="ocr_page" title="bbox 0 0 10 10; bbox 0 0 10 10"></div>',
    'HocrException',
  ),
  'bad-property-name': (
    '<div class="ocr_page" title="bbox 0 0 10 10; Bad 1"></div>',
    'HocrException',
  ),
  'unterminated-quote': (
    '<div class="ocr_page" title=\'bbox 0 0 10 10; image "open\'></div>',
    'HocrException',
  ),
  'non-finite-number': (
    '<div class="ocr_page" title="bbox 0 0 10 10; textangle 1e400"></div>',
    'HocrException',
  ),
  'wconf-out-of-range': (
    '<div class="ocr_page" title="bbox 0 0 10 10"><span class="ocr_line" title="bbox 0 0 5 5"><span class="ocrx_word" title="bbox 0 0 5 5; x_wconf 101">a</span></span></div>',
    'HocrException',
  ),
  'word-outside-line': (
    '<div class="ocr_page" title="bbox 0 0 10 10"><span class="ocrx_word" title="bbox 0 0 5 5">a</span></div>',
    'HocrException',
  ),
  'nested-page': (
    '<div class="ocr_page" title="bbox 0 0 10 10"><div class="ocr_page" title="bbox 0 0 10 10"></div></div>',
    'HocrException',
  ),
  'line-without-bbox': (
    '<div class="ocr_page" title="bbox 0 0 10 10"><span class="ocr_line">a</span></div>',
    'HocrException',
  ),
  'ambiguous-role': (
    '<div class="ocr_page" title="bbox 0 0 10 10"><span class="ocr_line ocrx_word" title="bbox 0 0 5 5">a</span></div>',
    'HocrException',
  ),
  'no-page': ('<html><body><p>plain</p></body></html>', 'HocrException'),
  'duplicate-metadata': (
    '<html><head><meta name="ocr-system" content="a"/><meta name="ocr-system" content="b"/></head><body><div class="ocr_page" title="bbox 0 0 10 10"></div></body></html>',
    'HocrException',
  ),
};
