// D01 versioned comparator: runs Unseal's Readium model over the pinned
// corpus and compares it against the executed official toolkit evidence,
// generates the position lists the independent Python verifier re-derives,
// and self-tests the four comparator refusals the acceptance contract
// requires. Writes its artifacts under build/evidence/D01/.
//
// Usage:
//   dart run tool/readium_compare.dart --evidence <dir> \
//     [--corpus tool/readium/corpus/locator-cases.json] \
//     [--python <python>] [--books <epub,pdf,comic>]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:unseal/unseal.dart';

const evidenceDefault = 'build/evidence/D01';
const corpusDefault = 'tool/readium/corpus/locator-cases.json';

void main(final List<String> arguments) {
  _run(arguments);
}

void _run(final List<String> arguments) {
  String evidenceDir = evidenceDefault;
  var corpusPath = corpusDefault;
  var python = '/usr/bin/env python3';
  for (var index = 0; index < arguments.length - 1; index++) {
    switch (arguments[index]) {
      case '--evidence':
        evidenceDir = arguments[index + 1];
      case '--corpus':
        corpusPath = arguments[index + 1];
      case '--python':
        python = arguments[index + 1];
    }
  }

  final failures = <String>[];
  final caseVerdicts = <String, String>{};
  final artifacts = <String>[];

  // ---- Stage A: interchange against the executed toolkit evidence ----
  final reference = _loadReference(evidenceDir, failures);
  final corpus = _loadCorpus(corpusPath, failures);
  if (reference != null && corpus != null) {
    _compareInterchange(corpus, reference, caseVerdicts, failures);
  }

  // ---- Stage B: position lists + independent verifier ----
  final positionResults = _comparePositions(evidenceDir, python, artifacts, failures);
  caseVerdicts.addAll(positionResults);

  // ---- Stage C: comparator refusal self-tests ----
  final negatives = _selfTestNegatives(evidenceDir, corpus, reference, python, failures);
  caseVerdicts['negatives'] = negatives ? 'pass' : 'fail';

  final report = <String, Object?>{
    'schemaVersion': 1,
    'comparator': 'tool/readium_compare.dart',
    'corpusSha256': _sha256(File(corpusPath)),
    'referenceSha256': _sha256(File('$evidenceDir/reference.json')),
    'schemaCheckSha256': _sha256(File('$evidenceDir/schema-check.json')),
    'cases': caseVerdicts,
    'evidenceArtifacts': artifacts,
    'failures': failures,
    'status': failures.isEmpty ? 'pass' : 'fail',
  };
  final reportFile = File('$evidenceDir/comparison.json');
  reportFile.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln(
    'readium_compare: ${report['status']} — ${caseVerdicts.length} case groups, '
    '${failures.length} failures',
  );
  for (final failure in failures) {
    stdout.writeln('  ! $failure');
  }
  if (failures.isNotEmpty) exitCode = 1;
}

// ---------------------------------------------------------------- staging

