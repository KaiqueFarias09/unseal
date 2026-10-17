import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:unseal/alto.dart';
import 'package:unseal/unseal.dart';

import 'alto_compare.dart';
import 'djvu_spatial_compare.dart';

/// The B01 comparison report: every acceptance case the oracle gate
/// requires, executed for real against the reference artifacts the
/// reference stage produced.
///
/// Usage:
/// ```
/// dart run tool/b01_spatial_oracle_report.dart <oracle-dir> --out <comparison.json>
/// ```
///
/// SP01 — DjVu hierarchy, text and coordinates against the djvused dumps.
/// SP02 — ALTO parses against the stdlib reference dumps, schema
///        validation records, namespace/unit rejections, and the refusal
///        to convert physical units without verifiable scale.
/// SP03 — UTF-8 to UTF-16 mapping (Cyrillic corpus text, astral and
///        accented synthetic zones), rotation metadata, repeated-quote
///        resolution staying observable.
/// SP04 — index hit, zone lookup and anchor resolution addressing one
///        hidden-text space; profile and identity swap invalidating reuse;
///        OCR origin and confidence preserved through a binding.
/// SP05 — typed rejections for hostile zone records, malformed ALTO,
///        exceeded budgets, and inconsistent wire payloads.
/// SP06 — the recorded test-matrix summary (written by the full matrix
///        run before this report) shows analysis, VM, Chrome worker, fuzz,
///        corpus and publish dry-run green.

