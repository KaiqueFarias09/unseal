/// B04 acceptance comparator: eager ↔ session ↔ Calibre for MOBI/AZW3.
///
/// Compares three independent readings of one book under the frozen
/// comparison policy in `doc/mobi-sessions.md`:
///
/// * **eager** — `Unseal.parse` over the same bytes;
/// * **session** — a progressive `BookSession` (structure + on-demand
///   content) over the same bytes;
/// * **Calibre** — the independent `ebook-convert` OEB output for the
///   same input file, parsed through the same canonical text scanner.
///
/// Content parity (text, resources, navigation, metadata) and
/// progressivity (materialization counters) are reported as separate
/// case rows: equal content never proves progressive delivery. The
/// report JSON feeds `oracle_gate.py`; the tool exits non-zero when a
/// case lands outside its declared verdict set.
///
/// Usage:
/// ```
/// dart run tool/mobi_session_compare.dart --input book.mobi \
///   --calibre build/calibre-initial/mobi6-oeb \
///   --out build/evidence/b04/report.json
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as html_parser;
import 'package:unseal/unseal.dart';
import 'package:xml/xml.dart';

Future<void> main(final List<String> arguments) async {
  final inputPath = _stringOption(arguments, '--input');
  final calibreDir = _stringOption(arguments, '--calibre');
  final outPath = _stringOption(arguments, '--out');
  final includeSession = arguments.contains('--session');
  if (arguments.contains('--acceptance')) {
    await _runAcceptance(arguments);
    return;
  }
  if (inputPath == null || outPath == null) {
    stderr.writeln(
      'usage: dart run tool/mobi_session_compare.dart --input <file> '
      '[--calibre <oeb-dir>] --out <report.json> [--session] | '
      '--acceptance --mobi <file> --azw3 <file> --out <report.json>',
    );
    exit(2);
  }

  final bytes = File(inputPath).readAsBytesSync();
  final inputSha = sha256Hex(bytes);
  final cases = <Map<String, Object?>>[];

  final eager = _eagerFingerprint(bytes);
  cases.add(
    _case('MS01', 'eager fingerprint recorded', 'pass', {
      'format': eager.formatName,
      'readingOrder': eager.readingOrderNames,
    }),
  );

  if (includeSession) {
    cases.addAll(await _sessionCases(bytes, eager));
  }

  if (calibreDir != null) {
    cases.add(_calibreCase(calibreDir, eager, inputPath: inputPath));
  }

  final report = <String, Object?>{
    'schemaVersion': 1,
    'input': {'path': inputPath, 'sha256': inputSha, 'bytes': bytes.length},
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'cases': cases,
  };
  final outFile = File(outPath);
  await outFile.parent.create(recursive: true);
  await outFile.writeAsString(const JsonEncoder.withIndent('  ').convert(report));

  final failed = cases
      .where((final row) => (row['verdict'] as String) == 'fail')
      .map((final row) => row['id'])
      .toList();
  if (failed.isNotEmpty) {
    stderr.writeln('comparison FAILED for: $failed');
    exit(1);
  }
  stdout.writeln('comparison OK: ${cases.length} case rows -> $outPath');
  // Explicit: spawned browser-test processes can leave handles that
  // would otherwise keep this VM's event loop alive past main.
  exit(0);
}

// ---------------------------------------------------------------------------
// Eager fingerprint
// ---------------------------------------------------------------------------

final class _EagerFingerprint {
  _EagerFingerprint({
    required this.formatName,
    required this.readingOrderNames,
    required this.sectionTexts,
    required this.sectionSources,
    required this.resourceHashes,
    required this.navLabels,
    required this.navTargets,
    required this.navDepths,
    required this.metadata,
  });

  final String formatName;
  final List<String> readingOrderNames;
  final List<String> sectionTexts;
  final List<String> sectionSources;
  final Map<String, String> resourceHashes;
  final List<String> navLabels;
  final List<String> navTargets;
  final List<int> navDepths;
  final Map<String, Object?> metadata;
}

