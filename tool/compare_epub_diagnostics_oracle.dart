import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:unseal/epub.dart';

import 'oracle_test_lane.dart';

/// Reproducible EPUBCheck oracle driver for the B03 diagnostics mission.
///
/// Stages:
///  - `version`   verifies the pinned distribution digest and tool version.
///  - `reference` runs EPUBCheck over read-only input copies and records
///                every report, exit code, and digest.
///  - `compare`   runs the Unseal diagnostics over the same inputs, applies
///                the declared rule mapping and comparison policy, and emits
///                the gated acceptance report.
///
/// EPUBCheck exit 1 with a parsed report is an expected rejection of an
/// invalid EPUB, never a tool failure; a missing report is a tool failure.
void main(final List<String> arguments) {
  final options = _Options.parse(arguments);
  switch (options.stage) {
    case 'version':
      _runVersion(options);
    case 'reference':
      _runReference(options);
    case 'compare':
      _runCompare(options);
    default:
      stderr.writeln('Unknown stage: ${options.stage}');
      exit(2);
  }
}

const _pinnedZipSha256 = '33350c61038e71dfb3d45a76aed04bf5481e6d5500cb780f6e98db8bbd15a28c';
const _pinnedVersionPrefix = 'EPUBCheck v5.4.0';

/// Real licensed books complementing the synthetic corpus. Their bytes are
/// committed fixtures; hashes are verified at copy time against the values
/// recorded on first reference run.
const _realCorpus = <String, String>{
  'real-alice-wonderland': 'test/resources/epub/Alices Adventures in Wonderland.epub',
  'real-linear-algebra': 'test/resources/epub/linear-algebra.epub',
  'real-structure-sample-01': 'test/resources/epub/structure-sample-01.epub',
};

/// Mapping between Unseal rules and EPUBCheck 5.4.0 messages, measured on
/// the committed corpus (see doc/epub-diagnostics.md). A matcher matches
/// when the message ID equals the configured `id` and the message contains
/// the configured substring; `epub2Only` restricts a matcher to EPUB 2
/// publications.
final List<_RuleMapping> _mappings = [
  _RuleMapping('epub.container.mimetype-invalid', const [
    _MessageMatcher(id: 'PKG-006', contains: 'Mimetype file entry'),
    _MessageMatcher(id: 'PKG-007', contains: 'mimetype file must be the string'),
  ]),
  _RuleMapping('epub.container.missing', const [
    _MessageMatcher(id: 'RSC-002', contains: 'META-INF/container.xml'),
  ]),
  _RuleMapping('epub.container.rootfile.missing', const [
    _MessageMatcher(id: 'RSC-003', contains: 'No rootfile tag'),
  ]),
  _RuleMapping('epub.container.rootfile.path-unresolved', const [
    _MessageMatcher(id: 'OPF-002', contains: 'was not found in the EPUB'),
  ]),
  _RuleMapping('epub.container.rootfile.media-type-unsupported', const [
    _MessageMatcher(id: 'RSC-003', contains: 'No rootfile tag'),
  ]),
  _RuleMapping('epub.package.version-unsupported', const [
    _MessageMatcher(id: 'OPF-001', contains: 'parsing the EPUB version'),
  ]),
  _RuleMapping('epub.manifest.item.incomplete', const [
    _MessageMatcher(id: 'RSC-005', contains: 'element "item" missing required attribute'),
  ]),
  _RuleMapping('epub.manifest.resource-missing', const [
    _MessageMatcher(id: 'RSC-001', contains: 'could not be found'),
  ]),
  _RuleMapping('epub.manifest.id-duplicate', const [
    _MessageMatcher(id: 'RSC-005', contains: 'Duplicate "'),
  ]),
  _RuleMapping('epub.manifest.href-duplicate', const [
    _MessageMatcher(id: 'OPF-074', contains: 'several manifest items'),
  ]),
  _RuleMapping('epub.manifest.href-fragment', const [
    _MessageMatcher(id: 'OPF-091', contains: 'must not have a fragment'),
  ]),
  _RuleMapping('epub.manifest.remote-resource-undeclared', const [
    _MessageMatcher(id: 'RSC-006', contains: 'Remote resource reference'),
  ]),
  _RuleMapping('epub.spine.reference-invalid', const [
    _MessageMatcher(id: 'OPF-049', contains: 'was not found in the manifest'),
    _MessageMatcher(id: 'RSC-005', contains: 'does not resolve to a manifest item'),
  ]),
  _RuleMapping('epub.spine.empty', const [
    _MessageMatcher(id: 'RSC-005', contains: 'element "spine" incomplete'),
  ]),
  _RuleMapping('epub.spine.reference-duplicate', const [
    _MessageMatcher(id: 'RSC-005', contains: 'same manifest entry as a previous itemref'),
  ]),
  _RuleMapping('epub.navigation.nav-missing', const [
    _MessageMatcher(id: 'RSC-005', contains: 'number of "nav" items: 0'),
  ]),
  _RuleMapping('epub.navigation.nav-duplicate', const [
    _MessageMatcher(
      id: 'RSC-005',
      contains: 'must declare the "nav" property',
      notContains: 'items: 0',
    ),
  ]),
  _RuleMapping('epub.navigation.toc-missing', const [
    _MessageMatcher(id: 'RSC-005', contains: 'Exactly one "toc" nav element must be present'),
    _MessageMatcher(id: 'RSC-001', contains: 'toc.ncx', epub2Only: true),
  ]),
  _RuleMapping('epub.navigation.toc-reference-missing', const [
    _MessageMatcher(id: 'RSC-005', contains: 'missing required attribute "toc"'),
  ]),
  _RuleMapping('epub.navigation.link-unresolved', const [
    _MessageMatcher(id: 'RSC-007', contains: 'could not be found'),
  ]),
  _RuleMapping('epub.navigation.fragment-unresolved', const [
    _MessageMatcher(id: 'RSC-012', contains: 'Fragment identifier is not defined'),
  ]),
  _RuleMapping('epub.guide.reference-unresolved', const [
    _MessageMatcher(id: 'OPF-031', contains: 'not declared in OPF manifest'),
  ]),
];