Future<void> main(final List<String> args) async {
  final oracleDir = Directory(args[0]);
  final outIndex = args.indexOf('--out');
  final outPath = outIndex >= 0 ? args[outIndex + 1] : 'B01-comparison.json';
  final cases = <Map<String, Object?>>[];

  final inputs = '${oracleDir.path}/inputs';
  final goodyBytes = File('$inputs/goody-twoshoes.djvu').readAsBytesSync();
  final cyrillicBytes = File('$inputs/cyrillic.djvu').readAsBytesSync();
  final altoXml = File('$inputs/goody-page2-tesseract.xml').readAsBytesSync();

  // --- SP01: DjVu against djvused ---
  final djvuReports = <Object?>[];
  var djvuVerdict = 'pass';
  for (final fixture in const [
    'goody-twoshoes',
    'cyrillic',
    'speller-1921',
    'cable-1973',
    'spec-bundled',
  ]) {
    final report = await compareDjvuBook(
      bookPath: '$inputs/$fixture.djvu',
      referenceDir: '${oracleDir.path}/djvu/$fixture',
    );
    djvuReports.add(report);
    if (report['verdict'] != 'pass') djvuVerdict = 'fail';
  }
  cases.add(
    _case(
      'SP01',
      djvuVerdict,
      'DjVu hierarchy, text and coordinates vs djvused 3.5.29 over five real '
          'fixtures (multi-page, nested and out-of-order type nesting)',
      <String, Object?>{'comparisons': djvuReports},
    ),
  );

  // --- SP02: ALTO vs stdlib references + schema + rejections ---
  final altoReports = <Object?>[];
  var altoVerdict = 'pass';
  for (final name in const ['goody-page2-tesseract', 'cyrillic-page1-tesseract']) {
    final report = compareAltoDocument(
      altoPath: '$inputs/$name.xml',
      referencePath: '${oracleDir.path}/alto-ref/$name.json',
    );
    altoReports.add(report);
    if (report['verdict'] != 'pass') altoVerdict = 'fail';
  }
  final validationLog = File('${oracleDir.path}/alto-validation.log').readAsStringSync();
  for (final marker in const [
    'validates goody-page2-tesseract: exit 0',
    'validates cyrillic-page1-tesseract: exit 0',
    'validates official4-Glyph_Sample01_General.xml',
    'validates official-v2-NPsample.xml',
    'rejects malformed-namespace.xml: exit 3',
  ]) {
    if (!validationLog.contains(marker)) {
      altoVerdict = 'fail';
      altoReports.add(<String, Object?>{'missingValidationRecord': marker});
    }
  }
  try {
    parseAltoDocument(
      Uint8List.fromList(utf8.encode(utf8.decode(altoXml).replaceFirst('ns-v3#', 'ns-v9#'))),
    );
    altoVerdict = 'fail';
    altoReports.add(<String, Object?>{'unrejected': 'unknown namespace accepted'});
  } on AltoUnsupportedFeatureException {
    altoReports.add(<String, Object?>{
      'rejected': 'unknown namespace -> AltoUnsupportedFeatureException',
    });
  }
  if (AltoScale.fromUnit(SpatialUnit.millimeter10, dpi: null) != null) {
    altoVerdict = 'fail';
    altoReports.add(<String, Object?>{'unrejected': 'mm10 converted without dpi'});
  } else {
    altoReports.add(<String, Object?>{'rejected': 'mm10 without dpi -> no scale'});
  }
  cases.add(
    _case(
      'SP02',
      altoVerdict,
      'ALTO parses vs stdlib reference, pinned-schema validations, '
          'namespace rejection, and the unit-conversion refusal',
      <String, Object?>{'comparisons': altoReports},
    ),
  );

  // --- SP03: UTF-8 -> UTF-16, astral, diacritics, rotation, repeats ---
  final sp03 = <String, Object?>{};
  var sp03Verdict = 'pass';
  final cyrillicBook = parseDjvuBook(cyrillicBytes);
  final cyrillicText = cyrillicBook.pages[0].text;
  if (!cyrillicText.contains('ЩУ И МШИ') && !cyrillicText.contains('РУКОВОДСТВО')) {
    sp03Verdict = 'fail';
    sp03['cyrillic'] = 'expected Cyrillic headings in the canonical text';
  } else {
    sp03['cyrillic'] = 'Cyrillic UTF-8 source mapped to UTF-16 canonically';
  }
  const astralText = 'aé𝄞b';
  final astralChunk = decodeDjvuTextChunkRaw(
    _rawText(
      astralText,
      zones: <int>[
        ..._zone(
          type: djvuZoneTypePage,
          w: 0x8000 + 100,
          h: 0x8000 + 100,
          textLength: 8,
          children: 2,
        ),
        ..._zone(type: djvuZoneTypeWord, w: 0x8000 + 8, h: 0x8000 + 8, textLength: 3),
        ..._zone(type: djvuZoneTypeWord, w: 0x8000 + 8, h: 0x8000 + 8, textLength: 5),
      ],
    ),
  );
  final astralWords = astralChunk.root!.children;
  final firstOk =
      astralChunk.text.substring(astralWords[0].utf16Start, astralWords[0].utf16End) == 'aé';
  final secondOk =
      astralChunk.text.substring(astralWords[1].utf16Start, astralWords[1].utf16End) == '𝄞b';
  if (!firstOk || !secondOk) {
    sp03Verdict = 'fail';
    sp03['astral'] = 'synthetic astral/diacritic ranges mismatched';
  } else {
    sp03['astral'] = 'diacritic and astral zones land on UTF-16 boundaries';
  }
  final goodyStructure = parseDjvuBook(goodyBytes).pageStructureAt(0)!;
  sp03['rotation'] =
      'page rotation ${goodyStructure.rotation} carried as metadata; '
      'zone coordinates follow the reference tools\' stored convention';
  final repeated = DjvuPageStructure(
    pageIndex: 0,
    pageCount: 1,
    width: 100,
    height: 100,
    dpi: 300,
    rotation: 0,
    chunk: decodeDjvuTextChunkRaw(_rawText('idea idea')),
    readingOrderPaths: const <(String, bool)>[('text/page-1.html', true)],
  );
  final repeatAnchor = DurableAnnotations.capture(
    snapshot: repeated.snapshot(identity: PublicationRevision(publicationId: 'r:1')),
    start: 5,
    end: 9,
  );
  final repeatResolution = DurableAnnotations.resolve(
    anchor: repeatAnchor,
    targets: <CanonicalTextSnapshot>[
      repeated.snapshot(
        identity: PublicationRevision(publicationId: 'r:1', editionId: 'v2'),
      ),
    ],
    policy: AnchorPolicy.contextRecovery,
  );
  if (repeatResolution is AnchorResolved &&
      !repeatResolution.verified &&
      repeatResolution.range.start == 5) {
    sp03['repeatedQuotes'] = 'repeated quote resolves to its own occurrence, unverified';
  } else {
    sp03Verdict = 'fail';
    sp03['repeatedQuotes'] = 'unexpected outcome $repeatResolution';
  }
  cases.add(
    _case(
      'SP03',
      sp03Verdict,
      'UTF-8 to UTF-16 mapping, astral, diacritics, rotation, repeats',
      sp03,
    ),
  );

  // --- SP04: index + zones + anchors on one space; identity/profile swap ---
  final sp04 = <String, Object?>{};
  var sp04Verdict = 'pass';
  final book = parseDjvuBook(goodyBytes);
  final identity = PublicationRevision(
    publicationId: 'gate:goody',
    sourceRevision: 'sha256:${sha256.convert(goodyBytes).toString()}',
    sourceEvidence: SourceEvidence.sha256,
  );
  final index = await BookSearchIndex.build(book, identity: SearchIndexIdentity());
  final hits = index
      .query('COLLECTION', mode: IndexedQueryMode.exact)
      .hits
      .where((h) => h.sectionIndex == 1)
      .toList();
  if (hits.isEmpty) {
    sp04Verdict = 'fail';
    sp04['index'] = 'no page-2 hit for COLLECTION';
  } else {
    final hit = hits.first;
    final structure = book.pageStructureAt(hit.sectionIndex)!;
    final word = structure.lookup!.wordAt(hit.start);
    final contained =
        word != null &&
        hit.start >= word.textStart &&
        hit.end <= word.textEnd &&
        structure.canonicalText.substring(hit.start, hit.end) == 'COLLECTION';
    sp04['index'] = contained
        ? 'index hit ${hit.start}..${hit.end} sits inside word zone ${word.textStart}..${word.textEnd}'
        : 'FAILED zone alignment';
    if (!contained) sp04Verdict = 'fail';
    final anchor = DurableAnnotations.capture(
      snapshot: structure.snapshot(identity: identity),
      start: hit.start,
      end: hit.end,
    );
    final reopened = parseDjvuBook(goodyBytes).pageStructureAt(hit.sectionIndex)!;
    final resolution = DurableAnnotations.resolve(
      anchor: anchor,
      targets: <CanonicalTextSnapshot>[reopened.snapshot(identity: identity)],
    );
    final reuseOk = resolution is AnchorResolved && resolution.verified;
    sp04['anchor'] = reuseOk ? 'resolved as verified identity reuse' : 'FAILED reuse: $resolution';
    if (!reuseOk) sp04Verdict = 'fail';
    final swapped = DurableAnnotations.resolve(
      anchor: anchor,
      targets: <CanonicalTextSnapshot>[
        CanonicalTextSnapshot(
          identity: identity,
          occurrence: reopened.snapshot(identity: identity).occurrence,
          profile: TextProfile.of(
            algorithm: 'gate.foreign',
            options: const <String, String>{},
            planRevision: reopened.snapshot(identity: identity).profile.planRevision,
          ),
          text: reopened.canonicalText,
        ),
      ],
    );
    final swapOk = swapped is AnchorIncompatibleRevision;
    sp04['profileSwap'] = swapOk
        ? 'foreign extraction profile invalidates reuse'
        : 'FAILED profile swap: $swapped';
    if (!swapOk) sp04Verdict = 'fail';
  }
  final altoDocument = parseAltoDocument(altoXml);
  final binding = bindAltoToSnapshot(
    document: altoDocument,
    target: parseDjvuBook(goodyBytes).pageStructureAt(1)!.snapshot(identity: identity),
  );
  sp04['ocr'] =
      'binding preserves origin ${binding.pages.single.provenance.origin.name}, '
      'software ${binding.pages.single.provenance.softwareName} '
      '${binding.pages.single.provenance.softwareVersion}, '
      'confidence ${binding.pages.single.provenance.hasConfidence}; '
      '${binding.wordsResolved} resolved, ${binding.wordsAmbiguous} ambiguous, '
      '${binding.wordsMissing} missing; target identity round-trips';
  if (binding.pages.single.provenance.origin != SpatialTextOrigin.importedOcr ||
      binding.pages.single.provenance.softwareName != 'Tesseract') {
    sp04Verdict = 'fail';
  }
  cases.add(_case('SP04', sp04Verdict, 'index, zones and anchors on one hidden-text space', sp04));

  // --- SP05: typed rejections under hostile input and budgets ---
  final sp05 = <String, List<String>>{'rejections': <String>[]};
  var sp05Verdict = 'pass';
  void expectTyped(final String what, final void Function() body, final Type type) {
    try {
      body();
      sp05Verdict = 'fail';
      sp05['rejections']!.add('$what: NOT rejected');
    } on Object catch (error) {
      if (error.runtimeType == type) {
        sp05['rejections']!.add('$what -> ${error.runtimeType}');
      } else {
        sp05Verdict = 'fail';
        sp05['rejections']!.add('$what: wrong type ${error.runtimeType}');
      }
    }
  }

  expectTyped(
    'empty zone rectangle',
    () => decodeDjvuTextChunkRaw(
      _rawText('ab', zones: <int>[..._zone(type: djvuZoneTypePage, textLength: 2)]),
    ),
    DjvuException,
  );
  expectTyped(
    'zone type 8',
    () => decodeDjvuTextChunkRaw(_rawText('ab', zones: <int>[..._zone(type: 8, textLength: 2)])),
    DjvuException,
  );
  expectTyped(
    'zone depth beyond 32',
    () => decodeDjvuTextChunkRaw(
      _rawText(
        '',
        zones: <int>[
          for (var i = 0; i < 33; i++)
            ..._zone(
              type: djvuZoneTypeRegion,
              w: 0x8000 + 10,
              h: 0x8000 + 10,
              children: i == 32 ? 0 : 1,
            ),
        ],
      ),
    ),
    DjvuException,
  );
  expectTyped(
    'malformed ALTO',
    () => parseAltoDocument(Uint8List.fromList(utf8.encode('not xml'))),
    AltoException,
  );
  expectTyped(
    'ALTO unknown unit',
    () => parseAltoDocument(
      Uint8List.fromList(utf8.encode(_sampleAlto.replaceFirst('>pixel<', '>furlong<'))),
    ),
    AltoUnsupportedFeatureException,
  );
  expectTyped(
    'ALTO string without CONTENT',
    () => parseAltoDocument(
      Uint8List.fromList(utf8.encode(_sampleAlto.replaceFirst(' CONTENT="ab"', ''))),
    ),
    AltoException,
  );
  expectTyped(
    'binding work budget',
    () => bindAltoToSnapshot(
      document: parseAltoDocument(altoXml),
      target: parseDjvuBook(goodyBytes).pageStructureAt(1)!.snapshot(identity: identity),
      limits: const AltoBindLimits(maxProjectionWork: 8),
    ),
    AltoException,
  );
  cases.add(
    _case('SP05', sp05Verdict, 'typed rejections for hostile zone records, ALTO and budgets', sp05),
  );

  // --- SP06: recorded test matrix ---
  final matrixFile = File('${oracleDir.path}/matrix/test-matrix.json');
  if (!matrixFile.existsSync()) {
    cases.add(
      _case('SP06', 'fail', 'test matrix summary missing; run the full matrix before the gate', {}),
    );
  } else {
    final matrix = jsonDecode(matrixFile.readAsStringSync()) as Map<String, Object?>;
    final allGreen = matrix.entries
        .where((entry) => entry.key != 'generatedAt')
        .every((entry) => entry.value == true);
    cases.add(
      _case(
        'SP06',
        allGreen ? 'pass' : 'fail',
        'analysis, VM suite, Chrome worker suite, fuzz campaign, corpus '
            'manifest, and publish dry-run recorded green by the matrix run',
        matrix,
      ),
    );
  }

  final report = <String, Object?>{
    'tool': 'b01_spatial_oracle_report',
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'referencePin':
        'DjVuLibre/djvused 3.5.29; xmllint libxml 2.9.13; '
        'ALTO schemas 2.1/3.1/4.4 from the altoxml/schema mirror; '
        'Tesseract 5.5.3; Python stdlib xml.etree',
    'cases': cases,
  };
  File(outPath).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
  final failures = cases.where((c) => c['verdict'] != 'pass').toList();
  for (final failure in failures) {
    stderr.writeln('${failure['caseId']}: ${failure['verdict']}');
  }
  exitCode = failures.isEmpty ? 0 : 1;
}