_EagerFingerprint _eagerFingerprint(final Uint8List bytes) {
  final book = Unseal.parse(bytes);
  final mobi = book as MobiBook;
  final order = book.readingOrder;
  final texts = <String>[];
  final sources = <String>[];
  for (final item in order) {
    TextFile file = mobi.files.html.first;
    for (final candidate in mobi.files.html) {
      if (candidate.path == item.name) {
        file = candidate;
        break;
      }
    }
    texts.add(documentTextOf(file));
    sources.add(file.content);
  }
  final resources = <String, String>{};
  for (final file in [...mobi.files.images, ...mobi.files.fonts]) {
    resources[file.path] = sha256Hex(file.content);
  }
  final labels = <String>[];
  final targets = <String>[];
  final depths = <int>[];
  void walk(final List<NavPoint> points, [final int depth = 0]) {
    for (final point in points) {
      labels.add(point.label);
      targets.add(point.content);
      depths.add(depth);
      walk(point.subNavPoints, depth + 1);
    }
  }

  walk(mobi.navigation.navPoints);
  final metadata = mobi.metadata;

  return _EagerFingerprint(
    formatName: mobi.format.name,
    readingOrderNames: <String>[for (final item in order) item.name],
    sectionTexts: texts,
    sectionSources: sources,
    resourceHashes: resources,
    navLabels: labels,
    navTargets: targets,
    navDepths: depths,
    metadata: <String, Object?>{
      'title': metadata.title,
      'authors': metadata.authors,
      'languages': metadata.languages,
      'identifiers': metadata.identifiers,
    },
  );
}

// ---------------------------------------------------------------------------
// Calibre leg
// ---------------------------------------------------------------------------