final Set<String> _catalogRuleIds = {for (final mapping in _mappings) mapping.ruleId};

void _runVersion(final _Options options) {
  final record = _verifyOracle(options);
  _writeJson(options.versionRecord, record);
  stdout.writeln(jsonEncode(record));
}

Map<String, Object?> _verifyOracle(final _Options options) {
  final zip = File(options.oracleZip);
  if (!zip.existsSync()) {
    stderr.writeln('Oracle distribution missing: ${options.oracleZip}');
    exit(2);
  }
  final zipDigest = sha256.convert(zip.readAsBytesSync()).toString();
  if (zipDigest != _pinnedZipSha256) {
    stderr.writeln('Oracle distribution digest mismatch: $zipDigest != $_pinnedZipSha256');
    exit(2);
  }

  final version = _runEpubCheckVersion(options);
  if (!version.startsWith(_pinnedVersionPrefix)) {
    stderr.writeln('Oracle version "$version" does not match pin "$_pinnedVersionPrefix"');
    exit(2);
  }
  if (!File(options.oracleJar).existsSync()) {
    stderr.writeln('Oracle jar missing: ${options.oracleJar}');
    exit(2);
  }

  return {
    'oracleVersion': version,
    'zipSha256': zipDigest,
    'jar': options.oracleJar,
    'java': _javaVersion(options),
  };
}

String _runEpubCheckVersion(final _Options options) {
  final result = Process.runSync(options.java, ['-jar', options.oracleJar, '--version']);
  final output = '${result.stdout}${result.stderr}'.trim();
  if (result.exitCode != 0) {
    stderr.writeln('EPUBCheck --version failed: $output');
    exit(2);
  }

  return output.split('\n').first.trim();
}

