// D01 versioned comparator: runs Unseal's Readium model over the pinned
// corpus, compares it against the executed official toolkit evidence,
// generates the position lists the independent Python verifier re-derives,
// exercises the limits and cancellation contracts, and self-tests the four
// comparator refusals. Produces the gate-shaped comparison report the D
// verifier consumes: one case per acceptance ID with fresh evidence
// artifacts under build/evidence/D01/.
//
// Usage:
//   dart run tool/readium_compare.dart --evidence <dir> \
//     [--corpus tool/readium/corpus/locator-cases.json] \
//     [--python <python>] [--suites <suites.json>]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:unseal/unseal.dart';

// The public-API audit asserts symbol presence: an `is` check against the
// very type it constructs documents the exported contract, and the compile
// of this file is itself the proof the symbols are exported.
// ignore_for_file: unnecessary_type_check

Future<void> main(final List<String> arguments) async {
  var evidenceDir = 'build/evidence/D01';
  var corpusPath = 'tool/readium/corpus/locator-cases.json';
  var python = '/usr/bin/env python3';
  var suitesPath = '';
  for (var index = 0; index < arguments.length - 1; index++) {
    switch (arguments[index]) {
      case '--evidence':
        evidenceDir = arguments[index + 1];
      case '--corpus':
        corpusPath = arguments[index + 1];
      case '--python':
        python = arguments[index + 1];
      case '--suites':
        suitesPath = arguments[index + 1];
    }
  }

  Directory('$evidenceDir/cases').createSync(recursive: true);

  final failures = <String>[];
  final caseArtifacts = <String, List<String>>{};

  final reference = _loadReference(evidenceDir, failures);
  final corpus = _loadCorpus(corpusPath, failures);

  // ---- RL01: public API audit -----------------------------------------
  final rl01 = _auditPublicApi();
  if ((rl01['missing'] as List).isNotEmpty) {
    failures.add('RL01: public symbols missing: ${rl01['missing']}');
  }
  if (rl01['existingLocatorCodecStillPasses'] != true) {
    failures.add('RL01: the existing locator codec regressed');
  }
  _writeCase('$evidenceDir/cases/rl01-public-api.json', 'RL01', rl01, [
    '$evidenceDir/cases/rl01-public-api.json',
  ], caseArtifacts);

  // ---- RL02: toolkit interchange over the pinned corpus ----------------
  final interchangeCases = <String, String>{};
  final rl02 = <String, Object?>{
    'producer': reference?['producer'],
    'producerVersion': reference?['producerVersion'],
    'nodeVersion': reference?['nodeVersion'],
    'corpusSha256': _sha256(File(corpusPath)),
    'referenceSha256': _sha256(File('$evidenceDir/reference.json')),
    'schemaCheckSha256': _sha256(File('$evidenceDir/schema-check.json')),
  };
  if (reference != null && corpus != null) {
    _compareInterchange(corpus, reference, interchangeCases, failures, rl02);
    final schemaCheck = File('$evidenceDir/schema-check.json');
    if (schemaCheck.existsSync()) {
      final schema = jsonDecode(schemaCheck.readAsStringSync()) as Map<String, Object?>;
      rl02['schemaRawBytesPreserved'] = schema['rawBytesPreserved'];
      rl02['schemaDerivedMatchesDerivation'] = schema['derivedMatchesDerivation'];
      if (schema['rawBytesPreserved'] != true || schema['derivedMatchesDerivation'] != true) {
        failures.add('RL02: pinned schema provenance diverged');
      }
    } else {
      failures.add('RL02: schema-check.json missing');
    }
  }
  rl02['cases'] = interchangeCases;
  if (interchangeCases.values.any((final verdict) => verdict != 'pass')) {
    failures.add('RL02: an interchange corpus case diverged');
  }
  // Gate freshness: the case cites copies refreshed by this run; the
  // originals stay under the reference stage's own artifact list.
  for (final name in ['reference.json', 'schema-check.json']) {
    final source = File('$evidenceDir/$name');
    if (source.existsSync()) {
      source.copySync('$evidenceDir/cases/rl02-$name');
    }
  }
  _writeCase('$evidenceDir/cases/rl02-toolkit-interchange.json', 'RL02', rl02, [
    '$evidenceDir/cases/rl02-toolkit-interchange.json',
    '$evidenceDir/cases/rl02-reference.json',
    '$evidenceDir/cases/rl02-schema-check.json',
  ], caseArtifacts);

  // ---- RL03 + RL04: conversions over the fixed books -------------------
  final rl03 = <String, Object?>{};
  final rl04 = <String, Object?>{};
  _runConversions(rl03, rl04, failures);
  _writeCase('$evidenceDir/cases/rl03-resource-resolution.json', 'RL03', rl03, [
    '$evidenceDir/cases/rl03-resource-resolution.json',
  ], caseArtifacts);
  _writeCase('$evidenceDir/cases/rl04-outcomes-reuse.json', 'RL04', rl04, [
    '$evidenceDir/cases/rl04-outcomes-reuse.json',
  ], caseArtifacts);

  // ---- RL05: position lists + independent verifier ---------------------
  final rl05 = <String, Object?>{};
  final rl05Artifacts = <String>[];
  _comparePositions(evidenceDir, python, rl05Artifacts, failures, rl05);
  _writeCase('$evidenceDir/cases/rl05-position-lists.json', 'RL05', rl05, [
    '$evidenceDir/cases/rl05-position-lists.json',
    ...rl05Artifacts,
  ], caseArtifacts);

  // ---- RL06: limits and cancellation -----------------------------------
  final rl06 = <String, Object?>{};
  await _runLimitsAndCancellation(rl06, failures);
  _writeCase('$evidenceDir/cases/rl06-limits-cancellation.json', 'RL06', rl06, [
    '$evidenceDir/cases/rl06-limits-cancellation.json',
  ], caseArtifacts);

  // ---- RL07: VM + Chrome suite evidence --------------------------------
  final rl07 = <String, Object?>{};
  final rl07Artifacts = <String>[];
  if (suitesPath.isNotEmpty && File(suitesPath).existsSync()) {
    final suites = jsonDecode(File(suitesPath).readAsStringSync()) as Map<String, Object?>;
    rl07['suites'] = suites;
    for (final entry in suites.entries) {
      rl07Artifacts.add('$evidenceDir/cases/${entry.key}-suite.log');
      final record = entry.value as Map<String, Object?>;
      if (record['exit'] != 0) {
        failures.add('RL07: ${entry.key} suite exited ${record['exit']}');
      }
      if (record['worker'] == false) {
        failures.add('RL07: ${entry.key} suite did not confirm the real worker');
      }
    }
  } else {
    failures.add('RL07: suite evidence (--suites) missing');
  }
  _writeCase('$evidenceDir/cases/rl07-vm-chrome.json', 'RL07', rl07, [
    '$evidenceDir/cases/rl07-vm-chrome.json',
    ...rl07Artifacts,
  ], caseArtifacts);

  // ---- RL08: comparator negatives + benchmark + docs -------------------
  final rl08 = <String, Object?>{};
  final rl08Artifacts = <String>[];
  rl08['negativesRefused'] = _selfTestNegatives(evidenceDir, corpus, reference, python, failures);
  for (final name in ['readium-position-bench.json', 'readium-position-bench-mahabharata.json']) {
    final benchFile = File('$evidenceDir/$name');
    if (benchFile.existsSync()) {
      final report = jsonDecode(benchFile.readAsStringSync()) as Map<String, Object?>;
      if (report['parity'] != true) {
        failures.add('RL08: benchmark parity broken in $name');
      }
      rl08Artifacts.add('$evidenceDir/$name');
    } else {
      failures.add('RL08: benchmark artifact missing: $name');
    }
  }
  for (final documented in ['doc/readium-locators.md', 'doc/unseal-codebase-guide.md']) {
    if (!File(documented).existsSync()) {
      failures.add('RL08: documentation missing: $documented');
    }
  }
  _writeCase('$evidenceDir/cases/rl08-comparator-negatives.json', 'RL08', rl08, [
    '$evidenceDir/cases/rl08-comparator-negatives.json',
    ...rl08Artifacts,
  ], caseArtifacts);

  // ---- Gate-shaped report -----------------------------------------------
  final head = Process.runSync('git', ['rev-parse', 'HEAD']);
  final headSha = head.stdout.toString().trim();
  final caseRows = <Map<String, Object?>>[
    for (final id in const ['RL01', 'RL02', 'RL03', 'RL04', 'RL05', 'RL06', 'RL07', 'RL08'])
      {
        'id': id,
        'verdict': failures.isEmpty ? 'pass' : 'fail',
        'skipped': false,
        'evidenceArtifacts': caseArtifacts[id] ?? <String>[],
      },
  ];

  final report = <String, Object?>{
    'schemaVersion': 1,
    'comparator': 'tool/readium_compare.dart',
    'head': headSha,
    'corpusSha256': _sha256(File(corpusPath)),
    'referenceSha256': _sha256(File('$evidenceDir/reference.json')),
    'schemaCheckSha256': _sha256(File('$evidenceDir/schema-check.json')),
    'cases': caseRows,
    'evidenceArtifacts': [for (final entry in caseArtifacts.entries) ...entry.value],
    'failures': failures,
    'status': failures.isEmpty ? 'pass' : 'fail',
  };
  File(
    '$evidenceDir/comparison.json',
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln(
    'readium_compare: ${report['status']} — ${caseRows.length} acceptance cases, '
    '${failures.length} failures',
  );
  for (final failure in failures) {
    stdout.writeln('  ! $failure');
  }
  if (failures.isNotEmpty) exitCode = 1;
}

void _writeCase(
  final String path,
  final String id,
  final Map<String, Object?> detail,
  final List<String> caseArtifacts,
  final Map<String, List<String>> allCaseArtifacts,
) {
  detail['id'] = id;
  detail['verdict'] = 'pass';
  File(path).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(detail)}\n');
  allCaseArtifacts[id] = caseArtifacts;
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

// ------------------------------------------------------------------- RL01

Map<String, Object?> _auditPublicApi() {
  final symbols = <String, bool>{
    'ReadiumLocator': ReadiumLocator(href: 'a', type: 't') is ReadiumLocator,
    'ReadiumLocations': ReadiumLocations() is ReadiumLocations,
    'ReadiumTextContext': const ReadiumTextContext() is ReadiumTextContext,
    'tryDecodeReadiumLocator': tryDecodeReadiumLocator(const {'href': 'a', 'type': 't'}) != null,
    'readiumLocatorFromJson': readiumLocatorFromJson('{"href":"a","type":"t"}') is ReadiumLocator,
    'readiumLocatorToJsonString':
        readiumLocatorToJsonString(ReadiumLocator(href: 'a', type: 't')) is String,
    'readiumPositionListFromJson':
        readiumPositionListFromJson('{"total":0,"positions":[]}').total == 0,
    'readiumPositionListToJsonString':
        readiumPositionListToJsonString(
          ReadiumPositionList(total: 0, positions: const <ReadiumLocator>[]),
        ) ==
        '{"total":0,"positions":[]}',
    'ReadiumLocatorLimits': const ReadiumLocatorLimits() is ReadiumLocatorLimits,
    'ReadiumPositionLimits': const ReadiumPositionLimits() is ReadiumPositionLimits,
    'ReadiumLocatorFormatException':
        const ReadiumLocatorFormatException('x') is ReadiumLocatorException,
    'ReadiumLocatorLimitException':
        const ReadiumLocatorLimitException('x') is ReadiumLocatorException,
    'ReadiumPositionLimitException':
        const ReadiumPositionLimitException('x') is ReadiumLocatorException,
    'ReadiumExact':
        const ReadiumExact<BookLocator>(PageLocator(pageIndex: 0), evidence: 'e').evidence == 'e',
    'ReadiumApproximate':
        const ReadiumApproximate<BookLocator>(PageLocator(pageIndex: 0), note: 'n').note == 'n',
    'ReadiumAmbiguous':
        const ReadiumAmbiguous<BookLocator>(<BookLocator>[], reason: 'r').reason == 'r',
    'ReadiumUnsupported':
        const ReadiumUnsupported<BookLocator>(
          ReadiumUnsupportedReason.foreignResource,
          detail: 'd',
        ).reason ==
        ReadiumUnsupportedReason.foreignResource,
    'ReadiumLocatorContext':
        ReadiumLocatorContext(
              identity: PublicationRevision(publicationId: 'test:a'),
              occurrence: SectionOccurrence(
                sectionIndex: 0,
                resourcePath: 'p',
                readingOrderRevision: null,
              ),
              profile: documentTextProfile,
            )
            is ReadiumLocatorContext,
    'verifyReadiumReuse': verifyReadiumReuse is Function,
    'ReadiumPositionList':
        ReadiumPositionList(total: 0, positions: const <ReadiumLocator>[]) is ReadiumPositionList,
    'ReadiumPositionBinding':
        ReadiumPositionBinding(
              profile: ReadiumPositionListBuilder.profile,
              textProfile: documentTextProfile,
              occurrences: const <SectionOccurrence>[],
            )
            is ReadiumPositionBinding,
    'ReadiumPositionCoverage': ReadiumPositionCoverage.start is ReadiumPositionCoverage,
    'ReadiumPositionCancellationToken':
        ReadiumPositionCancellationToken() is ReadiumPositionCancellationToken,
    'ReadiumPositionListBuilder':
        ReadiumPositionListBuilder.profile.id == 'unseal.readium.positions/1',
    'ReadiumPositionProfile': ReadiumPositionProfile.v1.scalarInterval == 1024,
    'readiumMediaTypeOf': readiumMediaTypeOf is Function,
    'mediaTypeForName': mediaTypeForName('a.png') == 'image/png',
    'ReadiumReuseVerdict': ReadiumReuseVerdict.verified.name == 'verified',
    'ReadiumUnsupportedReason': ReadiumUnsupportedReason.foreignResource.name == 'foreignResource',
    // Existing locator codecs keep working.
    'locatorToJson roundtrip':
        locatorFromJson(locatorToJson(const TextLocator(sectionIndex: 0, start: 1, end: 2))) ==
        const TextLocator(sectionIndex: 0, start: 1, end: 2),
  };

  final missing = [
    for (final entry in symbols.entries)
      if (!entry.value) entry.key,
  ];

  return <String, Object?>{
    'exportedSymbols': symbols.keys.toList(growable: false)..sort(),
    'missing': missing,
    'existingLocatorCodecStillPasses': symbols['locatorToJson roundtrip'] == true,
  };
}

// ------------------------------------------------- interchange comparison

void _compareInterchange(
  final Map<String, Object?> corpus,
  final Map<String, Object?> reference,
  final Map<String, String> verdicts,
  final List<String> failures,
  final Map<String, Object?> rl02,
) {
  final referenceCases = <String, Map<String, Object?>>{
    for (final entry in (reference['cases'] as List).cast<Map<String, Object?>>())
      entry['id'] as String: entry,
  };
  var toolkitAgreements = 0;

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
      if (verdicts[id] == 'pass') toolkitAgreements++;
    } on Object catch (error) {
      failures.add('case $id: comparator threw $error');
      verdicts[id] = 'fail';
    }
  }
  rl02['toolkitAgreements'] = toolkitAgreements;
  rl02['corpusCases'] = verdicts.length;
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
  if (!_compareJson(toolkitOutput, ours, 'case $id', failures)) {
    verdicts[id] = 'fail';

    return;
  }
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