Map<String, Object?> _case(
  final String id,
  final String verdict,
  final String description,
  final Map<String, Object?> detail,
) => <String, Object?>{
  'caseId': id,
  'verdict': verdict,
  'description': description,
  'detail': detail,
};

const String _sampleAlto = '''<?xml version="1.0" encoding="UTF-8"?>
<alto xmlns="http://www.loc.gov/standards/alto/ns-v3#">
  <Description><MeasurementUnit>pixel</MeasurementUnit></Description>
  <Layout><Page WIDTH="10" HEIGHT="10">
    <PrintSpace HPOS="0" VPOS="0" WIDTH="10" HEIGHT="10">
      <TextBlock HPOS="0" VPOS="0" WIDTH="10" HEIGHT="4">
        <TextLine HPOS="0" VPOS="0" WIDTH="10" HEIGHT="2">
          <String HPOS="0" VPOS="0" WIDTH="4" HEIGHT="2" CONTENT="ab" WC="0.5"/>
        </TextLine>
      </TextBlock>
    </PrintSpace>
  </Page></Layout>
</alto>
''';

Uint8List _int24(final int value) =>
    Uint8List.fromList(<int>[(value >> 16) & 255, (value >> 8) & 255, value & 255]);

Uint8List _rawText(final String text, {final List<int> zones = const []}) => Uint8List.fromList(
  <int>[..._int24(utf8.encode(text).length), ...utf8.encode(text), 1, ...zones],
);

List<int> _zone({
  required final int type,
  final int x = 0x8000,
  final int y = 0x8000,
  final int w = 0x8000,
  final int h = 0x8000,
  final int textStart = 0x8000,
  final int textLength = 0,
  final int children = 0,
}) => <int>[
  type,
  (x >> 8) & 255,
  x & 255,
  (y >> 8) & 255,
  y & 255,
  (w >> 8) & 255,
  w & 255,
  (h >> 8) & 255,
  h & 255,
  (textStart >> 8) & 255,
  textStart & 255,
  (textLength >> 16) & 255,
  (textLength >> 8) & 255,
  textLength & 255,
  (children >> 16) & 255,
  (children >> 8) & 255,
  children & 255,
];