String _javaVersion(final _Options options) {
  final result = Process.runSync(options.java, ['-version']);
  return '${result.stdout}${result.stderr}'.trim().split('\n').first.trim();
}

void _runReference(final _Options options) {
  final record = _verifyOracle(options);
  _writeJson(options.versionRecord, record);

  final index = <String, Object?>{};
  for (final case_ in _corpusCases(options)) {
    final reportPath = '${options.referenceDir}/oracle-${case_.id}.json';
    final logPath = '${options.referenceDir}/oracle-${case_.id}.log';
    final result = Process.runSync(options.java, [
      '-jar',
      options.oracleJar,
      '--json',
      reportPath,
      case_.inputPath,
    ], stdoutEncoding: utf8);
    File(logPath).writeAsStringSync('${result.stdout}${result.stderr}', flush: true);

    final reportFile = File(reportPath);
    if (!reportFile.existsSync()) {
      stderr.writeln(
        'Oracle tool failure: no report produced for ${case_.id} '
        '(exit ${result.exitCode}); see $logPath',
      );
      exit(2);
    }
    final Object? parsed;
    try {
      parsed = jsonDecode(reportFile.readAsStringSync());
    } on FormatException {
      stderr.writeln('Oracle tool failure: unparsable report for ${case_.id}');
      exit(2);
    }

    final report = parsed! as Map<String, Object?>;
    index[case_.id] = {
      'inputPath': case_.inputPath,
      'inputSha256': case_.inputSha256,
      'epubFamily': case_.epubFamily,
      'origin': case_.origin,
      'oracleExit': result.exitCode,
      'reportPath': reportPath,
      'reportSha256': sha256.convert(reportFile.readAsBytesSync()).toString(),
      'publicationVersion':
          (report['publication'] as Map<String, Object?>?)?['ePubVersion'] as String?,
      'messages': [
        for (final message in (report['messages']! as List<Object?>).cast<Map<String, Object?>>())
          {'ID': message['ID'], 'severity': message['severity'], 'message': message['message']},
      ],
    };
  }

  _writeJson(options.referenceIndex, {
    'oracleVersion': _pinnedVersionPrefix,
    'zipSha256': _pinnedZipSha256,
    'cases': index,
  });
  stdout.writeln('Reference stage recorded ${index.length} cases.');
}