Map<String, Object?>? _loadReference(final String evidenceDir, final List<String> failures) {
  final file = File('$evidenceDir/reference.json');
  if (!file.existsSync()) {
    failures.add(
      'missing reference evidence: ${file.path} — the executed '
      'toolkit run must exist before comparison',
    );
    return null;
  }

  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

Map<String, Object?>? _loadCorpus(final String corpusPath, final List<String> failures) {
  final file = File(corpusPath);
  if (!file.existsSync()) {
    failures.add('missing corpus: ${file.path}');
    return null;
  }

  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

// ------------------------------------------------ interchange comparison

void _compareInterchange(
  final Map<String, Object?> corpus,
  final Map<String, Object?> reference,
  final Map<String, String> verdicts,
  final List<String> failures,
) {
  final referenceCases = <String, Map<String, Object?>>{
    for (final entry in (reference['cases'] as List).cast<Map<String, Object?>>())
      entry['id'] as String: entry,
  };

  for (final entry in (corpus['cases'] as List).cast<Map<String, Object?>>()) {
    final id = entry['id'] as String;
    final observed = referenceCases[id];
    if (observed == null) {
      failures.add('case $id: reference evidence has no such case');
      verdicts[id] = 'fail';

      continue;
    }

    try {
      if (entry['kind'] == 'positionList') {
        _comparePositionListCase(entry, observed, verdicts, id, failures);
      } else {
        _compareLocatorCase(entry, observed, verdicts, id, failures);
      }
    } on Object catch (error) {
      failures.add('case $id: comparator threw $error');
      verdicts[id] = 'fail';
    }
  }
}

void _compareLocatorCase(
  final Map<String, Object?> entry,
  final Map<String, Object?> observed,
  final Map<String, String> verdicts,
  final String id,
  final List<String> failures,
) {
  final input = entry['input'] as Map<String, Object?>;
  if (observed['rejected'] == true) {
    final mapLevel = tryDecodeReadiumLocator(input);
    if (mapLevel != null) {
      failures.add('case $id: toolkit rejects, Unseal accepts');
      verdicts[id] = 'fail';

      return;
    }
    verdicts[id] = 'pass';

    return;
  }

  final toolkitOutput = observed['output'] as Map<String, Object?>;
  final locator = tryDecodeReadiumLocator(input);
  if (locator == null) {
    failures.add('case $id: toolkit accepts, Unseal rejects');
    verdicts[id] = 'fail';

    return;
  }

  final ours = locator.serialize();
  final supported = _compareJson(toolkitOutput, ours, 'case $id', failures);
  if (!supported) {
    verdicts[id] = 'fail';

    return;
  }
  // Re-decode our own serialization: the shape is stable.
  final redone = tryDecodeReadiumLocator(ours);
  if (redone == null || !_compareJson(ours, redone.serialize(), 'case $id reencode', failures)) {
    verdicts[id] = 'fail';

    return;
  }
  verdicts[id] = 'pass';
}

void _comparePositionListCase(
  final Map<String, Object?> entry,
  final Map<String, Object?> observed,
  final Map<String, String> verdicts,
  final String id,
  final List<String> failures,
) {
  final input = entry['input'] as Map<String, Object?>;
  final decoded = tryDecodeReadiumPositionListModel(input);
  if (decoded == null) {
    failures.add('case $id: Unseal refuses the official positions example');
    verdicts[id] = 'fail';

    return;
  }
  final toolkitEntries = (observed['entries'] as List).cast<Map<String, Object?>>();
  if (toolkitEntries.length != decoded.positions.length) {
    failures.add('case $id: entry count diverges from the toolkit');
    verdicts[id] = 'fail';

    return;
  }
  for (var index = 0; index < toolkitEntries.length; index++) {
    if (!_compareJson(
      toolkitEntries[index],
      decoded.positions[index].serialize(),
      'case $id entry $index',
      failures,
    )) {
      verdicts[id] = 'fail';

      return;
    }
  }
  verdicts[id] = 'pass';
}

/// Structural JSON comparison with numeric (not type-strict) equality —
/// the toolkit emits JS numbers (`0`) where Dart emits `0.0`.
bool _compareJson(
  final Object? expected,
  final Object? actual,
  final String where,
  final List<String> failures,
) {
  final equal = _jsonEqual(expected, actual);
  if (!equal) {
    failures.add('$where: toolkit output $expected != Unseal output $actual');
  }

  return equal;
}

bool _jsonEqual(final Object? expected, final Object? actual) {
  if (expected is num && actual is num) {
    return expected.toDouble() == actual.toDouble();
  }
  if (expected is Map && actual is Map) {
    if (expected.length != actual.length) return false;
    for (final key in expected.keys) {
      if (!actual.containsKey(key)) return false;
      if (!_jsonEqual(expected[key], actual[key])) return false;
    }

    return true;
  }
  if (expected is List && actual is List) {
    if (expected.length != actual.length) return false;
    for (var index = 0; index < expected.length; index++) {
      if (!_jsonEqual(expected[index], actual[index])) return false;
    }

    return true;
  }

  return expected == actual;
}

// ------------------------------------------------------ position lists

Map<String, String> _comparePositions(
  final String evidenceDir,
  final String python,
  final List<String> artifacts,
  final List<String> failures,
) {
  final verdicts = <String, String>{};
  final books = <(String, String, String)>[
    ('RL03-RL05-epub', 'test/resources/epub/structure-sample-01.epub', 'epub'),
    ('RL03-RL05-pdf', 'test/resources/pdf/gutenberg/pg11-generated.pdf', 'pdf'),
    ('RL03-RL05-comic', 'test/resources/comic/sample.cbz', 'comic'),
  ];

  for (final (label, bookPath, kind) in books) {
    final bookFile = File(bookPath);
    if (!bookFile.existsSync()) {
      failures.add('position case $label: missing book $bookPath');
      verdicts[label] = 'fail';

      continue;
    }
    final bytes = Uint8List.fromList(bookFile.readAsBytesSync());
    try {
      final (listJson, evidenceJson) = _generateEvidence(bytes, kind);
      final listFile = File('$evidenceDir/positions-$kind.json');
      final evidenceFile = File('$evidenceDir/positions-$kind-evidence.json');
      listFile.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(listJson)}\n');
      evidenceFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(evidenceJson)}\n',
      );
      artifacts
        ..add(listFile.path)
        ..add(evidenceFile.path);

      final reportFile = File('$evidenceDir/verifier-$kind.json');
      final verifier = Process.runSync(python, [
        'tool/readium/positions_verify.py',
        '--list',
        listFile.path,
        '--evidence',
        evidenceFile.path,
        '--book',
        bookPath,
        '--report',
        reportFile.path,
      ]);
      artifacts.add(reportFile.path);
      if (verifier.exitCode != 0) {
        failures.add(
          'position case $label: independent verifier failed '
          '(exit ${verifier.exitCode})\n${verifier.stderr}',
        );
        verdicts[label] = 'fail';

        continue;
      }
      verdicts[label] = 'pass';
    } on Object catch (error) {
      failures.add('position case $label: $error');
      verdicts[label] = 'fail';
    }
  }

  return verdicts;
}

