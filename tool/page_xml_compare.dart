/// C02 comparator: diffs the Dart PAGE parser against the independent
/// lxml extractor's records over the same real corpus, and pins the
/// negative verdicts.
///
/// Usage:
///
/// ```
/// dart run tool/page_xml_compare.dart \
///   --reference build/c02/outputs/reference.json \
///   --out build/c02/outputs/comparison-diff.json
/// ```
///
/// Exit codes: 0 every document matches and every negative rejects
/// typed; 1 any difference or unexpected acceptance.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:unseal/unseal.dart';

Future<void> main(final List<String> arguments) async {
  var referencePath = 'build/c02/outputs/reference.json';
  var outPath = 'build/c02/outputs/comparison-diff.json';
  var inputs = 'build/c02';
  for (var i = 0; i < arguments.length - 1; i++) {
    if (arguments[i] == '--reference') referencePath = arguments[i + 1];
    if (arguments[i] == '--out') outPath = arguments[i + 1];
    if (arguments[i] == '--inputs') inputs = arguments[i + 1];
  }
  final reference = jsonDecode(File(referencePath).readAsStringSync()) as Map<String, Object?>;
  final documents = reference['documents']! as Map<String, Object?>;
  final negativesDir = Directory('$inputs/negatives');

  final compared = <Map<String, Object?>>[];
  var failures = 0;
  var totalFields = 0;
  if (documents.isEmpty) throw StateError('Reference contains no documents');

  for (final entry in documents.entries) {
    final name = entry.key;
    final expected = entry.value as Map<String, Object?>;
    final file = File('$inputs/corpus/$name');
    final Uint8List bytes;
    if (file.existsSync()) {
      bytes = file.readAsBytesSync();
    } else {
      bytes = File('$inputs/negatives/$name').readAsBytesSync();
    }
    final differences = <String>[];
    final inputHashes = reference['inputs']! as Map<String, Object?>;
    if (sha256.convert(bytes).toString() != inputHashes[name]) {
      throw StateError('Reference/input digest differs for $name');
    }
    var documentFields = 0;
    final PageXmlDocument document;
    try {
      document = parsePageXmlDocument(bytes);
    } on PageXmlUnsupportedFeatureException catch (error) {
      // Declared negatives reject typed; their rejection is the
      // expected outcome, never a failure of the comparison.
      compared.add({
        'file': name,
        'status': name.startsWith('negative-') ? 'rejected-unsupported' : 'parse-rejected',
        'error': error.message,
      });
      if (!name.startsWith('negative-')) failures++;
      continue;
    } on PageXmlException catch (error) {
      compared.add({
        'file': name,
        'status': name.startsWith('negative-') ? 'rejected-typed' : 'parse-rejected',
        'error': error.message,
      });
      if (!name.startsWith('negative-')) failures++;
      continue;
    }
    _diffDocument(document, expected, differences, () => documentFields++);
    totalFields += documentFields;
    compared.add({
      'file': name,
      'status': differences.isEmpty ? 'match' : 'diff',
      'fields': documentFields,
      'differences': differences,
    });
    if (differences.isNotEmpty) failures++;
  }

  final negatives = <Map<String, Object?>>[];
  // Descriptive enumeration tokens (TextRegion/@type and friends)
  // travel verbatim as declared data; the XSD lane owns their
  // vocabulary. This XSD-invalid negative is therefore a declared
  // Dart acceptance, not a parser defect.
  const declaredAcceptances = <String>{'negative-bad-text-type.xml'};
  for (final entity in negativesDir.listSync().whereType<File>()) {
    if (!entity.path.endsWith('.xml')) continue;
    final name = entity.uri.pathSegments.last;
    final role = documents.containsKey(name)
        ? 'schema-valid (positive or declared parser-negative)'
        : 'schema-invalid';
    try {
      parsePageXmlDocument(entity.readAsBytesSync());
    } on PageXmlUnsupportedFeatureException catch (error) {
      negatives.add({
        'file': name,
        'verdict': 'unsupported',
        'message': error.message,
        'role': role,
      });
      continue;
    } on PageXmlException catch (error) {
      negatives.add({
        'file': name,
        'verdict': 'rejected-typed',
        'message': error.message,
        'role': role,
      });
      continue;
    }
    final declared = name.startsWith('positive-') || declaredAcceptances.contains(name);
    negatives.add({
      'file': name,
      'verdict': declared ? 'accepted-as-declared-data' : 'accepted',
      'role': role,
    });
    if (!declared) failures++;
  }

  final head = Process.runSync('git', const ['rev-parse', 'HEAD']).stdout.toString().trim();
  final report = {
    'head': head,
    'reference': referencePath,
    'referenceSha256': _sha256(File(referencePath)),
    'documentsCompared': compared.length,
    'fieldsCompared': totalFields,
    'negativesChecked': negatives.length,
    'failures': failures,
    'compared': compared,
    'negatives': negatives,
  };
  File(outPath).writeAsStringSync('${const JsonEncoder.withIndent(' ').convert(report)}\n');
  stdout.writeln(
    'compare: $failures failures over ${compared.length} documents, '
    '${negatives.length} negatives, $totalFields fields',
  );
  if (failures > 0) exit(1);
}