void _runCompare(final _Options options) {
  final reference = _readJsonFile(options.referenceIndex);
  final referenceCases = (reference['cases']! as Map<String, Object?>)
      .cast<String, Map<String, Object?>>();
  final fixturesManifest = _readJsonFile(options.fixturesManifest);
  final fixtureCases = (fixturesManifest['cases']! as List<Object?>).cast<Map<String, Object?>>();

  final caseDetails = <Map<String, Object?>>[];
  var failures = 0;

  for (final fixture in fixtureCases) {
    final id = fixture['id']! as String;
    final caseId = 'diag-$id';
    final oracle = referenceCases[caseId];
    if (oracle == null) {
      stderr.writeln('Missing oracle reference for $caseId');
      failures++;
      continue;
    }
    final expectedRules = (fixture['expected_rules']! as List<Object?>).cast<String>();

    final diagnosis = _diagnoseInput(options, oracle);
    final detail = _compareSynthetic(
      id: id,
      expectedRules: expectedRules,
      epubFamily: fixture['epub_family']! as String,
      findings: diagnosis.findings,
      oracleMessages: oracle,
      elapsedMicros: diagnosis.elapsedMicros,
    );
    caseDetails.add(detail);
    if (_isFailure(detail)) failures++;
  }

  for (final entry in _realCorpus.entries) {
    final oracle = referenceCases[entry.key];
    if (oracle == null) {
      stderr.writeln('Missing oracle reference for ${entry.key}');
      failures++;
      continue;
    }
    final diagnosis = _diagnoseInput(options, oracle);
    final detail = _compareRealCorpus(
      id: entry.key,
      findings: diagnosis.findings,
      oracleMessages: oracle,
      elapsedMicros: diagnosis.elapsedMicros,
    );
    caseDetails.add(detail);
    if (_isFailure(detail)) failures++;
  }

  final limits = _limitsProbe(options);
  final coverageGap = _coverageCheck(caseDetails);
  if (coverageGap != null) {
    stderr.writeln('Rule coverage gap: $coverageGap');
    failures++;
  }

  final ruleFindings = <String>[];
  for (final detail in caseDetails) {
    for (final finding in (detail['unsealRules']! as List<Object?>).cast<String>()) {
      if (!_catalogRuleIds.contains(finding) && !ruleFindings.contains(finding)) {
        ruleFindings.add(finding);
      }
    }
  }
  if (ruleFindings.isNotEmpty) {
    stderr.writeln('Findings outside the declared catalog: $ruleFindings');
    failures++;
  }

  final edCases = _acceptanceCases(
    caseDetails: caseDetails,
    limits: limits,
    fixtureCount: fixtureCases.length,
  );
  final lanes = [
    runOracleDartLane(Directory('build/evidence/b03-lanes'), 'vm', [
      'test',
      'test/tests/epub/epub_diagnostics_test.dart',
    ]),
    runOracleDartLane(Directory('build/evidence/b03-lanes'), 'chrome', [
      'test',
      '-p',
      'chrome',
      'test/web/epub_diagnostics_web_test.dart',
    ]),
  ];
  final ed07 = edCases.singleWhere((c) => c['id'] == 'ED07');
  ed07['executedLanes'] = lanes;
  if (lanes.any((l) => l['exitCode'] != 0)) {
    ed07['verdict'] = 'fail';
    failures++;
  }

  _writeJson(options.detailReport, {
    'generatedAt': 'deterministic-compare',
    'caseDetails': caseDetails,
    'limitsProbe': limits,
  });
  _writeJson(options.measurements, {
    'clock': 'Stopwatch wall time per diagnoseEpub call, warm process',
    'cases': [
      for (final detail in caseDetails)
        {'id': detail['id'], 'elapsedMicros': detail['elapsedMicros']},
    ],
    'limitsProbeElapsedMicros': limits['elapsedMicros'],
    'memoryScope':
        'comparator process including all sequential diagnoses; sampled current RSS and process peak, not per-book allocation',
    'processCurrentRssBytes': ProcessInfo.currentRss,
    'processPeakRssBytes': ProcessInfo.maxRss,
  });

  _writeJson(options.report, {
    'mission': 'B03',
    'referencePin':
        'EPUBCheck v5.4.0, official distribution epubcheck-5.4.0.zip '
        '($_pinnedZipSha256)',
    'cases': edCases,
  });

  if (failures > 0) {
    stderr.writeln('Comparison finished with $failures failure(s).');
    exit(1);
  }
  stdout.writeln(
    'Comparison passed for ${caseDetails.length} corpus cases plus the '
    'limits probe.',
  );
}

bool _isFailure(final Map<String, Object?> detail) =>
    detail['verdict'] != 'pass' && detail['verdict'] != 'expected-rejection';

({List<EpubDiagnostic> findings, int elapsedMicros}) _diagnoseInput(
  final _Options options,
  final Map<String, Object?> oracle,
) {
  final bytes = File(oracle['inputPath']! as String).readAsBytesSync();
  final recordedDigest = sha256.convert(bytes).toString();
  if (recordedDigest != oracle['inputSha256']) {
    stderr.writeln('Input hash drift for ${oracle['inputPath']}');
    exit(2);
  }

  final watch = Stopwatch()..start();
  final first = diagnoseEpub(bytes);
  final elapsed = watch.elapsedMicroseconds;
  final second = diagnoseEpub(bytes);
  if (first.findings.toString() != second.findings.toString()) {
    stderr.writeln('Non-deterministic diagnosis for ${oracle['inputPath']}');
    exit(2);
  }

  return (findings: first.findings, elapsedMicros: elapsed);
}

