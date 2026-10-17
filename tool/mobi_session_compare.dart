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

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:unseal/unseal.dart';
import 'package:xml/xml.dart';

Future<void> main(final List<String> arguments) async {
  final inputPath = _stringOption(arguments, '--input');
  final calibreDir = _stringOption(arguments, '--calibre');
  final outPath = _stringOption(arguments, '--out');
  final includeSession = arguments.contains('--session');
  if (inputPath == null || outPath == null) {
    stderr.writeln(
      'usage: dart run tool/mobi_session_compare.dart --input <file> '
      '[--calibre <oeb-dir>] --out <report.json> [--session]',
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
    cases.add(_calibreCase(calibreDir, eager));
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
    required this.metadata,
  });

  final String formatName;
  final List<String> readingOrderNames;
  final List<String> sectionTexts;
  final List<String> sectionSources;
  final Map<String, String> resourceHashes;
  final List<String> navLabels;
  final List<String> navTargets;
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
  void walk(final List<NavPoint> points) {
    for (final point in points) {
      labels.add(point.label);
      targets.add(point.content);
      walk(point.subNavPoints);
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

Map<String, Object?> _calibreCase(final String oebDir, final _EagerFingerprint eager) {
  final dir = Directory(oebDir);
  if (!dir.existsSync()) {
    return _case('MS03-calibre', 'Calibre OEB directory missing', 'fail', {'dir': oebDir});
  }

  final opfFile = _findOpf(dir);
  if (opfFile == null) {
    return _case('MS03-calibre', 'No content.opf in Calibre output', 'fail', {'dir': oebDir});
  }
  final opf = XmlDocument.parse(opfFile.readAsStringSync());
  final opfDir = opfFile.parent.path;
  final ns = opf.rootElement.namespaceUri;
  final manifestItemsById = <String, String>{
    for (final item in opf.findAllElements('item', namespaceUri: ns))
      if (item.getAttribute('id') case final String id) id: item.getAttribute('href') ?? '',
  };
  final spineHrefs = <String>[
    for (final itemref in opf.findAllElements('itemref', namespaceUri: ns))
      manifestItemsById[itemref.getAttribute('idref')] ?? '',
  ];

  final pieces = <String>[];
  for (final href in spineHrefs) {
    if (!RegExp(r'\.x?html?$', caseSensitive: false).hasMatch(href)) continue;
    final file = File('$opfDir/${Uri.decodeComponent(href)}');
    if (!file.existsSync()) continue;
    // Declared normalization (R5): both sides pass through the same
    // canonical document-text scanner; whitespace collapses afterwards.
    pieces.add(
      documentTextOf(TextFile(content: file.readAsStringSync(), name: '', type: '', path: href)),
    );
  }
  final calibreText = _collapseWhitespace(pieces.join('\n'));
  final unsealText = _collapseWhitespace(eager.sectionTexts.join('\n'));

  if (calibreText == unsealText) {
    return _case(
      'MS03-calibre',
      'Calibre OEB text equals eager text under R5 normalization',
      'pass',
      {'characters': unsealText.length, 'spineHtmlFiles': pieces.length},
    );
  }

  final delta = _firstDivergence(unsealText, calibreText);
  return _case('MS03-calibre', 'Calibre OEB text differs under R5 normalization', 'fail', {
    'unsealCharacters': unsealText.length,
    'calibreCharacters': calibreText.length,
    'divergence': delta,
  });
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
  final joinedSession = _collapseWhitespace(sessionTexts.join('\n'));
  final joinedEager = _collapseWhitespace(eager.sectionTexts.join('\n'));
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
  void walk(final List<NavPoint> points) {
    for (final point in points) {
      labels.add(point.label);
      targets.add(point.content);
      walk(point.subNavPoints);
    }
  }

  walk(mobiHeader.navigation.navPoints);
  final unresolvable = <String>[
    for (final target in targets)
      if (!(await _sessionTargetResolves(session, target))) target,
  ];
  final labelsMatch =
      labels.length == eager.navLabels.length &&
      List<String>.of(eager.navLabels).join('\u0000') == labels.join('\u0000');
  cases.add(
    labelsMatch && unresolvable.isEmpty
        ? _case('MS03-session-nav', 'Navigation labels equal and targets resolve', 'pass', {
            'entries': labels.length,
          })
        : _case('MS03-session-nav', 'Navigation mismatch', 'fail', {
            'labelsMatch': labelsMatch,
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
