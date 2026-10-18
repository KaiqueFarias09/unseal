import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../../support/page_snapshot.dart';

Uint8List _bytes(final String xml) => Uint8List.fromList(utf8.encode(xml));

final Uint8List claurenFixture = File(
  'test/resources/page/clauren-mimil-1815-0023.xml',
).readAsBytesSync();
final Uint8List hilbertFixture = File(
  'test/resources/page/hilbert-zahlkoerper-1897-0370.xml',
).readAsBytesSync();

/// A word-level PAGE document over the target's own first words, with
/// diacritics and an astral-plane word.
const String _pageXml =
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15">'
    '<Metadata><Creator>TestOCR</Creator><Created>2026-01-01T00:00:00</Created>'
    '<LastChange>2026-01-01T00:00:00</LastChange></Metadata>'
    '<Page imageFilename="p.tif" imageWidth="300" imageHeight="100">'
    '<TextRegion id="r1" orientation="0">'
    '<Coords points="10,10 290,10 290,50 10,50"/>'
    '<TextLine id="l1"><Coords points="10,10 290,10 290,25 10,25"/>'
    '<Baseline points="10,24 290,22" conf="0.9"/>'
    '<Word id="w1"><Coords points="10,10 40,25"/>'
    '<TextEquiv conf="0.91"><Unicode>café</Unicode></TextEquiv></Word>'
    '<Word id="w2"><Coords points="45,10 70,25"/>'
    '<TextEquiv conf="0.88"><Unicode>naïve</Unicode></TextEquiv></Word>'
    '<Word id="w3"><Coords points="75,10 105,25"/>'
    '<TextEquiv conf="0.75"><Unicode>𝄞 𝕌𝕟𝕚𝕔𝕠𝕕𝕖</Unicode></TextEquiv></Word>'
    '</TextLine>'
    '<TextLine id="l2"><Coords points="10,30 290,30 290,45 10,45"/>'
    '<Word id="w4"><Coords points="10,30 60,45"/>'
    '<TextEquiv conf="0.8"><Unicode>ſäculum</Unicode></TextEquiv></Word>'
    '</TextLine>'
    '</TextRegion>'
    '</Page></PcGts>';