/// Whether [actual] matches a reference value the lxml extractor kept
/// as text: numeric attributes compare numerically ("300" == 300.0),
/// everything else as strings.
bool _matchesScalar(final Object? actual, final String text) {
  final numeric = num.tryParse(text);
  if (numeric != null && actual is num) {
    return actual.toDouble() == numeric.toDouble();
  }

  return actual?.toString() == text;
}

void _diffDocument(
  final PageXmlDocument document,
  final Map<String, Object?> expected,
  final List<String> into,
  final void Function() count,
) {
  void check(final String what, final Object? actual, final Object? expectedValue) {
    count();
    final matches = switch (expectedValue) {
      null => actual == null,
      final String text => _matchesScalar(actual, text),
      final num number => actual is num && actual.toDouble() == number.toDouble(),
      final bool flag => actual == flag,
      _ => actual.toString() == expectedValue.toString(),
    };
    if (!matches) into.add('$what: dart=${actual ?? 'null'} reference=$expectedValue');
  }

  check('pcGtsId', document.pcGtsId, expected['pcGtsId']);
  final metadata = expected['metadata']! as Map<String, Object?>;
  check('metadata.creator', document.creator, metadata['creator']);
  check('metadata.created', document.created, metadata['created']);
  check('metadata.lastChange', document.lastChange, metadata['lastChange']);
  check('metadata.comments', document.comments, metadata['comments']);

  final page = expected['page']! as Map<String, Object?>;
  check('page.imageFilename', document.page.imageFilename, page['imageFilename']);
  check('page.imageWidth', document.page.width, page['imageWidth']);
  check('page.imageHeight', document.page.height, page['imageHeight']);
  check('page.imageXResolution', document.page.xResolution, page['imageXResolution']);
  check('page.imageYResolution', document.page.yResolution, page['imageYResolution']);
  check('page.imageResolutionUnit', document.page.resolutionUnit, page['imageResolutionUnit']);
  check('page.orientation', document.page.orientation, page['orientation']);
  check('page.type', document.page.type, page['type']);
  check('page.primaryLanguage', document.page.primaryLanguage, page['primaryLanguage']);
  check('page.conf', document.page.confidence, page['conf']);
  _diffPolygon(
    document.page.border,
    page['border'] as Map<String, Object?>?,
    'page.border',
    into,
    count,
  );
  _diffPolygon(
    document.page.printSpace,
    page['printSpace'] as Map<String, Object?>?,
    'page.printSpace',
    into,
    count,
  );

  final expectedRegions = (expected['regions']! as List<Object?>).cast<Map<String, Object?>>();
  if (expectedRegions.length != document.page.regions.length) {
    into.add(
      'regions.count: dart=${document.page.regions.length} reference=${expectedRegions.length}',
    );
  }
  for (var i = 0; i < expectedRegions.length && i < document.page.regions.length; i++) {
    _diffRegion(document.page.regions[i], expectedRegions[i], 'regions[$i]', into, count);
  }

  final expectedOrder = expected['readingOrder'];
  if (expectedOrder == null) {
    check('readingOrder', document.page.readingOrder, null);
  } else {
    final entries = (expectedOrder as List<Object?>).cast<Map<String, Object?>>();
    final actualEntries = <String>[];
    void walk(final PageXmlGroup group) {
      actualEntries.add(group.id);
      for (final item in group.items) {
        if (item is PageXmlRegionRef) {
          actualEntries.add(item.regionRef);
        } else if (item is PageXmlGroup) {
          walk(item);
        }
      }
    }

    walk(document.page.readingOrder!.root);
    final flat = <String>[
      for (final entry in entries)
        entry['regionRef'] as String? ?? entry['id'] as String? ?? '(group)',
    ];
    count();
    if (flat.length != actualEntries.length) {
      into.add('readingOrder.length: dart=${actualEntries.length} reference=${flat.length}');
    } else {
      for (var i = 0; i < flat.length; i++) {
        if (flat[i] != actualEntries[i]) {
          into.add('readingOrder[$i]: dart=${actualEntries[i]} reference=${flat[i]}');
        }
      }
    }
  }
}