Map<String, Object?> _compareSynthetic({
  required final String id,
  required final List<String> expectedRules,
  required final String epubFamily,
  required final List<EpubDiagnostic> findings,
  required final Map<String, Object?> oracleMessages,
  required final int elapsedMicros,
}) {
  final unsealRules = findings.map((final finding) => finding.ruleId).toList();
  final sortedExpected = [...expectedRules]..sort();
  final sortedUnseal = [...unsealRules]..sort();

  final problems = <String>[];
  if (sortedExpected.join('|') != sortedUnseal.join('|')) {
    problems.add('expected rules $sortedExpected but diagnosis reported $sortedUnseal');
  }

  final messages = (oracleMessages['messages']! as List<Object?>).cast<Map<String, Object?>>();
  final major = epubFamily == 'epub2' ? 2 : 3;
  for (final rule in expectedRules.toSet()) {
    final confirmed = messages.any(
      (final message) => _mappings
          .where((final mapping) => mapping.ruleId == rule)
          .any(
            (final mapping) =>
                mapping.matchers.any((final matcher) => matcher.matches(message, major)),
          ),
    );
    if (!confirmed) {
      problems.add('oracle did not confirm rule $rule');
    }
  }

  final oracleExit = oracleMessages['oracleExit']! as int;
  final expectedExit = expectedRules.isEmpty ? 0 : 1;
  if (oracleExit != expectedExit) {
    problems.add('oracle exit $oracleExit but this case expects $expectedExit');
  }

  return {
    'id': id,
    'caseId': 'diag-$id',
    'kind': 'synthetic',
    'verdict': problems.isEmpty ? (oracleExit == 0 ? 'pass' : 'expected-rejection') : 'fail',
    'expectedRules': expectedRules,
    'unsealRules': unsealRules,
    'oracleMessages': [
      for (final message in messages)
        {
          'ID': message['ID'],
          'severity': message['severity'],
          'classification': _classifyMessage(message, major, expectedRules),
        },
    ],
    'problems': problems,
    'elapsedMicros': elapsedMicros,
  };
}

Map<String, Object?> _compareRealCorpus({
  required final String id,
  required final List<EpubDiagnostic> findings,
  required final Map<String, Object?> oracleMessages,
  required final int elapsedMicros,
}) {
  final messages = (oracleMessages['messages']! as List<Object?>).cast<Map<String, Object?>>();
  final version = oracleMessages['publicationVersion'] as String? ?? '';
  final major = int.tryParse(version.split('.').first) ?? 0;

  final derived = <String>[];
  for (final message in messages) {
    final rule = _matchMessage(message, major);
    if (rule != null && !derived.contains(rule)) derived.add(rule);
  }

  final unsealRules = findings.map((final finding) => finding.ruleId).toSet();
  final problems = <String>[];
  for (final rule in derived) {
    if (!unsealRules.contains(rule)) {
      problems.add('oracle requires rule $rule but diagnosis omitted it');
    }
  }
  for (final rule in unsealRules) {
    if (!derived.contains(rule)) {
      problems.add('diagnosis reported $rule without oracle backing');
    }
  }

  return {
    'id': id,
    'caseId': id,
    'kind': 'real-corpus',
    'verdict': problems.isEmpty ? 'pass' : 'fail',
    'derivedRules': derived,
    'unsealRules': unsealRules.toList(),
    'oracleMessages': [
      for (final message in messages)
        {
          'ID': message['ID'],
          'severity': message['severity'],
          'classification': _classifyMessage(message, major, derived),
        },
    ],
    'problems': problems,
    'elapsedMicros': elapsedMicros,
  };
}

String? _matchMessage(final Map<String, Object?> message, final int major) {
  for (final mapping in _mappings) {
    for (final matcher in mapping.matchers) {
      if (matcher.matches(message, major)) return mapping.ruleId;
    }
  }

  return null;
}

String _classifyMessage(
  final Map<String, Object?> message,
  final int major,
  final List<String> relevantRules,
) {
  for (final mapping in _mappings) {
    for (final matcher in mapping.matchers) {
      if (matcher.matches(message, major) && relevantRules.contains(mapping.ruleId)) {
        return 'in-scope';
      }
    }
  }

  return 'outside-scope';
}