Map<String, Object?> _calibreCase(
  final String oebDir,
  final _EagerFingerprint eager, {
  required final String inputPath,
}) {
  final dir = Directory(oebDir);
  final opfFile = dir.existsSync() ? _findOpf(dir) : null;
  if (opfFile == null) {
    return _case('MS03-calibre', 'Calibre OEB package missing', 'fail', {'dir': oebDir});
  }
  final opf = XmlDocument.parse(opfFile.readAsStringSync());
  final ns = opf.rootElement.namespaceUri;
  final items = {
    for (final item in opf.findAllElements('item', namespaceUri: ns))
      if (item.getAttribute('id') case final String id) id: item,
  };
  File resource(final String href) => File.fromUri(opfFile.uri.resolve(href.split('#').first));
  final pieces = <String>[];
  final problems = <String>[];
  for (final itemref in opf.findAllElements('itemref', namespaceUri: ns)) {
    final item = items[itemref.getAttribute('idref')];
    final href = item?.getAttribute('href');
    if (href == null || !resource(href).existsSync()) {
      problems.add('Calibre spine resource missing: $href');
      continue;
    }
    pieces.add(
      documentTextOf(
        TextFile(content: resource(href).readAsStringSync(), name: '', type: '', path: href),
      ),
    );
  }
  final calibreText = _collapseWhitespace(pieces.join('\n'));
  final unsealText = _collapseWhitespace(eager.sectionTexts.join('\n'));
  if (pieces.isEmpty || calibreText != unsealText) problems.add('canonical text differs');

  const dc = 'http://purl.org/dc/elements/1.1/';
  List<String> metadataValues(final String name) => [
    for (final element in opf.findAllElements(name, namespaceUri: dc))
      _collapseWhitespace(element.innerText),
  ];
  final referenceMetadata = <String, Object?>{
    'title': metadataValues('title').firstOrNull,
    'authors': metadataValues('creator'),
    'languages': metadataValues('language'),
  };
  for (final key in referenceMetadata.keys) {
    if (jsonEncode(referenceMetadata[key]) != jsonEncode(eager.metadata[key])) {
      problems.add('metadata $key differs');
    }
  }
  final sourceIdentifiers = <String, String>{};
  for (final element in opf.findAllElements('identifier', namespaceUri: dc)) {
    final scheme = element.getAttribute('scheme', namespaceUri: ns)?.toLowerCase();
    // ebook-convert synthesizes UUIDs. They are not identifiers from the input.
    if (scheme == 'uuid') continue;
    if (scheme != null) {
      sourceIdentifiers[scheme == 'mobi-asin' ? 'asin' : scheme] = element.innerText;
    }
  }
  final unsealIdentifiers = eager.metadata['identifiers'] as Map<String, String>;
  for (final identifier in sourceIdentifiers.entries) {
    if (unsealIdentifiers[identifier.key] != identifier.value) {
      problems.add('source identifier ${identifier.key} differs');
    }
  }

  final ncxItem = items.values
      .where((item) => item.getAttribute('media-type') == 'application/x-dtbncx+xml')
      .firstOrNull;
  final navDetails = <Map<String, Object?>>[];
  if (ncxItem == null) {
    problems.add('Calibre navigation reference missing');
  } else {
    final ncxFile = resource(ncxItem.getAttribute('href')!);
    final ncx = XmlDocument.parse(ncxFile.readAsStringSync());
    final points = ncx.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'navPoint')
        .toList();
    if (points.length != eager.navLabels.length) problems.add('navigation count differs');
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final label = point.childElements.where((e) => e.name.local == 'navLabel').first.innerText;
      final target = point.childElements
          .where((e) => e.name.local == 'content')
          .first
          .getAttribute('src')!;
      final targetFile = File.fromUri(ncxFile.uri.resolve(target.split('#').first));
      final referenceContext = targetFile.existsSync()
          ? _targetContext(targetFile.readAsStringSync(), target)
          : null;
      String? actualContext;
      if (i < eager.navTargets.length) {
        final actualTarget = eager.navTargets[i];
        final name = actualTarget.split('#').first;
        final section = name.isEmpty ? 0 : eager.readingOrderNames.indexOf(name);
        if (section >= 0) {
          actualContext = _targetContext(eager.sectionSources[section], actualTarget);
        }
      }
      final labelsEqual =
          i < eager.navLabels.length &&
          _collapseWhitespace(label) == _collapseWhitespace(eager.navLabels[i]);
      final depth = point.ancestors
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'navPoint')
          .length;
      final depthEqual = i < eager.navDepths.length && eager.navDepths[i] == depth;
      final targetsEqual = referenceContext != null && referenceContext == actualContext;
      if (!labelsEqual || !targetsEqual || !depthEqual) problems.add('navigation entry $i differs');
      navDetails.add({
        'label': label,
        'target': target,
        'labelsEqual': labelsEqual,
        'targetsEqual': targetsEqual,
        'depthEqual': depthEqual,
        'depth': depth,
        'referenceContext': referenceContext,
        'unsealContext': actualContext,
      });
    }
  }

  final referencePath =
      'build/evidence/b04/calibre-resources-${sha256Hex(File(inputPath).readAsBytesSync())}.json';
  final calibreDebug =
      Platform.environment['CALIBRE_DEBUG'] ??
      '/Applications/calibre.app/Contents/MacOS/calibre-debug';
  final argv = [
    calibreDebug,
    '-e',
    'tool/mobi_calibre_resources.py',
    '--',
    inputPath,
    referencePath,
  ];
  final run = Process.runSync(argv.first, argv.sublist(1));
  Map<String, Object?>? rawReference;
  if (run.exitCode == 0 && File(referencePath).existsSync()) {
    rawReference = (jsonDecode(File(referencePath).readAsStringSync()) as Map)
        .cast<String, Object?>();
    if (rawReference['inputSha256'] != sha256Hex(File(inputPath).readAsBytesSync())) {
      problems.add('Calibre raw-resource input hash differs');
    }
    final expectedHashes = [
      for (final entry in rawReference['resources']! as List) (entry as Map)['sha256'] as String,
    ]..sort();
    final actualHashes = eager.resourceHashes.values.toList()..sort();
    if (jsonEncode(expectedHashes) != jsonEncode(actualHashes)) {
      problems.add('raw image/font resource hash multiset differs');
    }
  } else {
    problems.add('Calibre raw-resource reference failed: ${run.exitCode} ${run.stderr}');
  }
  return _case(
    'MS03-calibre',
    'Independent Calibre text, metadata, navigation targets and resource hashes',
    problems.isEmpty ? 'pass' : 'fail',
    {
      'problems': problems,
      'characters': unsealText.length,
      if (calibreText != unsealText) 'textDivergence': _firstDivergence(unsealText, calibreText),
      'referenceMetadata': referenceMetadata,
      'unsealMetadata': eager.metadata,
      'sourceIdentifiers': sourceIdentifiers,
      'navigation': navDetails,
      'rawResources': rawReference,
      'referenceCommand': argv,
      'referenceExitCode': run.exitCode,
      'normalization':
          'R5 text; navigation label order and 96 non-whitespace canonical characters at resolved anchors; binary image/font hash multiset ignores names; generated Calibre UUID and rewritten CSS excluded',
    },
  );
}