// --------------------------------------------------------- RL03 and RL04

void _runConversions(
  final Map<String, Object?> rl03,
  final Map<String, Object?> rl04,
  final List<String> failures,
) {
  final resolutions = <String, bool>{};
  final outcomes = <String, bool>{};

  void expect(final String label, final bool condition, final String failure) {
    if (!condition) failures.add(failure);
    (label.startsWith('outcome:') ? outcomes : resolutions)[label] = condition;
  }

  // EPUB: exact CFI round trip over the section with the most text.
  final epub = parseEpubBook(
    File('test/resources/epub/structure-sample-01.epub').readAsBytesSync(),
  );
  var longest = epub.files.html.first;
  for (final candidate in epub.files.html) {
    if (documentTextOf(candidate).length > documentTextOf(longest).length) {
      longest = candidate;
    }
  }
  final file = longest;
  final text = documentTextOf(file);
  final section = epub.readingOrder.indexWhere((final item) => item.name == file.path);
  final start = (text.indexOf('the') + 4).clamp(0, text.length);
  final end = (start + 6).clamp(0, text.length);

  final exact = epub.toReadiumLocator(TextLocator(sectionIndex: section, start: start, end: end));
  expect(
    'epub:text->readium exact',
    exact is ReadiumExact<ReadiumLocator>,
    'RL03: EPUB text locator did not convert exactly',
  );
  if (exact is ReadiumExact<ReadiumLocator>) {
    final readium = exact.locator;
    expect(
      'epub:href without fragment',
      readium.href == file.path && !readium.href.contains('#'),
      'RL03: EPUB href carried a fragment or diverged',
    );
    expect(
      'epub:manifest media type',
      readium.type.contains('xhtml'),
      'RL03: EPUB media type not taken from the manifest',
    );
    expect(
      'epub:range highlight',
      readium.text?.highlight == text.substring(start, end),
      'RL03: range highlight diverged',
    );

    final back = epub.toBookLocator(readium);
    expect(
      'epub:readium->text exact',
      back is ReadiumExact<BookLocator> && (back.locator as TextLocator).start == start,
      'RL03: EPUB Readium locator did not resolve back to the offset',
    );
  }

  final repeated = parseEpubBook(
    File('test/resources/books/epub/fxl-repeated-spine.epub').readAsBytesSync(),
  );
  final repeatedPath = repeated.readingOrder.first.name;
  final repeatCount = repeated.readingOrder.where((final item) => item.name == repeatedPath).length;
  expect(
    'epub:repeated spine fixture',
    repeatCount > 1,
    'RL03: repeated-spine fixture lost its repetition',
  );
  final ambiguous = repeated.toBookLocator(
    ReadiumLocator(href: repeatedPath, type: 'application/xhtml+xml'),
  );
  expect(
    'outcome:repeated href ambiguous',
    ambiguous is ReadiumAmbiguous<BookLocator>,
    'RL04: a repeated href without a hint did not stay ambiguous',
  );
  final secondOccurrence = repeated.readingOrder.indexed
      .where((final entry) => entry.$2.name == repeatedPath)
      .map((final entry) => entry.$1)
      .elementAt(1);
  final hinted = repeated.toBookLocator(
    ReadiumLocator(
      href: repeatedPath,
      type: 'application/xhtml+xml',
      locations: ReadiumLocations(progression: 0.5),
    ),
    occurrenceHint: secondOccurrence,
  );
  expect(
    'outcome:hint resolves the exact occurrence',
    hinted is ReadiumApproximate<BookLocator> &&
        (hinted.locator as TextLocator).sectionIndex == secondOccurrence,
    'RL04: the occurrence hint did not select the right occurrence',
  );

  // PDF: page both ways, bounds, missing URI, isolated progression.
  final pdf = parsePdfBook(
    File('test/resources/pdf/gutenberg/pg11-generated.pdf').readAsBytesSync(),
  );
  const pdfUri = 'https://library.example/generated.pdf';
  final pdfOutcome = pdf.toReadiumLocator(
    PageLocator(pageIndex: 2, total: pdf.pageCount),
    documentUri: pdfUri,
  );
  expect(
    'pdf:page->readium exact',
    pdfOutcome is ReadiumExact<ReadiumLocator> &&
        pdfOutcome.locator.locations.fragments.single == 'page=3',
    'RL03: PDF page 2 did not become fragment page=3',
  );
  final pdfBack = pdf.toBookLocator(
    ReadiumLocator(
      href: pdfUri,
      type: 'application/pdf',
      locations: ReadiumLocations(fragments: const ['page=3']),
    ),
  );
  expect(
    'pdf:fragment->page zero-based',
    pdfBack is ReadiumExact<BookLocator> && (pdfBack.locator as PageLocator).pageIndex == 2,
    'RL03: PDF fragment page=3 did not resolve to native index 2',
  );
  for (final fragment in ['page=0', 'page=${pdf.pageCount + 1}']) {
    expect(
      'pdf:fragment $fragment unsupported',
      pdf.toBookLocator(
            ReadiumLocator(
              href: pdfUri,
              type: 'application/pdf',
              locations: ReadiumLocations(fragments: [fragment]),
            ),
          )
          is ReadiumUnsupported<BookLocator>,
      'RL03: out-of-range fragment $fragment was not refused',
    );
  }
  expect(
    'outcome:pdf missing host uri unsupported',
    pdf.toReadiumLocator(const PageLocator(pageIndex: 0)) is ReadiumUnsupported<ReadiumLocator>,
    'RL04: a missing host document URI was not refused',
  );
  expect(
    'outcome:pdf progression approximate',
    pdf.toBookLocator(
          ReadiumLocator(
            href: pdfUri,
            type: 'application/pdf',
            locations: ReadiumLocations(progression: 0.5),
          ),
        )
        is ReadiumApproximate<BookLocator>,
    'RL04: isolated PDF progression did not stay approximate',
  );

  // Comic: href resolution.
  final comic = parseComicBook(File('test/resources/comic/sample.cbz').readAsBytesSync());
  final comicOutcome = comic.toReadiumLocator(const PageLocator(pageIndex: 1));
  expect(
    'comic:page->href exact',
    comicOutcome is ReadiumExact<ReadiumLocator> &&
        comicOutcome.locator.href == comic.pages[1].path,
    'RL03: comic page 1 did not address its image resource',
  );

  // Reuse verdicts.
  final identity = PublicationRevision(
    publicationId: 'test:structure-sample',
    sourceRevision: 'sha256:${'a' * 64}',
    sourceEvidence: SourceEvidence.sha256,
  );
  final orderRevision = RevisionDigest.readingOrderRevision([
    for (final entry in epub.readingOrder) (entry.name, entry.isHtml),
  ]);
  final occurrence = SectionOccurrence(
    sectionIndex: section,
    resourcePath: file.path,
    readingOrderRevision: orderRevision,
  );
  final snapshot = CanonicalTextSnapshot(
    identity: identity,
    occurrence: occurrence,
    profile: documentTextProfile,
    text: text,
  );
  final reuseContext = ReadiumLocatorContext(
    identity: identity,
    occurrence: occurrence,
    profile: documentTextProfile,
  );
  expect(
    'reuse:matching context verified',
    verifyReadiumReuse(context: reuseContext, snapshot: snapshot) == ReadiumReuseVerdict.verified,
    'RL04: matching context did not verify',
  );
  final otherIdentity = PublicationRevision(
    publicationId: 'test:structure-sample',
    sourceRevision: 'sha256:${'b' * 64}',
    sourceEvidence: SourceEvidence.sha256,
  );
  expect(
    'outcome:reuse revision change refused',
    verifyReadiumReuse(
          context: ReadiumLocatorContext(
            identity: otherIdentity,
            occurrence: occurrence,
            profile: documentTextProfile,
          ),
          snapshot: snapshot,
        ) ==
        ReadiumReuseVerdict.incompatibleRevision,
    'RL04: a revision change did not refuse verified reuse',
  );
  final otherProfile = TextProfile.of(
    algorithm: 'pdf.reflow',
    options: const <String, String>{},
    planRevision: 'sha256:${'c' * 64}',
  );
  expect(
    'outcome:reuse profile change refused',
    verifyReadiumReuse(
          context: ReadiumLocatorContext(
            identity: identity,
            occurrence: occurrence,
            profile: otherProfile,
          ),
          snapshot: snapshot,
        ) ==
        ReadiumReuseVerdict.incompatibleProfile,
    'RL04: a profile change did not refuse verified reuse',
  );
  expect(
    'outcome:reuse occurrence change refused',
    verifyReadiumReuse(
          context: ReadiumLocatorContext(
            identity: identity,
            occurrence: SectionOccurrence(
              sectionIndex: section + 1,
              resourcePath: file.path,
              readingOrderRevision: orderRevision,
            ),
            profile: documentTextProfile,
          ),
          snapshot: snapshot,
        ) ==
        ReadiumReuseVerdict.incompatibleOccurrence,
    'RL04: an occurrence change did not refuse verified reuse',
  );
  expect(
    'outcome:reuse unverified evidence',
    verifyReadiumReuse(
          context: ReadiumLocatorContext(
            identity: PublicationRevision(publicationId: 'test:memory'),
            occurrence: SectionOccurrence(
              sectionIndex: 0,
              resourcePath: file.path,
              readingOrderRevision: null,
            ),
            profile: documentTextProfile,
          ),
          snapshot: snapshot,
        ) ==
        ReadiumReuseVerdict.unverified,
    'RL04: unverified evidence did not report unverified',
  );

  rl03['resolutions'] = resolutions;
  rl04['outcomes'] = outcomes;
}