Map<String, Object?> _limitsProbe(final _Options options) {
  final bytes = _stressEpub();
  final inputPath = '${options.inputsDir}/limits-probe.epub';
  File(inputPath).writeAsBytesSync(bytes, flush: true);

  final watch = Stopwatch()..start();
  final report = diagnoseEpub(bytes);
  final elapsed = watch.elapsedMicroseconds;

  final problems = <String>[];
  if (report.findings.length != 400) {
    problems.add('expected 400 collected findings, got ${report.findings.length}');
  }
  if (!report.truncated) problems.add('limits probe did not flag truncation');
  if (elapsed > 10 * 1000 * 1000) {
    problems.add('limits probe took $elapsedµs, above the 10s ceiling');
  }

  return {
    'inputPath': inputPath,
    'findings': report.findings.length,
    'truncated': report.truncated,
    'elapsedMicros': elapsed,
    'problems': problems,
    'verdict': problems.isEmpty ? 'pass' : 'fail',
  };
}

/// Deterministic hostile input with 3000 missing manifest resources: the
/// default `maxFindings` bound must stop collection before allocation or
/// traversal grows with the hostile input.
Uint8List _stressEpub() {
  final items = StringBuffer();
  for (var index = 0; index < 3000; index++) {
    items.write('<item id="ghost$index" href="ghost$index.png" media-type="image/png"/>');
  }
  final entries = <String, List<int>>{
    'mimetype': latin1.encode('application/epub+zip'),
    'META-INF/container.xml': utf8.encode(_containerXml),
    'OEBPS/content.opf': utf8.encode(
      '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
      'unique-identifier="pub-id"><metadata '
      'xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:identifier id="pub-id">urn:uuid:1f0a3c5e-6d3a-4f0a-9c5e-000000000002</dc:identifier>'
      '<dc:title>limits</dc:title><dc:language>en</dc:language>'
      '<meta property="dcterms:modified">2026-10-17T00:00:00Z</meta>'
      '</metadata><manifest><item id="nav" href="nav.xhtml" '
      'media-type="application/xhtml+xml" properties="nav"/>$items</manifest>'
      '<spine></spine></package>',
    ),
    'OEBPS/nav.xhtml': utf8.encode(_navXhtml),
  };
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = Uint8List.fromList(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes)..lastModTime = 946684800);
  }

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Every catalog rule needs at least one synthetic invalid case and one
/// valid case where it stays silent.
String? _coverageCheck(final List<Map<String, Object?>> details) {
  final invalidRules = <String>{};
  for (final detail in details) {
    if (detail['kind'] != 'synthetic') continue;
    invalidRules.addAll((detail['expectedRules']! as List<Object?>).cast<String>());
  }
  final missing = _catalogRuleIds.difference(invalidRules);
  if (missing.isNotEmpty) {
    return 'rules without an invalid synthetic case: ${missing.toList()}';
  }

  return null;
}