String? _targetContext(final String source, final String target) {
  final document = html_parser.parse(source);
  final fragment = target.contains('#') ? Uri.decodeComponent(target.split('#').last) : null;
  var active = fragment == null;
  var found = active;
  final text = StringBuffer();
  void visit(final html.Node node) {
    if (node is html.Element) {
      if (node.localName == 'script' || node.localName == 'style' || node.localName == 'head') {
        return;
      }
      if (node.id == fragment || node.attributes['name'] == fragment) {
        active = true;
        found = true;
      }
    }
    if (active && node is html.Text) text.write(node.text);
    for (final child in node.nodes) {
      visit(child);
    }
  }

  visit(document.body ?? document);
  if (!found) return null;
  final normalized = _collapseWhitespace(text.toString()).replaceAll(RegExp(r'\s+'), '');
  return normalized.substring(0, normalized.length < 96 ? normalized.length : 96);
}

File? _findOpf(final Directory dir) {
  for (final file in dir.listSync(recursive: true)) {
    if (file is File && file.path.toLowerCase().endsWith('.opf')) return file;
  }

  return null;
}

// ---------------------------------------------------------------------------
// Session leg (populated by the B04 implementation)
// ---------------------------------------------------------------------------

Future<List<Map<String, Object?>>> _sessionCases(
  final Uint8List bytes,
  final _EagerFingerprint eager,
) async {
  final session = await BookSession.open(bytes);
  try {
    return await _sessionCaseRows(session, eager);
  } finally {
    session.dispose();
  }
}

Future<List<Map<String, Object?>>> _sessionCaseRows(
  final BookSession session,
  final _EagerFingerprint eager,
) async {
  final cases = <Map<String, Object?>>[];
  final mobiHeader = session.book as MobiBook;
  final order = session.book.readingOrder;

  // R1 canonical text: concatenated session section text equals the
  // eager text (MOBI6) or the per-part text (KF8).
  final sessionTexts = <String>[];
  for (final item in order) {
    final text = await session.loadDocumentText(item.name);
    if (text == null) {
      cases.add(_case('MS03-session-text', 'Section ${item.name} did not materialize', 'fail', {}));
      return cases;
    }
    sessionTexts.add(text);
  }
  // Declared R1: plain concatenation in reading order, no separator.
  final joinedSession = _collapseWhitespace(sessionTexts.join());
  final joinedEager = _collapseWhitespace(eager.sectionTexts.join());
  cases.add(
    joinedSession == joinedEager
        ? _case('MS03-session-text', 'Session text equals eager text under R1', 'pass', {
            'characters': joinedEager.length,
          })
        : _case('MS03-session-text', 'Session text differs from eager text', 'fail', {
            'divergence': _firstDivergence(joinedEager, joinedSession),
          }),
  );

  // R2 resource hashes: every eager resource loads on demand with the
  // same bytes.
  final mismatched = <String>[];
  for (final entry in eager.resourceHashes.entries) {
    final bytesOnDemand = await session.loadResource(entry.key);
    if (bytesOnDemand == null || sha256Hex(bytesOnDemand) != entry.value) {
      mismatched.add(entry.key);
    }
  }
  cases.add(
    mismatched.isEmpty
        ? _case(
            'MS03-session-resources',
            'All eager resources load with identical hashes',
            'pass',
            {'resources': eager.resourceHashes.length},
          )
        : _case('MS03-session-resources', 'Resource hash mismatches', 'fail', {
            'mismatched': mismatched,
          }),
  );

  // R3 navigation labels and target resolvability.
  final labels = <String>[];
  final targets = <String>[];
  final depths = <int>[];
  void walk(final List<NavPoint> points, [final int depth = 0]) {
    for (final point in points) {
      labels.add(point.label);
      targets.add(point.content);
      depths.add(depth);
      walk(point.subNavPoints, depth + 1);
    }
  }

  walk(mobiHeader.navigation.navPoints);
  final unresolvable = <String>[
    for (final target in targets)
      if (!(await _sessionTargetResolves(session, target))) target,
  ];
  final depthMatch = jsonEncode(depths) == jsonEncode(eager.navDepths);
  final targetMatch =
      eager.formatName == 'mobi' || jsonEncode(targets) == jsonEncode(eager.navTargets);
  final labelsMatch =
      labels.length == eager.navLabels.length &&
      List<String>.of(eager.navLabels).join('\u0000') == labels.join('\u0000');
  cases.add(
    labelsMatch && depthMatch && targetMatch && unresolvable.isEmpty
        ? _case('MS03-session-nav', 'Navigation labels equal and targets resolve', 'pass', {
            'entries': labels.length,
          })
        : _case('MS03-session-nav', 'Navigation mismatch', 'fail', {
            'labelsMatch': labelsMatch,
            'depthMatch': depthMatch,
            'targetsMatch': targetMatch,
            'unresolvable': unresolvable.take(8).toList(),
          }),
  );

  // R4 metadata.
  final metadata = session.book.metadata;
  final metadataEqual =
      const JsonEncoder().convert(eager.metadata) ==
      const JsonEncoder().convert(<String, Object?>{
        'title': metadata.title,
        'authors': metadata.authors,
        'languages': metadata.languages,
        'identifiers': metadata.identifiers,
      });
  cases.add(
    metadataEqual
        ? _case('MS03-session-metadata', 'Metadata equal', 'pass', {})
        : _case('MS03-session-metadata', 'Metadata mismatch', 'fail', {
            'eager': eager.metadata,
            'session': <String, Object?>{
              'title': metadata.title,
              'authors': metadata.authors,
              'languages': metadata.languages,
              'identifiers': metadata.identifiers,
            },
          }),
  );

  return cases;
}