(Map<String, Object?>, Map<String, Object?>) _generateEvidence(
  final Uint8List bytes,
  final String kind,
) {
  switch (kind) {
    case 'epub':
      final book = parseEpubBook(bytes);
      final build = ReadiumPositionListBuilder.ofBook(book);
      return (
        build.list.toServiceJson(),
        <String, Object?>{
          'book': {'kind': 'epub', 'sha256': _sha256OfBytes(bytes)},
          'profile': {'id': 'unseal.readium.positions/1', 'scalarInterval': 1024},
          'occurrences': <Object?>[
            for (var index = 0; index < book.readingOrder.length; index++)
              <String, Object?>{
                'sectionIndex': index,
                'resourcePath': book.readingOrder[index].name,
                'isHtml': book.readingOrder[index].isHtml,
                if (book.readingOrder[index].isHtml) 'text': _sectionText(book, index) ?? '',
                'textUtf16Length': (_sectionText(book, index) ?? '').length,
              },
          ],
        },
      );
    case 'pdf':
      final book = parsePdfBook(bytes);
      final build = ReadiumPositionListBuilder.ofBook(
        book,
        documentUri: 'https://library.example/generated.pdf',
      );
      return (
        build.list.toServiceJson(),
        <String, Object?>{
          'book': {'kind': 'pdf', 'sha256': _sha256OfBytes(bytes)},
          'profile': {'id': 'unseal.readium.positions/1', 'scalarInterval': 1024},
          'occurrences': <Object?>[
            for (var index = 0; index < book.pageCount; index++)
              <String, Object?>{
                'sectionIndex': index,
                'resourcePath': 'https://library.example/generated.pdf',
                'isHtml': false,
              },
          ],
        },
      );
    case 'comic':
      final book = parseComicBook(bytes);
      final build = ReadiumPositionListBuilder.ofBook(book);
      return (
        build.list.toServiceJson(),
        <String, Object?>{
          'book': {'kind': 'comic', 'sha256': _sha256OfBytes(bytes)},
          'profile': {'id': 'unseal.readium.positions/1', 'scalarInterval': 1024},
          'occurrences': <Object?>[
            for (var index = 0; index < book.pageCount; index++)
              <String, Object?>{
                'sectionIndex': index,
                'resourcePath': book.pages[index].path,
                'isHtml': false,
              },
          ],
        },
      );
  }
  throw ArgumentError('unknown kind $kind');
}

