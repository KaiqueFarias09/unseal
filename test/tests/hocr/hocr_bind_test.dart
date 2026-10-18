import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../../support/hocr_snapshot.dart';

Uint8List _bytes(final String html) => Uint8List.fromList(utf8.encode(html));

String _document(final String body) =>
    '<html><head><meta name="ocr-system" content="bind-test"/></head><body>$body</body></html>';

HocrDocument _parse(final String body) => parseHocrDocument(_bytes(_document(body)));

HocrSnapshotBinding _bind(
  final String body, {
  required final String target,
  final HocrBindLimits limits = const HocrBindLimits(),
}) => bindHocrToSnapshot(document: _parse(body), target: hocrSnapshot(target), limits: limits);

/// A two-page Tesseract-shaped document with boxed words.
String _tesseractBody(final List<List<String>> lines) {
  final buffer = StringBuffer(
    '<div class="ocr_page" id="p1" title="bbox 0 0 200 400">'
    '<div class="ocr_carea" title="bbox 0 0 200 400"><p class="ocr_par" lang="eng">',
  );
  for (final words in lines) {
    buffer.write('<span class="ocr_line" title="bbox 0 0 200 20; baseline 0.01 -1">');
    for (final word in words) {
      buffer.write(
        '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 80">${word.trim()}</span>',
      );
    }
    buffer.write('</span>');
  }
  buffer.write('</p></div></div>');

  return buffer.toString();
}