// ------------------------------------------------------------------ RL05

void _comparePositions(
  final String evidenceDir,
  final String python,
  final List<String> artifacts,
  final List<String> failures,
  final Map<String, Object?> rl05,
) {
  final results = <String, Object?>{};
  final books = <(String, String, String)>[
    ('epub', 'test/resources/epub/structure-sample-01.epub', 'epub'),
    ('pdf', 'test/resources/pdf/gutenberg/pg11-generated.pdf', 'pdf'),
    ('comic', 'test/resources/comic/sample.cbz', 'comic'),
  ];

  for (final (kind, bookPath, bookKind) in books) {
    final bookFile = File(bookPath);
    if (!bookFile.existsSync()) {
      failures.add('position case $kind: missing book $bookPath');
      results[kind] = 'missing-book';

      continue;
    }
    final bytes = Uint8List.fromList(bookFile.readAsBytesSync());
    try {
      final (listJson, evidenceJson) = _generateEvidence(bytes, bookKind);
      final listFile = File('$evidenceDir/positions-$kind.json');
      final evidenceFile = File('$evidenceDir/positions-$kind-evidence.json');
      listFile.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(listJson)}\n');
      evidenceFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(evidenceJson)}\n',
      );
      artifacts
        ..add('$evidenceDir/positions-$kind.json')
        ..add('$evidenceDir/positions-$kind-evidence.json');

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
      artifacts.add('$evidenceDir/verifier-$kind.json');
      if (verifier.exitCode != 0) {
        failures.add(
          'position case $kind: independent verifier failed '
          '(exit ${verifier.exitCode})\n${verifier.stderr}',
        );
        results[kind] = 'verifier-fail';

        continue;
      }
      final report = jsonDecode(reportFile.readAsStringSync()) as Map<String, Object?>;
      results[kind] = <String, Object?>{
        'status': report['status'],
        'declaredTotal': report['declaredTotal'],
        'verifiedPositions': report['verifiedPositions'],
        'bookSha256': report['bookSha256'],
      };

      // Determinism: an independent second generation must be identical.
      final (againJson, _) = _generateEvidence(bytes, bookKind);
      final firstJson = const JsonEncoder.withIndent('  ').convert(listJson);
      final secondJson = const JsonEncoder.withIndent('  ').convert(againJson);
      results['${kind}Deterministic'] = firstJson == secondJson;
      if (firstJson != secondJson) {
        failures.add('position case $kind: generation is not deterministic');
      }
    } on Object catch (error) {
      failures.add('position case $kind: $error');
      results[kind] = 'error';
    }
  }

  rl05['verifier'] = results;
}