Future<bool> _sessionTargetResolves(final BookSession session, final String target) async {
  // Declared R3 rule: a target resolves when its section path exists
  // in the reading order and its fragment anchor survives in the
  // section source.
  final withoutFragment = target.split('#').first;
  final fragment = target.contains('#') ? target.split('#').last : null;
  final names = <String>[for (final item in session.book.readingOrder) item.name];
  String? section;
  if (withoutFragment.isNotEmpty) {
    final direct = withoutFragment;
    section = names.contains(direct)
        ? direct
        : names.where((final name) => name.endsWith('/$direct')).firstOrNull;
  } else {
    section = names.firstOrNull;
  }
  if (section == null) return false;
  if (fragment == null) return true;

  final source = await session.loadDocumentSource(section);
  if (source == null) return false;

  return source.contains('id="$fragment"') || source.contains("id='$fragment'");
}

// ---------------------------------------------------------------------------
// Shared normalization and helpers
// ---------------------------------------------------------------------------

String _collapseWhitespace(final String text) {
  final buffer = StringBuffer();
  var pendingSpace = false;
  for (final unit in text.runes) {
    // Declared R5 normalization: ASCII whitespace and Unicode space
    // separators (the set the source formats use for typographic
    // spacing) collapse to single spaces, so reconstruction
    // differences in spacing alone never fail the comparison.
    final isSpace =
        unit == 0x20 ||
        (unit >= 0x09 && unit <= 0x0D) ||
        unit == 0xA0 ||
        unit == 0x1680 ||
        (unit >= 0x2000 && unit <= 0x200A) ||
        unit == 0x2028 ||
        unit == 0x2029 ||
        unit == 0x202F ||
        unit == 0x205F ||
        unit == 0x3000 ||
        unit == 0xFEFF;
    if (isSpace) {
      pendingSpace = true;
      continue;
    }
    if (pendingSpace && buffer.isNotEmpty) buffer.write(' ');
    pendingSpace = false;
    buffer.writeCharCode(unit);
  }

  return buffer.toString().trim();
}

Map<String, Object?> _firstDivergence(final String expected, final String actual) {
  final limit = expected.length < actual.length ? expected.length : actual.length;
  var at = 0;
  while (at < limit && expected[at] == actual[at]) {
    at++;
  }
  String window(final String text) {
    final start = at - 40 < 0 ? 0 : at - 40;
    final end = at + 80 > text.length ? text.length : at + 80;

    return text.substring(start, end);
  }

  return <String, Object?>{
    'atCharacter': at,
    'expectedContext': window(expected),
    'actualContext': window(actual),
  };
}