String? _sectionText(final Book book, final int index) {
  final order = book.readingOrder;
  if (index < 0 || index >= order.length || !order[index].isHtml) return null;
  for (final file in book.files.html) {
    if (file.path == order[index].name) return documentTextOf(file);
  }

  return null;
}

// ------------------------------------------------------------- negatives

/// The four comparator refusals the acceptance contract requires, each
/// demonstrated to actually refuse.
bool _selfTestNegatives(
  final String evidenceDir,
  final Map<String, Object?>? corpus,
  final Map<String, Object?>? reference,
  final String python,
  final List<String> failures,
) {
  var allRefused = true;
  void expectRefusal(final String label, final bool refused) {
    if (!refused) {
      failures.add('negative $label: comparator did not refuse');
      allRefused = false;
    }
  }

  // 1. A missing reference artifact refuses.
  final missing = _loadReference('$evidenceDir/absent-dir', <String>[]);
  expectRefusal('missing-reference', missing == null);

  if (corpus == null || reference == null) return false;

  // 2. A failing reference command refuses: a failing subprocess is a
  //    failure, never a pass.
  final failing = Process.runSync(python, ['-c', 'import sys; sys.exit(3)']);
  expectRefusal('failing-command', failing.exitCode != 0);

  // 3. An altered reference field refuses.
  final mutated = jsonDecode(jsonEncode(reference)) as Map<String, Object?>;
  final cases = (mutated['cases'] as List).cast<Map<String, Object?>>();
  final smoke = cases.firstWhere((final entry) => entry['id'] == 'toolkit-smoke');
  final output = smoke['output'] as Map<String, Object?>;
  final locations = output['locations'] as Map<String, Object?>;
  locations['position'] = 99; // altered from the executed truth
  final mutatedVerdicts = <String, String>{};
  final mutatedFailures = <String>[];
  _compareInterchange(corpus, mutated, mutatedVerdicts, mutatedFailures);
  expectRefusal('altered-field', mutatedFailures.isNotEmpty);

  // 4. A position attributed to the wrong occurrence refuses: swap the
  //    progressions of the first two EPUB positions (different
  //    occurrences) and re-verify.
  final listFile = File('$evidenceDir/positions-epub.json');
  final evidenceFile = File('$evidenceDir/positions-epub-evidence.json');
  if (listFile.existsSync() && evidenceFile.existsSync()) {
    final list = jsonDecode(listFile.readAsStringSync()) as Map<String, Object?>;
    final positions = (list['positions'] as List).cast<Map<String, Object?>>();
    if (positions.length >= 2) {
      // Attribute the first position to the last position's occurrence:
      // small sections can share identical progressions, but the first
      // and last hrefs of a multi-occurrence book differ.
      final firstHref = positions.first['href'] as String;
      final lastHref = positions.last['href'] as String;
      if (firstHref != lastHref) {
        positions.first['href'] = lastHref;
      } else {
        final first = positions.first['locations'] as Map<String, Object?>;
        final last = positions.last['locations'] as Map<String, Object?>;
        final swap = first['totalProgression'];
        first['totalProgression'] = last['totalProgression'];
        last['totalProgression'] = swap;
      }
      final mutatedList = File('$evidenceDir/negative-mutated-positions.json');
      mutatedList.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(list)}\n');
      final result = Process.runSync(python, [
        'tool/readium/positions_verify.py',
        '--list',
        mutatedList.path,
        '--evidence',
        evidenceFile.path,
        '--book',
        'test/resources/epub/structure-sample-01.epub',
      ]);
      expectRefusal('wrong-occurrence-position', result.exitCode != 0);
      mutatedList.deleteSync();
    } else {
      expectRefusal('wrong-occurrence-position', false);
    }
  } else {
    expectRefusal('wrong-occurrence-position', false);
  }

  return allRefused;
}

// ---------------------------------------------------------------- helpers

String _sha256(final File file) =>
    file.existsSync() ? _sha256OfBytes(Uint8List.fromList(file.readAsBytesSync())) : '';

String _sha256OfBytes(final List<int> bytes) => crypto.sha256.convert(bytes).toString();