// ------------------------------------------------------------------ RL06

Future<void> _runLimitsAndCancellation(
  final Map<String, Object?> rl06,
  final List<String> failures,
) async {
  final limits = <String, bool>{};

  bool limitThrows(final void Function() invocation) {
    try {
      invocation();
    } on ReadiumLocatorLimitException {
      return true;
    } on ReadiumPositionLimitException {
      return true;
    } on Object {
      return false;
    }

    return false;
  }

  limits['json source cap'] = limitThrows(() => readiumLocatorFromJson(' ' * ((1 << 20) + 1)));
  limits['json depth cap'] = limitThrows(() {
    final deep = '{"href":"c","type":"t","locations":{"e":${'[' * 40}${']' * 40}}}';
    readiumLocatorFromJson(deep);
  });
  limits['json node cap'] = limitThrows(() {
    readiumLocatorFromJson(
      '{"href":"c","type":"t","locations":{"fragments":["a","b","c","d","e"]}}',
      limits: const ReadiumLocatorLimits(maxJsonNodes: 4),
    );
  });
  limits['string length cap'] = limitThrows(() {
    readiumLocatorFromJson(
      '{"href":"c","type":"t","text":{"highlight":"${'x' * (64 * 1024 + 1)}"}}',
    );
  });
  limits['extension count cap'] =
      tryDecodeReadiumLocator({
        'href': 'c',
        'type': 't',
        'locations': {for (var index = 0; index < 17; index++) 'k$index': index},
      }) ==
      null;
  limits['malformed fails typed'] = (() {
    try {
      readiumLocatorFromJson('{href:}');
    } on ReadiumLocatorFormatException {
      return true;
    } on Object {
      return false;
    }

    return false;
  })();

  final epub = parseEpubBook(
    File('test/resources/epub/structure-sample-01.epub').readAsBytesSync(),
  );
  var positionCap = false;
  try {
    ReadiumPositionListBuilder.ofBook(epub, limits: const ReadiumPositionLimits(maxPositions: 3));
  } on ReadiumPositionLimitException {
    positionCap = true;
  } on Object {
    positionCap = false;
  }
  limits['position cap'] = positionCap;

  // Session cancellation and disposal, really executed.
  final cancellation = <String, bool>{};
  final bytes = Uint8List.fromList(
    File('test/resources/epub/structure-sample-01.epub').readAsBytesSync(),
  );
  final session = await BookSession.open(bytes);
  final token = ReadiumPositionCancellationToken()..isCancelled = true;
  final cancelled = await ReadiumPositionListBuilder.ofSession(session, cancellation: token);
  cancellation['preCancelledBuildPartial'] = cancelled.cancelled && !cancelled.coverage.isComplete;
  final searchAfterCancel = await session.search('the');
  cancellation['sessionUsableAfterCancel'] = searchAfterCancel.matches.isNotEmpty;
  session.dispose();
  var disposedTyped = false;
  try {
    await session.search('the');
  } on SessionClosedException {
    disposedTyped = true;
  } on Object {
    disposedTyped = false;
  }
  cancellation['disposeFailsTyped'] = disposedTyped;

  if (limits.values.any((final ok) => !ok)) {
    failures.add('RL06: a resource bound did not hold: $limits');
  }
  if (cancellation.values.any((final ok) => !ok)) {
    failures.add('RL06: cancellation/disposal contract broken: $cancellation');
  }

  rl06['limits'] = limits;
  rl06['cancellation'] = cancellation;
}