void _diffRegion(
  final PageXmlRegion region,
  final Map<String, Object?> expected,
  final String prefix,
  final List<String> into,
  final void Function() count,
) {
  void check(final String what, final Object? actual, final Object? expectedValue) {
    count();
    final matches = switch (expectedValue) {
      null => actual == null,
      final String text => _matchesScalar(actual, text),
      final num number => actual is num && actual.toDouble() == number.toDouble(),
      final bool flag => actual == flag,
      _ => actual.toString() == expectedValue.toString(),
    };
    if (!matches) into.add('$prefix.$what: dart=${actual ?? 'null'} reference=$expectedValue');
  }

  check('kind', region.kind.elementName, expected['kind']);
  check('id', region.id, expected['id']);
  check('continuation', region.continuation, expected['continuation']);
  check('custom', region.custom, expected['custom']);
  check('orientation', region.orientation, expected['orientation']);
  check('readingOrientation', region.readingOrientation, expected['readingOrientation']);
  check('type', region.textType, expected['type']);
  check('primaryLanguage', region.primaryLanguage, expected['primaryLanguage']);
  check('secondaryLanguage', region.secondaryLanguage, expected['secondaryLanguage']);
  check('readingDirection', region.readingDirection, expected['readingDirection']);
  check('textLineOrder', region.textLineOrder, expected['textLineOrder']);
  _diffPolygon(
    region.polygon,
    expected['polygon'] as Map<String, Object?>?,
    '$prefix.polygon',
    into,
    count,
  );
  _diffText(
    region.text,
    expected['textEquiv'] as Map<String, Object?>?,
    '$prefix.textEquiv',
    into,
    count,
  );

  final expectedLines = (expected['lines'] as List<Object?>? ?? const <Object?>[])
      .cast<Map<String, Object?>>();
  if (expectedLines.length != region.lines.length) {
    into.add('$prefix.lines.count: dart=${region.lines.length} reference=${expectedLines.length}');
  }
  for (var i = 0; i < expectedLines.length && i < region.lines.length; i++) {
    final line = region.lines[i];
    final expectedLine = expectedLines[i];
    check('lines[$i].id', line.id, expectedLine['id']);
    check('lines[$i].primaryLanguage', line.primaryLanguage, expectedLine['primaryLanguage']);
    check('lines[$i].readingDirection', line.readingDirection, expectedLine['readingDirection']);
    check('lines[$i].index', line.index?.toString(), expectedLine['index']);
    _diffPolygon(
      line.polygon,
      expectedLine['polygon'] as Map<String, Object?>?,
      '$prefix.lines[$i].polygon',
      into,
      count,
    );
    final expectedBaseline = expectedLine['baseline'] as Map<String, Object?>?;
    final baseline = line.baseline;
    if (expectedBaseline == null) {
      check('lines[$i].baseline', baseline, null);
    } else {
      count();
      if (baseline == null) {
        into.add('$prefix.lines[$i].baseline: dart=null reference=present');
      } else {
        _diffPoints(
          baseline.points,
          (expectedBaseline['points'] as List<Object?>).cast<List<Object?>>(),
          '$prefix.lines[$i].baseline.points',
          into,
          count,
        );
        check('lines[$i].baseline.conf', baseline.confidence, expectedBaseline['conf']);
      }
    }
    _diffText(
      line.text,
      expectedLine['textEquiv'] as Map<String, Object?>?,
      '$prefix.lines[$i].textEquiv',
      into,
      count,
    );
    final expectedWords = (expectedLine['words'] as List<Object?>? ?? const <Object?>[])
        .cast<Map<String, Object?>>();
    if (expectedWords.length != line.words.length) {
      into.add(
        '$prefix.lines[$i].words.count: dart=${line.words.length} reference=${expectedWords.length}',
      );
    }
    for (var w = 0; w < expectedWords.length && w < line.words.length; w++) {
      final word = line.words[w];
      final expectedWord = expectedWords[w];
      check('words[$w].id', word.id, expectedWord['id']);
      check('words[$w].language', word.language, expectedWord['language']);
      check('words[$w].readingDirection', word.readingDirection, expectedWord['readingDirection']);
      _diffPolygon(
        word.polygon,
        expectedWord['polygon'] as Map<String, Object?>?,
        '$prefix.lines[$i].words[$w].polygon',
        into,
        count,
      );
      _diffText(
        word.text,
        expectedWord['textEquiv'] as Map<String, Object?>?,
        '$prefix.lines[$i].words[$w].textEquiv',
        into,
        count,
      );
    }
  }
}