Map<String, Object?> _case(
  final String id,
  final String description,
  final String verdict,
  final Map<String, Object?> details,
) {
  return <String, Object?>{'id': id, 'description': description, 'verdict': verdict, ...details};
}

String sha256Hex(final Uint8List bytes) => sha256.convert(bytes).toString();

String? _stringOption(final List<String> arguments, final String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;

  return arguments[index + 1];
}

// ---------------------------------------------------------------------------
// B04 acceptance sweep: one case row per MS01–MS07
// ---------------------------------------------------------------------------

Future<void> _runAcceptance(final List<String> arguments) async {
  final mobiPath = _stringOption(arguments, '--mobi');
  final azw3Path = _stringOption(arguments, '--azw3');
  final outPath = _stringOption(arguments, '--out');
  final calibreMobi = _stringOption(arguments, '--calibre-mobi');
  final calibreAzw3 = _stringOption(arguments, '--calibre-azw3');
  if (mobiPath == null ||
      azw3Path == null ||
      outPath == null ||
      calibreMobi == null ||
      calibreAzw3 == null) {
    stderr.writeln(
      'acceptance mode needs --mobi, --azw3, --calibre-mobi, --calibre-azw3 and --out',
    );
    exit(2);
  }

  final cases = <Map<String, Object?>>[];

  // MS01/MS02/MS04–MS07 map to the acceptance test groups; each runs as
  // a real `dart test` invocation so the gate executes the same
  // behavioral contract CI does.
  final groups = <(String, String, List<String>)>[
    (
      'MS01',
      'MOBI 6 session open with structural header and on-demand content',
      ['test/tests/progressive/mobi_session_test.dart'],
    ),
    (
      'MS02',
      'AZW3/KF8 sessions plus the compression matrix over the real and generated corpus',
      ['test/tests/progressive/mobi_session_matrix_test.dart'],
    ),
    (
      'MS04',
      'instrumentation proves open materializes nothing and bounded per-section work',
      ['test/tests/progressive/mobi_session_metrics_test.dart'],
    ),
    (
      'MS05',
      'search, index, progression, statistics, reopening and incompatible revision',
      ['test/tests/progressive/mobi_session_reading_test.dart'],
    ),
    (
      'MS06',
      'VM isolate sessions: concurrency, out-of-order, cancellation, disposal',
      ['test/tests/progressive/mobi_session_lifecycle_test.dart'],
    ),
    (
      'MS07',
      'hostile PalmDB structures, limits and DRM refusal',
      ['test/tests/progressive/mobi_session_hostile_test.dart'],
    ),
  ];
  for (final (id, description, files) in groups) {
    final result = await _runDartTest(files);
    cases.add(
      _case(id, description, result ? 'pass' : 'fail', {'command': 'dart test ${files.join(' ')}'}),
    );
  }

  final baselines = <Map<String, Object?>>[];
  var baselinesOk = true;
  for (final input in [mobiPath, azw3Path]) {
    final baselinePath =
        'build/evidence/b04/baseline-${sha256Hex(File(input).readAsBytesSync())}.json';
    final (ok, _) = await _runCaptured([
      'run',
      'tool/mobi_session_bench.dart',
      '--input',
      input,
      '--out',
      baselinePath,
    ]);
    baselinesOk = baselinesOk && ok;
    baselines.add({
      'path': baselinePath,
      'exitPassed': ok,
      if (ok) 'report': jsonDecode(File(baselinePath).readAsStringSync()),
    });
  }
  final ms04 = cases.firstWhere((row) => row['id'] == 'MS04');
  ms04['isolatedBaselines'] = baselines;
  if (!baselinesOk) ms04['verdict'] = 'fail';

  // MS06's Chrome half: the real Web Worker lane for MOBI sessions.
  final chromeOk = await _runChromeWorkerTest();
  final ms06 = cases.firstWhere((final row) => row['id'] == 'MS06');
  ms06['chromeWorker'] = chromeOk ? 'pass' : 'fail';
  if (!chromeOk) ms06['verdict'] = 'fail';

  // MS03: content parity eager ↔ session and the independent Calibre
  // comparison, under the frozen rules.
  final parity = <Map<String, Object?>>[];
  var parityOk = true;
  final inputs = <(String, String?)>[(mobiPath, calibreMobi), (azw3Path, calibreAzw3)];
  for (final (path, calibreDir) in inputs) {
    final bytes = File(path).readAsBytesSync();
    final eager = _eagerFingerprint(bytes);
    final rows = await _sessionCases(bytes, eager);
    for (final row in rows) {
      if ((row['verdict'] as String) != 'pass') parityOk = false;
      parity.add(<String, Object?>{'input': path, 'case': row['id'], 'verdict': row['verdict']});
    }
    if (calibreDir != null) {
      final row = _calibreCase(calibreDir, eager, inputPath: path);
      if ((row['verdict'] as String) != 'pass') parityOk = false;
      parity.add(<String, Object?>{
        'input': path,
        'case': 'calibre',
        'verdict': row['verdict'],
        'details': row,
      });
    }
  }
  cases.add(
    _case(
      'MS03',
      'eager/session parity and Calibre comparison under the frozen rules',
      parityOk ? 'pass' : 'fail',
      {'rows': parity},
    ),
  );

  final report = <String, Object?>{
    'schemaVersion': 1,
    'mode': 'acceptance',
    'commandRuns': _acceptanceCommands,
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'cases': cases,
  };
  final outFile = File(outPath);
  await outFile.parent.create(recursive: true);
  await outFile.writeAsString(const JsonEncoder.withIndent('  ').convert(report));

  final failed = cases
      .where((final row) => (row['verdict'] as String) != 'pass')
      .map((final row) => row['id'])
      .toList();
  if (failed.isNotEmpty) {
    stderr.writeln('acceptance FAILED for: $failed');
    exit(1);
  }
  stdout.writeln('acceptance OK: ${cases.length} cases -> $outPath');
  // Explicit, for the same reason as the comparison path above.
  exit(0);
}