void main() {
  test('words bind onto exact UTF-16 ranges across astral and diacritics', () {
    const targetText = 'café naïve 𝄞 𝕌𝕟𝕚𝕔𝕠𝕕𝕖 ſäculum fin.';
    final binding = bindPageToSnapshot(
      document: parsePageXmlDocument(_bytes(_pageXml)),
      target: pageSnapshot(targetText),
    );

    expect(binding.wordsResolved, 4);
    expect(binding.wordsAmbiguous, 0);
    expect(binding.wordsMissing, 0);
    final zones = binding.pages.single.zones;
    final words = zones.where((zone) => zone.kind == SpatialZoneKind.word).toList();
    expect(words, hasLength(4));
    for (final zone in words) {
      expect(targetText.substring(zone.textStart, zone.textEnd), isNotEmpty);
    }
    // Exact code-unit comparison: the astral word spans surrogate pairs.
    final astral = words[2];
    expect(targetText.substring(astral.textStart, astral.textEnd), '𝄞 𝕌𝕟𝕚𝕔𝕠𝕕𝕖');
    expect(astral.confidence, 0.75);
    // Confidence presence, per-zone, and page provenance.
    expect(binding.pages.single.provenance.origin, SpatialTextOrigin.importedOcr);
    expect(binding.pages.single.provenance.hasConfidence, isTrue);
    expect(binding.pages.single.provenance.softwareName, 'TestOCR');
  });

  test('lines and regions aggregate their children min/max', () {
    const targetText = 'café naïve 𝄞 𝕌𝕟𝕚𝕔𝕠𝕕𝕖 ſäculum fin.';
    final binding = bindPageToSnapshot(
      document: parsePageXmlDocument(_bytes(_pageXml)),
      target: pageSnapshot(targetText),
    );
    final zones = binding.pages.single.zones;
    final region = zones.firstWhere((zone) => zone.kind == SpatialZoneKind.region);
    final line1 = zones.firstWhere((zone) => zone.kind == SpatialZoneKind.line);
    expect(targetText.substring(line1.textStart, line1.textEnd), 'café naïve 𝄞 𝕌𝕟𝕚𝕔𝕠𝕕𝕖');
    expect(region.textStart, line1.textStart);
    final lastWord = zones.last;
    expect(targetText.substring(lastWord.textStart, lastWord.textEnd), 'ſäculum');
    expect(region.textEnd, lastWord.textEnd);
    // Zone rectangles are the derived bounding boxes of the native
    // polygons.
    final document = parsePageXmlDocument(_bytes(_pageXml));
    final nativeRegion = document.page.regions.single;
    expect(region.rect, nativeRegion.polygon.boundingRect);
    expect(
      zones.firstWhere((zone) => zone.kind == SpatialZoneKind.line).rect,
      nativeRegion.lines.first.polygon.boundingRect,
    );
  });

  test('repeated quotes stay ambiguous with bounded candidates', () {
    const targetText = 'echo alpha echo beta echo';
    final document = parsePageXmlDocument(
      _bytes(_pageXml.replaceFirst('<Unicode>café</Unicode>', '<Unicode>echo</Unicode>')),
    );
    final binding = bindPageToSnapshot(document: document, target: pageSnapshot(targetText));
    expect(binding.wordsAmbiguous, 1);
    final ambiguous = binding.ambiguousWords.single;
    expect(ambiguous.content, 'echo');
    expect(ambiguous.place.regionIndex, 0);
    expect(ambiguous.place.lineIndex, 0);
    expect(ambiguous.place.wordIndex, 0);
    // The default cap records at most 16 candidates; three exist here.
    expect(ambiguous.candidates, hasLength(3));
    // The chosen occurrence follows the reading cursor: the first
    // 'echo' at or after the start.
    expect(ambiguous.chosen.$1, 0);
    expect(targetText.substring(ambiguous.chosen.$1, ambiguous.chosen.$2), 'echo');
  });

  test('the candidate cap stops counting beyond the limit', () {
    const targetText = 'a b a b a b a b a b a b a b a b a b a b';
    final document = parsePageXmlDocument(
      _bytes(_pageXml.replaceFirst('<Unicode>café</Unicode>', '<Unicode>a</Unicode>')),
    );
    final binding = bindPageToSnapshot(
      document: document,
      target: pageSnapshot(targetText),
      limits: const PageXmlBindLimits(maxCandidateOccurrences: 5),
    );
    expect(binding.ambiguousWords.single.candidates, hasLength(5));
  });

  test('missing words are observable, not invented', () {
    final document = parsePageXmlDocument(
      _bytes(_pageXml.replaceFirst('<Unicode>ſäculum</Unicode>', '<Unicode>absent</Unicode>')),
    );
    final binding = bindPageToSnapshot(
      document: document,
      target: pageSnapshot('café naïve 𝄞 𝕌𝕟𝕚𝕔𝕠𝕕𝕖 ſäculum'),
    );
    expect(binding.wordsMissing, 1);
    expect(binding.wordsResolved, 3);
  });

  test('the projection work budget bounds hostile scans typed', () {
    final document = parsePageXmlDocument(_bytes(_pageXml));
    expect(
      () => bindPageToSnapshot(
        document: document,
        target: pageSnapshot('café naïve 𝄞 𝕌𝕟𝕚𝕔𝕠𝕕𝕖 ſäculum'),
        limits: const PageXmlBindLimits(maxProjectionWork: 3),
      ),
      throwsA(isA<PageXmlException>()),
    );
    expect(
      () => bindPageToSnapshot(
        document: document,
        target: pageSnapshot('x'),
        limits: const PageXmlBindLimits(maxCandidateOccurrences: 1),
      ),
      throwsA(isA<ArgumentError>()),
      reason: 'one candidate cannot detect ambiguity',
    );
  });

  test('line-level sidecars bind their line text', () {
    final document = parsePageXmlDocument(claurenFixture);
    final lines = document.page.regions
        .expand((region) => region.lines)
        .where((line) => line.text != null && line.text!.text.isNotEmpty)
        .toList();
    expect(lines, isNotEmpty);
    // The target carries the sidecar's own first line, so the binding
    // resolves it.
    final firstLineText = lines.first.text!.text;
    final binding = bindPageToSnapshot(
      document: document,
      target: pageSnapshot('$firstLineText und mehr'),
    );
    expect(binding.wordsResolved, greaterThanOrEqualTo(1));
    final lineZones = binding.pages.single.zones
        .where((zone) => zone.kind == SpatialZoneKind.line)
        .toList();
    expect(lineZones, isNotEmpty);
    // The first declared line lands on the target's opening range.
    expect(lineZones.first.textStart, 0);
    expect(lineZones.first.textEnd, firstLineText.length);
    expect(
      binding.pages.single.zones.where((zone) => zone.kind == SpatialZoneKind.word),
      isEmpty,
      reason: 'no word zones without word children',
    );
  });

  test('region-level sidecars bind their region text', () {
    // The synthetic region-level shape some producers emit: text only
    // on the TextRegion, no lines.
    const pageXml =
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15">'
        '<Metadata><Creator>T</Creator><Created>2026-01-01T00:00:00</Created>'
        '<LastChange>2026-01-01T00:00:00</LastChange></Metadata>'
        '<Page imageFilename="p.tif" imageWidth="300" imageHeight="100">'
        '<TextRegion id="r1" conf="0.9">'
        '<Coords points="10,10 290,10 290,90 10,90"/>'
        '<TextEquiv index="0" conf="0.82"><Unicode>Erster Absatz mit Worten</Unicode></TextEquiv>'
        '<TextEquiv index="1" conf="0.4"><Unicode>alternative reading</Unicode></TextEquiv>'
        '</TextRegion>'
        '<TextRegion id="r2">'
        '<Coords points="10,95 290,95 290,99 10,99"/>'
        '<TextEquiv><Unicode>zweite Region</Unicode></TextEquiv>'
        '</TextRegion>'
        '</Page></PcGts>';
    final document = parsePageXmlDocument(_bytes(pageXml));
    final binding = bindPageToSnapshot(
      document: document,
      target: pageSnapshot('Erster Absatz mit Worten zweite Region'),
    );
    expect(binding.wordsResolved, 2);
    final zones = binding.pages.single.zones;
    expect(zones.where((zone) => zone.kind == SpatialZoneKind.line), isEmpty);
    final regionZones = zones.where((zone) => zone.kind == SpatialZoneKind.region).toList();
    expect(regionZones, hasLength(2));
    expect(regionZones.first.textStart, 0);
    expect(regionZones.first.textEnd, 'Erster Absatz mit Worten'.length);
    expect(regionZones.first.confidence, 0.82, reason: 'the chosen TextEquiv conf');
    expect(regionZones.last.rect, document.page.regions.last.polygon.boundingRect);
  });

  test('a structure-only page parses and binds to an empty projection', () {
    final document = parsePageXmlDocument(hilbertFixture);
    final binding = bindPageToSnapshot(
      document: document,
      target: pageSnapshot('nothing here matches structure-only pages'),
    );
    expect(binding.wordsResolved, 0);
    expect(binding.wordsAmbiguous, 0);
    expect(binding.wordsMissing, 0);
    expect(binding.pages.single.zones, isEmpty);
    // The native geometry still carries every region polygon.
    expect(document.page.regions.every((region) => region.polygon.points.isNotEmpty), isTrue);
  });

  test('the binding exposes the target identity tuple for reuse checks', () {
    final binding = bindPageToSnapshot(
      document: parsePageXmlDocument(_bytes(_pageXml)),
      target: pageSnapshot('café naïve 𝄞 𝕌𝕟𝕚𝕔𝕠𝕕𝕖 ſäculum'),
    );
    expect(binding.targetIdentity.publicationId, 'test:page-target');
    expect(binding.targetOccurrence.sectionIndex, 0);
    expect(binding.targetProfile.id, isNotEmpty);
    expect(binding.targetTextRevision, startsWith('sha256:'));
    // A snapshot over a different text no longer matches: verified
    // reuse against the changed revision fails.
    final other = pageSnapshot('ganz anderer Text');
    expect(binding.target.sameIdentity(other), isFalse);
    expect(
      binding.target.identity.sameRevision(other.identity),
      isTrue,
      reason: 'identity alone is not the mismatch; the text revision is',
    );
  });

  test('reading order re-sequences zones across columns', () {
    // Two text regions stored right-to-left; the ReadingOrder declares
    // the left column first.
    const pageXml =
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<PcGts xmlns="http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15">'
        '<Metadata><Creator>T</Creator><Created>2026-01-01T00:00:00</Created>'
        '<LastChange>2026-01-01T00:00:00</LastChange></Metadata>'
        '<Page imageFilename="p.tif" imageWidth="300" imageHeight="100">'
        '<ReadingOrder><OrderedGroup id="g">'
        '<RegionRefIndexed index="0" regionRef="leftCol"/>'
        '<RegionRefIndexed index="1" regionRef="rightCol"/>'
        '</OrderedGroup></ReadingOrder>'
        '<TextRegion id="rightCol">'
        '<Coords points="150,10 290,10 290,50 150,50"/>'
        '<TextEquiv><Unicode>right</Unicode></TextEquiv>'
        '</TextRegion>'
        '<TextRegion id="leftCol">'
        '<Coords points="10,10 140,10 140,50 10,50"/>'
        '<TextEquiv><Unicode>left</Unicode></TextEquiv>'
        '</TextRegion>'
        '</Page></PcGts>';
    final binding = bindPageToSnapshot(
      document: parsePageXmlDocument(_bytes(pageXml)),
      target: pageSnapshot('left right'),
    );
    final zones = binding.pages.single.zones;
    // leftCol (region-level text) emits first despite stored order.
    expect(zones.first.kind, SpatialZoneKind.region);
    expect(zones.first.textStart, 0);
    expect(zones.first.textEnd, 4);
    expect(zones.last.textEnd, 10);
  });
}