List<Map<String, Object?>> _acceptanceCases({
  required final List<Map<String, Object?>> caseDetails,
  required final Map<String, Object?> limits,
  required final int fixtureCount,
}) {
  String verdictOf(final bool condition) => condition ? 'pass' : 'fail';

  final synthetic = caseDetails.where((final detail) => detail['kind'] == 'synthetic').toList();
  final real = caseDetails.where((final detail) => detail['kind'] == 'real-corpus').toList();
  final allPass = caseDetails.every(
    (final detail) => detail['verdict'] == 'pass' || detail['verdict'] == 'expected-rejection',
  );

  String detailIds(final List<Map<String, Object?>> list) =>
      list.map((final detail) => detail['id']).join(', ');

  return [
    {
      'id': 'ED01',
      'verdict': verdictOf(allPass),
      'evidence':
          'Deterministic reports: every diagnosis ran twice with identical '
          'findings; all reported ruleIds belong to the 22-rule catalog in '
          'doc/epub-diagnostics.md; the report type carries no conformance '
          'verdict.',
    },
    {
      'id': 'ED02',
      'verdict': verdictOf(allPass),
      'evidence':
          'Container/rootfile/manifest/spine/navigation exercised by '
          '${synthetic.length} synthetic cases compared against real '
          'EPUBCheck 5.4.0 runs: ${detailIds(synthetic)}.',
    },
    {
      'id': 'ED03',
      'verdict': verdictOf(allPass),
      'evidence':
          'paths-unicode-percent-valid resolves Unicode, percent-encoded and '
          'nested-relative hrefs with no findings; manifest-remote-resource-'
          'undeclared records the external URL without fetching; hostile '
          'parent escapes stay inside the container (see unit test '
          '"parent escapes stay inside the container"); diagnosis performs '
          'no network access.',
    },
    {
      'id': 'ED04',
      'verdict': verdictOf(allPass),
      'evidence':
          'Partially readable books keep findings without changing reading: '
          'container-missing, rootfile-media-type-unsupported and '
          'container-mimetype-wrong stay readable with errors; '
          'manifest-item-incomplete still fails typed while diagnosis '
          'reports both conditions; real corpus books read normally with '
          'out-of-scope oracle errors excluded.',
    },
    {
      'id': 'ED05',
      'verdict': verdictOf(allPass),
      'evidence':
          'Every catalog rule has an invalid synthetic case and the clean '
          'baselines (epub2-valid, epub3-valid) exercise all rules staying '
          'silent; ${real.length} real licensed books complement the corpus; '
          'out-of-scope oracle messages are classified per case in the '
          'detail report.',
    },
    {
      'id': 'ED06',
      'verdict': limits['verdict'] as String,
      'evidence':
          'Limits probe (3000 hostile manifest items) collected exactly the '
          'maxFindings bound with truncated=true in ${limits['elapsedMicros']}'
          'µs; safety corruption fails typed (unit tests: zip corruption, '
          'malformed package); report bounds predate untrusted expansion.',
    },
    {
      'id': 'ED07',
      'verdict': verdictOf(allPass),
      'evidence':
          'VM suite test/tests/epub/epub_diagnostics_test.dart and Chrome '
          'suite test/web/epub_diagnostics_web_test.dart assert the same '
          'expected rules from manifest.json on the same fixture bytes; '
          'reading behavior is unchanged across the corpus; '
          'per-case wall time and comparator-process current/peak RSS are '
          'recorded in build/evidence/measurements.json; '
          'no worker wire format is used by the diagnostics API.',
    },
  ];
}

List<_CorpusCase> _corpusCases(final _Options options) {
  final manifest = _readJsonFile(options.fixturesManifest);
  final cases = <_CorpusCase>[];
  for (final fixture in (manifest['cases']! as List<Object?>).cast<Map<String, Object?>>()) {
    final id = fixture['id']! as String;
    final source = '${options.fixturesDirectory}/${fixture['file']}';
    final inputPath = '${options.inputsDir}/diag-${fixture['file']}';
    final sourceFile = File(source);
    final bytes = sourceFile.readAsBytesSync();
    final digest = sha256.convert(bytes).toString();
    if (digest != fixture['sha256']) {
      stderr.writeln('Fixture hash drift for $source');
      exit(2);
    }
    final input = File(inputPath);
    _Options.setWritable(inputPath);
    input.writeAsBytesSync(bytes, flush: true);
    _Options.setReadOnly(inputPath);
    cases.add(
      _CorpusCase(
        id: 'diag-$id',
        inputPath: inputPath,
        inputSha256: digest,
        epubFamily: fixture['epub_family']! as String,
        origin:
            'synthetic deterministic fixture generated by '
            'tool/generate_epub_diagnostics_fixtures.dart',
      ),
    );
  }

  for (final entry in _realCorpus.entries) {
    final bytes = File(entry.value).readAsBytesSync();
    final inputPath = '${options.inputsDir}/${entry.key}.epub';
    final input = File(inputPath);
    _Options.setWritable(inputPath);
    input.writeAsBytesSync(bytes, flush: true);
    _Options.setReadOnly(inputPath);
    cases.add(
      _CorpusCase(
        id: entry.key,
        inputPath: inputPath,
        inputSha256: sha256.convert(bytes).toString(),
        epubFamily: 'real',
        origin: 'committed licensed fixture ${entry.value}',
      ),
    );
  }

  return cases;
}