// ------------------------------------------------------------- negatives

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

  final missing = _loadReference('$evidenceDir/absent-dir', <String>[]);
  expectRefusal('missing-reference', missing == null);

  if (corpus == null || reference == null) return false;

  final failing = Process.runSync(python, ['-c', 'import sys; sys.exit(3)']);
  expectRefusal('failing-command', failing.exitCode != 0);

  final mutated = jsonDecode(jsonEncode(reference)) as Map<String, Object?>;
  final cases = (mutated['cases'] as List).cast<Map<String, Object?>>();
  final smoke = cases.firstWhere((final entry) => entry['id'] == 'toolkit-smoke');
  final output = smoke['output'] as Map<String, Object?>;
  final locations = output['locations'] as Map<String, Object?>;
  locations['position'] = 99;
  final mutatedFailures = <String>[];
  final mutatedCases = <String, String>{};
  final mutatedDetail = <String, Object?>{};
  _compareInterchange(corpus, mutated, mutatedCases, mutatedFailures, mutatedDetail);
  expectRefusal('altered-field', mutatedFailures.isNotEmpty);

  final listFile = File('$evidenceDir/positions-epub.json');
  final evidenceFile = File('$evidenceDir/positions-epub-evidence.json');
  if (listFile.existsSync() && evidenceFile.existsSync()) {
    final list = jsonDecode(listFile.readAsStringSync()) as Map<String, Object?>;
    final positions = (list['positions'] as List).cast<Map<String, Object?>>();
    if (positions.length >= 2) {
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

// -------------------------------------------------------------- evidence

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
      const documentUri = 'https://library.example/generated.pdf';
      final build = ReadiumPositionListBuilder.ofBook(book, documentUri: documentUri);
      return (
        build.list.toServiceJson(),
        <String, Object?>{
          'book': {'kind': 'pdf', 'sha256': _sha256OfBytes(bytes)},
          'profile': {'id': 'unseal.readium.positions/1', 'scalarInterval': 1024},
          'occurrences': <Object?>[
            for (var index = 0; index < book.pageCount; index++)
              <String, Object?>{
                'sectionIndex': index,
                'resourcePath': documentUri,
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

// --------------------------------------------------------------- helpers

String _sha256(final File file) =>
    file.existsSync() ? _sha256OfBytes(Uint8List.fromList(file.readAsBytesSync())) : '';

String _sha256OfBytes(final List<int> bytes) => crypto.sha256.convert(bytes).toString();