/// The same VM this tool runs under, so the acceptance sweep needs no
/// PATH setup.
String get _dartBin => Platform.resolvedExecutable;

/// Runs child commands with their output redirected to a file.
/// browser-test grandchildren (chromedriver, Chrome) inherit the file
/// descriptor instead of this tool's pipes, so [Process.run] sees EOF
/// when the direct child exits.
final _acceptanceCommands = <Map<String, Object?>>[];

Future<(bool, String)> _runCaptured(final List<String> arguments) async {
  final log = File('build/evidence/b04/child-${DateTime.now().microsecondsSinceEpoch}.log');
  await log.parent.create(recursive: true);
  final process = await Process.start('/bin/sh', [
    '-c',
    '"$_dartBin" ${arguments.map(_shellQuote).join(' ')} > "${log.path}" 2>&1',
  ]);
  // Drain the pipes so no open handle keeps this VM alive after main
  // returns; the child's own output goes to the log file.
  unawaited(process.stdin.close());
  unawaited(process.stdout.drain<void>());
  unawaited(process.stderr.drain<void>());
  final code = await process.exitCode;
  final output = await log.readAsString();
  _acceptanceCommands.add({
    'argv': [_dartBin, ...arguments],
    'exitCode': code,
    'log': log.path,
    'sha256': sha256.convert(utf8.encode(output)).toString(),
  });
  return (code == 0, output);
}

String _shellQuote(final String value) => "'${value.replaceAll("'", "'\\''")}'";

Future<bool> _runDartTest(final List<String> files) async {
  final (ok, _) = await _runCaptured(['test', ...files]);

  return ok;
}

Future<bool> _runChromeWorkerTest() async {
  // Compile the worker, run the browser lane for MOBI sessions, clean
  // the artifacts — the same ritual CI's chrome lane uses.
  final (compileOk, _) = await _runCaptured([
    'compile',
    'js',
    'web/unseal_worker.dart',
    '-o',
    'test/web/unseal_worker.js',
  ]);
  if (!compileOk) return false;
  try {
    final (ok, _) = await _runCaptured([
      'test',
      '-p',
      'chrome',
      'test/web/session_mobi_worker_test.dart',
    ]);

    return ok;
  } finally {
    for (final artifact in [
      'test/web/unseal_worker.js',
      'test/web/unseal_worker.js.deps',
      'test/web/unseal_worker.js.map',
    ]) {
      final file = File(artifact);
      if (file.existsSync()) file.deleteSync();
    }
  }
}