void main() {
  test('alternative ancestors stay ambiguous and deleted lines are excluded', () {
    final binding = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40">'
      '<div class="alternatives"><ins>'
      '<span class="ocr_line" title="bbox 0 0 100 20">chosen</span></ins>'
      '<del><span class="ocr_line" title="bbox 0 20 100 40">discarded</span></del>'
      '</div></div>',
      target: 'chosen discarded',
    );
    expect(binding.document.pages.single.lines.single.text, 'chosen');
    expect(binding.wordsAmbiguous, 1);
    expect(binding.wordsResolved, 0);
    expect(binding.wordsMissing, 0);
  });

  test('words bind onto exact UTF-16 ranges across astral and diacritics', () {
    final binding = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 90">café</span>'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 80">𝄞 𝕌𝕟𝕚𝕔𝕠𝕕𝕖</span>'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 70">ſäculum</span>'
      '</span></div>',
      target: 'café 𝄞 𝕌𝕟𝕚𝕔𝕠𝕕𝕖 ſäculum fin.',
    );
    expect(binding.wordsResolved, 3);
    expect(binding.wordsAmbiguous, 0);
    expect(binding.wordsMissing, 0);
    final wordZones = binding.pages.single.zones
        .where((final zone) => zone.kind == SpatialZoneKind.word)
        .toList();
    expect(wordZones, hasLength(3));
    final target = binding.target.text;
    expect(target.substring(wordZones[0].textStart, wordZones[0].textEnd), 'café');
    expect(target.substring(wordZones[1].textStart, wordZones[1].textEnd), '𝄞 𝕌𝕟𝕚𝕔𝕠𝕕𝕖');
    expect(wordZones[1].utf16Length, 17);
    expect(target.substring(wordZones[2].textStart, wordZones[2].textEnd), 'ſäculum');
    expect(wordZones.map((final zone) => zone.confidence), <double?>[0.9, 0.8, 0.7]);
  });

  test('indentation inside words is trimmed for binding, model text stays verbatim', () {
    final binding = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 90">\n   padded\t</span>'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 90"> </span>'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 90">non\u00A0breaking</span>'
      '</span></div>',
      target: 'padded non\u00A0breaking',
    );
    final document = _parse(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
      '<span class="ocrx_word" title="bbox 0 0 10 10">\n   padded\t</span></span></div>',
    );
    expect(document.pages.single.words.single.text, '\n   padded\t');
    expect(
      binding.wordsResolved,
      2,
      reason: 'the whitespace-only word binds nothing and counts nothing',
    );
    expect(binding.wordsMissing, 0);
    final zones = binding.pages.single.zones
        .where((final zone) => zone.kind == SpatialZoneKind.word)
        .toList();
    expect(zones, hasLength(2));
    expect(binding.target.text.substring(zones[0].textStart, zones[0].textEnd), 'padded');
    expect(
      binding.target.text.substring(zones[1].textStart, zones[1].textEnd),
      'non\u00A0breaking',
    );
  });

  test('a line without words binds its own text (ocropy shape)', () {
    final binding = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">plain text line</span>'
      '<span class="ocr_line" title="bbox 0 0 100 20">second line</span></div>',
      target: 'plain text line second line',
    );
    expect(binding.wordsResolved, 2);
    final lines = binding.pages.single.zones
        .where((final zone) => zone.kind == SpatialZoneKind.line)
        .toList();
    expect(binding.target.text.substring(lines[0].textStart, lines[0].textEnd), 'plain text line');
  });

  test('repeated content stays ambiguous with a bounded candidate list', () {
    final binding = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 90">echo</span></span></div>',
      target:
          'echo echo echo echo echo echo echo echo echo echo echo echo echo echo echo echo echo echo',
    );
    expect(binding.wordsAmbiguous, 1);
    expect(binding.wordsResolved, 0);
    final unit = binding.ambiguousUnits.single;
    expect(unit.candidates, hasLength(16));
    expect(unit.chosen, (0, 4));
    expect(unit.place.pageIndex, 0);
    expect(unit.place.lineIndex, 0);
    expect(unit.place.wordIndex, 0);
  });

  test('an alternative reading makes the unit ambiguous even with one candidate', () {
    final binding = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 90"><span class="alternatives"><ins>hello</ins><del>hallo</del></span></span>'
      '</span></div>',
      target: 'hello world',
    );
    expect(binding.wordsAmbiguous, 1);
    expect(binding.ambiguousUnits.single.content, 'hello');
    expect(binding.ambiguousUnits.single.candidates, hasLength(1));
  });

  test('a line-level alternative reading propagates to its words', () {
    final binding = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
      '<span class="alternatives"><ins>a</ins><del>b</del></span>'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 90">cat</span></span></div>',
      target: 'a cat',
    );
    expect(binding.wordsAmbiguous, 1);
    expect(binding.wordsResolved, 0);
  });

  test('absence is observable as missing', () {
    final binding = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 90">absent</span></span></div>',
      target: 'nothing here',
    );
    expect(binding.wordsMissing, 1);
    expect(binding.wordsResolved, 0);
    // Missing units emit empty-range zones, the PAGE binding's precedent:
    // the geometry is real, the range selects nothing.
    final zones = binding.pages.single.zones;
    expect(zones.map((final zone) => zone.kind), <SpatialZoneKind>[
      SpatialZoneKind.region,
      SpatialZoneKind.line,
      SpatialZoneKind.word,
    ]);
    expect(zones.every((final zone) => zone.textStart == zone.textEnd), isTrue);
  });

  test('the reading cursor walks pages in document order', () {
    final body =
        '${_tesseractBody([
          <String>['one'],
        ])}<div class="ocr_page" id="p2" title="bbox 0 0 200 400"><span class="ocr_line" title="bbox 0 0 200 20; baseline 0 -1">'
        '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 80">two</span></span></div>';
    final binding = bindHocrToSnapshot(
      document: _parse(body),
      target: hocrSnapshot('one then two then once more'),
    );
    // The cursor walks page 0 then page 1; neither unit is missing, and
    // 'one' occurs once in this target so nothing turns ambiguous.
    expect(binding.wordsResolved, 2);
    expect(binding.wordsAmbiguous, 0);
    expect(binding.wordsMissing, 0);
    expect(binding.pages, hasLength(2));
    expect(binding.pageIndexes, <int>[0, 1]);
    final second = binding.pages[1];
    expect(second.zones.last.kind, SpatialZoneKind.word);
    expect(second.textLength, binding.target.text.length);
  });

  test('a frameless page binds text but emits no spatial page', () {
    final body =
        '<div class="ocr_page" id="p1" title="ppageno 0"></div>'
        '<div class="ocr_page" id="p2" title="ppageno 1"><span class="ocr_line" title="bbox 0 0 10 10">'
        '<span class="ocrx_word" title="bbox 0 0 4 4; x_wconf 80">ghost</span></span></div>';
    final binding = bindHocrToSnapshot(document: _parse(body), target: hocrSnapshot('ghost text'));
    expect(
      binding.pages,
      hasLength(1),
      reason: 'page 0 has no frame, page 1 derives one from its line',
    );
    expect(binding.pageIndexes, <int>[1]);
    expect(binding.wordsResolved, 1);
    final lookup = binding.lookups.single;
    expect(lookup.wordAt(0), isNotNull);
  });

  test('region zones follow the nearest boxed ancestor (Tesseract, ABBYY, ocropy)', () {
    final tesseract = _bind(
      _tesseractBody([
        <String>['alpha', 'beta'],
        <String>['gamma'],
      ]),
      target: 'alpha beta gamma',
    );
    final zones = tesseract.pages.single.zones;
    expect(zones.map((final zone) => zone.kind), <SpatialZoneKind>[
      SpatialZoneKind.region,
      SpatialZoneKind.line,
      SpatialZoneKind.word,
      SpatialZoneKind.word,
      SpatialZoneKind.line,
      SpatialZoneKind.word,
    ]);
    expect(zones.first.textStart, 0);
    expect(zones.first.textEnd, 'alpha beta gamma'.length);

    final abbyy = _bind(
      '<div class="ocr_page" title="bbox 0 0 200 400"><p class="ocr_par" title="bbox 0 0 200 100">'
      '<span class="ocr_line" title="bbox 0 0 200 20"><span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 80">word</span></span>'
      '</p></div>',
      target: 'word',
    );
    expect(abbyy.pages.single.zones.first.kind, SpatialZoneKind.region);

    final ocropy = _bind(
      '<div class="ocr_page" title="bbox 0 0 200 400"><span class="ocr_line" title="bbox 0 0 200 20">word</span></div>',
      target: 'word',
    );
    final ocropyZones = ocropy.pages.single.zones;
    expect(ocropyZones.first.kind, SpatialZoneKind.region);
    expect(ocropyZones, hasLength(2), reason: 'the page frame region and the line');
  });

  test('words without a box bind but emit no zone', () {
    final binding = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
      '<span class="ocrx_word" title="x_wconf 90">boxless</span>'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 90">boxed</span></span></div>',
      target: 'boxless boxed',
    );
    expect(binding.wordsResolved, 2);
    final words = binding.pages.single.zones
        .where((final zone) => zone.kind == SpatialZoneKind.word)
        .toList();
    expect(words, hasLength(1));
    expect(binding.target.text.substring(words.single.textStart, words.single.textEnd), 'boxed');
  });

  test('provenance carries the ocr-system and the confidence presence per page', () {
    final withConfidence = _bind(
      _tesseractBody([
        <String>['word'],
      ]),
      target: 'word',
    );
    expect(withConfidence.pages.single.provenance.softwareName, 'bind-test');
    expect(withConfidence.pages.single.provenance.softwareVersion, isNull);
    expect(withConfidence.pages.single.provenance.hasConfidence, isTrue);
    expect(withConfidence.pages.single.provenance.origin, SpatialTextOrigin.importedOcr);
    expect(withConfidence.pages.single.unit, SpatialUnit.pixel);
    expect(withConfidence.pages.single.rotation, 0);

    final unknownOnly = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf unknown">word</span></span></div>',
      target: 'word',
    );
    expect(unknownOnly.pages.single.provenance.hasConfidence, isFalse);

    final absent = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
      '<span class="ocrx_word" title="bbox 0 0 10 10">word</span></span></div>',
      target: 'word',
    );
    expect(absent.pages.single.provenance.hasConfidence, isFalse);
    expect(
      absent.pages.single.zones
          .firstWhere((final zone) => zone.kind == SpatialZoneKind.word)
          .confidence,
      isNull,
    );
  });

  test('the binding carries the full target identity tuple and reuse verifies it', () {
    final binding = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 90">word</span></span></div>',
      target: 'word',
    );
    expect(binding.targetIdentity, hocrSnapshot('word').identity);
    expect(binding.targetTextRevision, isNotEmpty);
    expect(binding.target.sameIdentity(binding.target), isTrue);
    final changed = hocrSnapshot('word changed');
    expect(binding.target.sameIdentity(changed), isFalse);
    expect(binding.boundText.targetTextRevision, binding.targetTextRevision);
    final view = binding.boundText;
    expect(view.pageIndexes, <int>[0]);
    expect(view.wordsResolved, 1);
  });

  test('budgets: projection work and candidate bounds fail or bind as declared', () {
    expect(
      () => _bind(
        '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
        '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 90">needle</span></span></div>',
        target: 'needle',
        limits: const HocrBindLimits(maxProjectionWork: 2),
      ),
      throwsA(isA<HocrException>()),
    );
    expect(() => HocrBindLimits(maxCandidateOccurrences: 1).requireValid(), throwsArgumentError);
    expect(() => HocrBindLimits(maxProjectionWork: 0).requireValid(), throwsArgumentError);

    final bounded = _bind(
      '<div class="ocr_page" title="bbox 0 0 100 40"><span class="ocr_line" title="bbox 0 0 100 20">'
      '<span class="ocrx_word" title="bbox 0 0 10 10; x_wconf 90">hit</span></span></div>',
      target: 'hit hit',
      limits: const HocrBindLimits(maxCandidateOccurrences: 2),
    );
    expect(bounded.ambiguousUnits.single.candidates, hasLength(2));
  });

  test('lookups answer word/line/region queries over the bound page', () {
    final binding = _bind(
      _tesseractBody([
        <String>['alpha', 'beta'],
        <String>['gamma'],
      ]),
      target: 'alpha beta gamma',
    );
    final lookup = binding.lookups.single;
    expect(lookup.wordAt(6)!.textStart, 6);
    expect(lookup.lineAt(0), isNotNull);
    expect(lookup.regionAt(0), isNotNull);
    expect(lookup.zonesIn(0, 5), hasLength(3));
    final selected = lookup.zonesIn(0, 5);
    expect(lookup.regionsOf(selected), hasLength(1));
    // The spatial page validates the depth-first nesting itself.
    expect(binding.pages.single.zones.first.kind, SpatialZoneKind.region);
  });
}