void _diffText(
  final PageXmlTextContent? actual,
  final Map<String, Object?>? expected,
  final String prefix,
  final List<String> into,
  final void Function() count,
) {
  count();
  if (expected == null) {
    if (actual != null) into.add('$prefix: dart=content reference=null');
    return;
  }
  if (actual == null) {
    into.add('$prefix: dart=null reference=${expected['chosen']}');
    return;
  }
  if (actual.text != expected['chosen']) {
    into.add('$prefix.chosen: dart=${actual.text} reference=${expected['chosen']}');
  }
  final expectedAlternatives = (expected['alternatives']! as List<Object?>)
      .cast<Map<String, Object?>>();
  if (expectedAlternatives.length != actual.alternatives.length) {
    into.add(
      '$prefix.alternatives.count: dart=${actual.alternatives.length} reference=${expectedAlternatives.length}',
    );
  }
  for (var i = 0; i < expectedAlternatives.length && i < actual.alternatives.length; i++) {
    final alternative = actual.alternatives[i];
    final expectedAlternative = expectedAlternatives[i];
    if (alternative.unicode != expectedAlternative['unicode']) {
      into.add('$prefix.alternatives[$i].unicode differs');
    }
    if (alternative.index?.toString() != expectedAlternative['index']?.toString()) {
      into.add('$prefix.alternatives[$i].index differs');
    }
    final conf = alternative.confidence;
    final expectedConf = expectedAlternative['conf'];
    if (expectedConf == null) {
      if (conf != null) into.add('$prefix.alternatives[$i].conf: dart=$conf reference=null');
    } else if (!_matchesScalar(conf, expectedConf as String)) {
      into.add('$prefix.alternatives[$i].conf: dart=$conf reference=$expectedConf');
    }
    count();
  }
}

void _diffPolygon(
  final PageXmlPolygon? actual,
  final Map<String, Object?>? expected,
  final String prefix,
  final List<String> into,
  final void Function() count,
) {
  count();
  if (expected == null) {
    if (actual != null) into.add('$prefix: dart=polygon reference=null');
    return;
  }
  if (actual == null) {
    into.add('$prefix: dart=null reference=present');
    return;
  }
  _diffPoints(
    actual.points,
    (expected['points'] as List<Object?>).cast<List<Object?>>(),
    '$prefix.points',
    into,
    count,
  );
  if (actual.confidence?.toString() != expected['conf']?.toString()) {
    into.add('$prefix.conf: dart=${actual.confidence} reference=${expected['conf']}');
  }
}

void _diffPoints(
  final List<(int, int)> actual,
  final List<List<Object?>> expected,
  final String prefix,
  final List<String> into,
  final void Function() count,
) {
  count();
  if (actual.length != expected.length) {
    into.add('$prefix.count: dart=${actual.length} reference=${expected.length}');
    return;
  }
  for (var i = 0; i < actual.length; i++) {
    if (actual[i].$1 != expected[i][0] || actual[i].$2 != expected[i][1]) {
      into.add('$prefix[$i]: dart=${actual[i]} reference=${expected[i]}');
      return;
    }
  }
}

String _sha256(final File file) => sha256.convert(file.readAsBytesSync()).toString();