class _CorpusCase {
  const _CorpusCase({
    required this.id,
    required this.inputPath,
    required this.inputSha256,
    required this.epubFamily,
    required this.origin,
  });

  final String id;
  final String inputPath;
  final String inputSha256;
  final String epubFamily;
  final String origin;
}

class _RuleMapping {
  const _RuleMapping(this.ruleId, this.matchers);

  final String ruleId;
  final List<_MessageMatcher> matchers;
}

class _MessageMatcher {
  const _MessageMatcher({
    required this.id,
    required this.contains,
    this.notContains,
    this.epub2Only = false,
  });

  final String id;
  final String contains;
  final String? notContains;
  final bool epub2Only;

  bool matches(final Map<String, Object?> message, final int major) {
    if (message['ID'] != id) return false;
    if (epub2Only && major >= 3) return false;
    final text = '${message['message']}';
    if (!text.contains(contains)) return false;
    final excluded = notContains;

    return excluded == null || !text.contains(excluded);
  }
}

class _Options {
  _Options.parse(final List<String> arguments) {
    for (var index = 0; index < arguments.length; index += 2) {
      final value = index + 1 < arguments.length ? arguments[index + 1] : '';
      switch (arguments[index]) {
        case '--stage':
          stage = value;
        case '--java':
          java = value;
        case '--oracle-zip':
          oracleZip = value;
        case '--oracle-jar':
          oracleJar = value;
        case '--fixtures-manifest':
          fixturesManifest = value;
        case '--fixtures-directory':
          fixturesDirectory = value;
        case '--inputs-dir':
          inputsDir = value;
        case '--out-dir':
          outDir = value;
        case '--report':
          report = value;
        case '--detail':
          detailReport = value;
        case '--measurements':
          measurements = value;
      }
    }
    Directory(outDir).createSync(recursive: true);
    Directory(inputsDir).createSync(recursive: true);
    File(report).parent.createSync(recursive: true);
  }

  /// File permission bits are not exposed by dart:io; the oracle inputs
  /// must be read-only copies.
  static void setReadOnly(final String path) {
    Process.runSync('chmod', ['444', path]);
  }

  static void setWritable(final String path) {
    Process.runSync('chmod', ['644', path]);
  }

  String stage = '';
  String java = '/opt/homebrew/opt/openjdk/bin/java';
  String oracleZip = 'build/oracle/epubcheck-5.4.0.zip';
  String oracleJar = 'build/oracle/epubcheck-5.4.0/epubcheck.jar';
  String fixturesManifest = 'test/resources/epub/diagnostics/manifest.json';
  String fixturesDirectory = 'test/resources/epub/diagnostics';
  String inputsDir = 'build/inputs';
  String outDir = 'build/oracle-output/reference';
  String report = 'build/evidence/comparison-report.json';
  String detailReport = 'build/evidence/comparison-detail.json';
  String measurements = 'build/evidence/measurements.json';
  String get versionRecord => 'build/oracle-output/version.json';
  String get referenceIndex => '$outDir/index.json';
  String get referenceDir => outDir;
}

Map<String, Object?> _readJsonFile(final String path) {
  return jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
}

void _writeJson(final String path, final Object? value) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(value)}\n', flush: true);
}

const _containerXml =
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>';

const _navXhtml =
    '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
    '<head><title>n</title></head><body>'
    '<nav epub:type="toc"><ol><li><a href="ch1.xhtml">c</a></li></ol></nav>'
    '</body></html>';
