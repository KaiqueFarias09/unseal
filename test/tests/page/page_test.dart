import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

Uint8List _bytes(final String xml) => Uint8List.fromList(utf8.encode(xml));

final Uint8List kantFixture = File(
  'test/resources/page/kant-aufklaerung-1784-0017.xml',
).readAsBytesSync();
final Uint8List claurenFixture = File(
  'test/resources/page/clauren-mimil-1815-0023.xml',
).readAsBytesSync();
final Uint8List hilbertFixture = File(
  'test/resources/page/hilbert-zahlkoerper-1897-0370.xml',
).readAsBytesSync();
final Uint8List derivedFixture = File(
  'test/resources/page/kant-0017-derived-alternatives.xml',
).readAsBytesSync();

const String _v2019 = 'http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15';

/// A minimal schema-shaped document the negative tests mutate.
String _doc({
  String namespace = _v2019,
  String pageAttributes = 'imageFilename="page.tif" imageWidth="200" imageHeight="100"',
  String metadata =
      '<Creator>Test</Creator><Created>2026-01-01T00:00:00</Created>'
      '<LastChange>2026-01-02T00:00:00</LastChange>',
  String body = '',
}) =>
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<PcGts xmlns="$namespace" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
    '<Metadata>$metadata</Metadata>'
    '<Page $pageAttributes>$body</Page>'
    '</PcGts>';

String _textRegion({
  String id = 'r1',
  String attributes = '',
  String coords = '10,20 110,20 110,60 10,60',
  String lines = '',
  String textEquiv = '',
}) =>
    '<TextRegion id="$id" $attributes>'
    '<Coords points="$coords"/>'
    '$textEquiv$lines'
    '</TextRegion>';

String _word({String id = 'w1', String content = 'word', String coords = '10,20 40,30'}) =>
    '<Word id="$id">'
    '<Coords points="$coords"/>'
    '<TextEquiv><Unicode>$content</Unicode></TextEquiv>'
    '</Word>';

void main() {
  test('parses the real Kant GT page with full granularity', () {
    final document = parsePageXmlDocument(kantFixture);

    expect(document.creator, 'OCR-D');
    expect(document.created, isNotNull);
    expect(document.page.imageFilename, contains('0017'));
    expect(document.page.width, 1457);
    expect(document.page.height, 2083);
    // Region kinds beyond text survive as geometry.
    final kinds = document.page.regions.map((region) => region.kind).toSet();
    expect(kinds, contains(PageXmlRegionKind.text));
    expect(kinds, contains(PageXmlRegionKind.separator));
    expect(kinds.length, greaterThan(1));
    // Heading region with language pair, lines, words, baseline.
    final heading = document.page.regions.firstWhere((region) => region.id == 'r_1_1');
    expect(heading.textType, 'heading');
    expect(heading.primaryLanguage, 'German');
    expect(heading.secondaryLanguage, 'Latin');
    expect(heading.lines, isNotEmpty);
    final line = heading.lines.first;
    expect(line.primaryLanguage, 'German');
    expect(line.baseline, isNotNull, reason: 'the corpus declares baselines');
    expect(line.baseline!.points.length, greaterThanOrEqualTo(2));
    expect(line.words, isNotEmpty);
    final word = line.words.first;
    expect(word.language, 'German');
    expect(word.text, isNotNull);
    expect(word.text!.text, isNotEmpty);
    // Native polygons keep the stored integer points; the bounding box
    // is the derived projection.
    expect(line.polygon.points, isNotEmpty);
    final (x, y, width, height) = line.polygon.boundingBox;
    final xs = line.polygon.points.map((point) => point.$1);
    final ys = line.polygon.points.map((point) => point.$2);
    expect(x, xs.reduce(math.min));
    expect(y, ys.reduce(math.min));
    expect(width, xs.reduce(math.max) - xs.reduce(math.min));
    expect(height, ys.reduce(math.max) - ys.reduce(math.min));
  });

  test('parses reading order with indexed refs and deterministic order', () {
    final document = parsePageXmlDocument(kantFixture);
    final order = document.page.readingOrder;
    expect(order, isNotNull);
    final refs = order!.regionRefs();
    expect(refs.first, 'r_1_1');
    // Every text region is referenced exactly once (validated at parse).
    final textIds = document.page.regions
        .where((region) => region.kind == PageXmlRegionKind.text)
        .map((region) => region.id)
        .toSet();
    expect(refs.toSet(), textIds);
    // Reading order re-sequences the stored regions.
    expect(document.page.regionsInReadingOrder().map((region) => region.id), refs);
  });

  test('clauren GT keeps line-level text without words', () {
    final document = parsePageXmlDocument(claurenFixture);
    final textRegions = document.page.regions
        .where((region) => region.kind == PageXmlRegionKind.text)
        .toList();
    final lines = textRegions.expand((region) => region.lines).toList();
    expect(lines, isNotEmpty);
    for (final line in lines) {
      expect(line.words, isEmpty, reason: 'the 1815 GT declares no Word children');
      expect(line.text, isNotNull);
      expect(line.text!.text, isNotEmpty);
    }
  });

  test('every region kind parses as geometry, text regions in depth', () {
    final body = <String>[
      for (final kind in PageXmlRegionKind.values)
        kind == PageXmlRegionKind.text
            ? _textRegion(
                id: 'kind-${kind.name}',
                textEquiv: '<TextEquiv><Unicode>t</Unicode></TextEquiv>',
              )
            : '<${kind.elementName} id="kind-${kind.name}">'
                  '<Coords points="0,0 5,5"/>'
                  '</${kind.elementName}>',
    ].join();
    final document = parsePageXmlDocument(_bytes(_doc(body: body)));
    expect(document.page.regions, hasLength(PageXmlRegionKind.values.length));
    expect(
      document.page.regions.map((region) => region.kind).toSet(),
      PageXmlRegionKind.values.toSet(),
    );
    // Only the text region carries lines/text; the rest stay geometry.
    for (final region in document.page.regions) {
      if (region.kind == PageXmlRegionKind.text) continue;
      expect(region.lines, isEmpty);
      expect(region.text, isNull);
    }
  });

  test('hilbert GT is a structure-only page: TextEquivs present but empty', () {
    final document = parsePageXmlDocument(hilbertFixture);
    final textRegions = document.page.regions
        .where((region) => region.kind == PageXmlRegionKind.text)
        .toList();
    expect(textRegions, isNotEmpty);
    for (final region in textRegions) {
      expect(region.lines, isEmpty, reason: 'the 1897 GT declares no TextLine children');
      expect(region.text, isNotNull, reason: 'every region carries a TextEquiv element');
      expect(region.text!.text, isEmpty, reason: 'structure-only GT carries empty Unicode');
    }
  });

  test('derived sample carries alternatives, confidence, orientation', () {
    final document = parsePageXmlDocument(derivedFixture);
    final region = document.page.regions
        .where((region) => region.kind == PageXmlRegionKind.text)
        .first;
    expect(region.orientation, 90.0);
    expect(region.text, isNotNull);
    final content = region.text!;
    expect(content.alternatives.length, 2);
    // The declared policy: the lowest index wins; index 0 carries the
    // astral/diacritic alternative.
    expect(content.chosen.index, 0);
    expect(content.text, startsWith('πάθει μῆκος ὀφείλεται'));
    expect(content.text, contains('𝕌𝕟𝕚𝕔𝕠𝕕𝕖'));
    expect(content.text, contains('ſæculum'));
    expect(content.confidence, 0.977);
    // Page-level figures: orientation 180 projects as rotation 180.
    expect(document.page.orientation, 180.0);
    expect(document.page.confidence, 0.995);
    expect(document.page.rotation, 180);
    expect(document.page.xResolution, 300);
    expect(document.page.resolutionUnit, 'PPI');
  });

  test('fractional page orientation never invents a rotation', () {
    final payload = _doc(
      pageAttributes: 'imageFilename="p.tif" imageWidth="10" imageHeight="10" orientation="2.5"',
      body: _textRegion(textEquiv: '<TextEquiv><Unicode>x</Unicode></TextEquiv>'),
    );
    final document = parsePageXmlDocument(_bytes(payload));
    expect(document.page.orientation, 2.5);
    expect(document.page.rotation, 0);
  });

  test('a ReadingOrder-less page reads regions in stored order', () {
    final payload = _doc(
      body:
          _textRegion(id: 'b', textEquiv: '<TextEquiv><Unicode>b</Unicode></TextEquiv>') +
          _textRegion(id: 'a', textEquiv: '<TextEquiv><Unicode>a</Unicode></TextEquiv>'),
    );
    final document = parsePageXmlDocument(_bytes(payload));
    expect(document.page.readingOrder, isNull);
    expect(document.page.regionsInReadingOrder().map((region) => region.id).toList(), ['b', 'a']);
  });

  test('other PAGE versions and namespaces fail typed', () {
    for (final namespace in [
      'http://schema.primaresearch.org/PAGE/gts/pagecontent/2013-07-15',
      'http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-03-15',
      'http://schema.primaresearch.org/PAGE/gts/pagecontent/2020-01-16',
      'http://www.loc.gov/standards/alto/ns-v3#',
    ]) {
      expect(
        () => parsePageXmlDocument(_bytes(_doc(namespace: namespace))),
        throwsA(isA<PageXmlUnsupportedFeatureException>()),
        reason: namespace,
      );
    }
  });

  test('schema-required metadata and page fields fail typed when absent', () {
    expect(
      () => parsePageXmlDocument(_bytes(_doc(metadata: ''))),
      throwsA(isA<PageXmlException>()),
    );
    expect(
      () => parsePageXmlDocument(_bytes(_doc(metadata: '<Creator>x</Creator>'))),
      throwsA(isA<PageXmlException>()),
      reason: 'Created and LastChange are schema-required',
    );
    expect(
      () => parsePageXmlDocument(
        _bytes(_doc(pageAttributes: 'imageFilename="p.tif" imageHeight="10"')),
      ),
      throwsA(isA<PageXmlException>()),
      reason: 'imageWidth missing',
    );
    expect(
      () => parsePageXmlDocument(_bytes(_doc(pageAttributes: 'imageWidth="10" imageHeight="10"'))),
      throwsA(isA<PageXmlException>()),
      reason: 'imageFilename missing',
    );
    expect(
      () => parsePageXmlDocument(
        _bytes(_doc(pageAttributes: 'imageFilename="p" imageWidth="0" imageHeight="10"')),
      ),
      throwsA(isA<PageXmlException>()),
    );
  });

  test('numeric corruption fails typed, including non-finite values', () {
    for (final value in ['NaN', 'Infinity', '-Infinity', '1e400']) {
      expect(
        () => parsePageXmlDocument(
          _bytes(
            _doc(
              pageAttributes:
                  'imageFilename="p" imageWidth="10" imageHeight="10" orientation="$value"',
            ),
          ),
        ),
        throwsA(isA<PageXmlException>()),
        reason: value,
      );
    }
    // Negative orientation is schema-legal (anti-clockwise) and stays
    // native: accepted as data, never turned into a rotation.
    final negative = parsePageXmlDocument(
      _bytes(
        _doc(
          pageAttributes: 'imageFilename="p" imageWidth="10" imageHeight="10" orientation="-90.0"',
        ),
      ),
    );
    expect(negative.page.orientation, -90.0);
    expect(negative.page.rotation, 270);
    expect(
      () => parsePageXmlDocument(
        _bytes(_doc(body: '<TextRegion id="r"><Coords points="0,0 5,5" conf="1.5"/></TextRegion>')),
      ),
      throwsA(isA<PageXmlException>()),
      reason: 'confidence above one',
    );
  });

  test('malformed points fail typed', () {
    for (final points in ['0,0', '0,0 5,-5', '0,0 5', 'a,b 1,1', '0.5,0 1,1', '']) {
      expect(
        () => parsePageXmlDocument(
          _bytes(_doc(body: '<TextRegion id="r"><Coords points="$points"/></TextRegion>')),
        ),
        throwsA(isA<PageXmlException>()),
        reason: points,
      );
    }
  });

  test('a TextEquiv without Unicode content fails typed', () {
    expect(
      () => parsePageXmlDocument(
        _bytes(
          _doc(
            body: _textRegion(
              textEquiv: '<TextEquiv><PlainText>no unicode</PlainText></TextEquiv>',
            ),
          ),
        ),
      ),
      throwsA(isA<PageXmlException>()),
    );
  });

  test('negative TextEquiv indexes fail typed', () {
    expect(
      () => parsePageXmlDocument(
        _bytes(
          _doc(
            body: _textRegion(textEquiv: '<TextEquiv index="-1"><Unicode>x</Unicode></TextEquiv>'),
          ),
        ),
      ),
      throwsA(isA<PageXmlException>()),
    );
  });

  test('id collisions across regions, lines, words and groups fail typed', () {
    expect(
      () => parsePageXmlDocument(
        _bytes(
          _doc(
            body: _textRegion(id: 'dup') + _textRegion(id: 'dup'),
          ),
        ),
      ),
      throwsA(isA<PageXmlException>()),
    );
    expect(
      () => parsePageXmlDocument(
        _bytes(
          _doc(
            body:
                '<TextRegion id="r"><Coords points="0,0 5,5"/>'
                '<TextLine id="r"><Coords points="0,0 5,5"/></TextLine></TextRegion>',
          ),
        ),
      ),
      throwsA(isA<PageXmlException>()),
    );
    expect(
      () => parsePageXmlDocument(
        _bytes(
          _doc(
            body:
                '<TextRegion id="r"><Coords points="0,0 5,5"/>'
                '<TextLine id="l"><Coords points="0,0 5,5"/>${_word(id: 'l')}</TextLine>'
                '</TextRegion>',
          ),
        ),
      ),
      throwsA(isA<PageXmlException>()),
    );
  });

  test('reading-order violations fail typed', () {
    String withOrder(final String inner) => _doc(
      body:
          '${_textRegion(id: 'r1', textEquiv: '<TextEquiv><Unicode>a</Unicode></TextEquiv>')}'
          '${_textRegion(id: 'r2', textEquiv: '<TextEquiv><Unicode>b</Unicode></TextEquiv>')}'
          '<ReadingOrder><OrderedGroup id="g1">$inner</OrderedGroup></ReadingOrder>',
    );

    expect(
      () => parsePageXmlDocument(
        _bytes(withOrder('<RegionRefIndexed index="0" regionRef="missing"/>')),
      ),
      throwsA(isA<PageXmlException>()),
      reason: 'reference without target',
    );
    expect(
      () => parsePageXmlDocument(
        _bytes(
          withOrder(
            '<RegionRefIndexed index="0" regionRef="r1"/>'
            '<RegionRefIndexed index="1" regionRef="r1"/>',
          ),
        ),
      ),
      throwsA(isA<PageXmlException>()),
      reason: 'region referenced twice',
    );
    expect(
      () => parsePageXmlDocument(_bytes(withOrder('<RegionRefIndexed index="0" regionRef="g1"/>'))),
      throwsA(isA<PageXmlException>()),
      reason: 'group id used as region id',
    );
    expect(
      () => parsePageXmlDocument(_bytes(withOrder('<RegionRefIndexed regionRef="r1"/>'))),
      throwsA(isA<PageXmlException>()),
      reason: 'indexed ref without index',
    );
    expect(
      () => parsePageXmlDocument(_bytes(withOrder('<RegionRef regionRef="r1"/>'))),
      throwsA(isA<PageXmlException>()),
      reason: 'unindexed ref inside an ordered group',
    );
  });

  test('nested unordered groups recurse and keep document order', () {
    final payload = _doc(
      body:
          '${_textRegion(id: 'r1', textEquiv: '<TextEquiv><Unicode>a</Unicode></TextEquiv>')}'
          '${_textRegion(id: 'r2', textEquiv: '<TextEquiv><Unicode>b</Unicode></TextEquiv>')}'
          '<ReadingOrder><UnorderedGroup id="g1">'
          '<OrderedGroup id="g2">'
          '<RegionRefIndexed index="1" regionRef="r2"/>'
          '<RegionRefIndexed index="0" regionRef="r1"/>'
          '</OrderedGroup>'
          '</UnorderedGroup></ReadingOrder>',
    );
    final document = parsePageXmlDocument(_bytes(payload));
    expect(document.page.readingOrder!.regionRefs(), ['r1', 'r2']);
  });

  test('duplicate sibling indexes fail typed; index order wins', () {
    final payload = _doc(
      body:
          '${_textRegion(id: 'first', textEquiv: '<TextEquiv><Unicode>a</Unicode></TextEquiv>')}'
          '${_textRegion(id: 'second', textEquiv: '<TextEquiv><Unicode>b</Unicode></TextEquiv>')}'
          '<ReadingOrder><OrderedGroup id="g">'
          '<RegionRefIndexed index="5" regionRef="first"/>'
          '<RegionRefIndexed index="5" regionRef="second"/>'
          '</OrderedGroup></ReadingOrder>',
    );
    expect(
      () => parsePageXmlDocument(_bytes(payload)),
      throwsA(isA<PageXmlException>()),
      reason: 'siblings must not declare the same index',
    );
    final ordered = _doc(
      body:
          '${_textRegion(id: 'first', textEquiv: '<TextEquiv><Unicode>a</Unicode></TextEquiv>')}'
          '${_textRegion(id: 'second', textEquiv: '<TextEquiv><Unicode>b</Unicode></TextEquiv>')}'
          '<ReadingOrder><OrderedGroup id="g">'
          '<RegionRefIndexed index="7" regionRef="second"/>'
          '<RegionRefIndexed index="2" regionRef="first"/>'
          '</OrderedGroup></ReadingOrder>',
    );
    expect(parsePageXmlDocument(_bytes(ordered)).page.readingOrder!.regionRefs(), [
      'first',
      'second',
    ], reason: 'declared indexes re-sequence stored order');
  });

  test('XML structure limits hold before the DOM', () {
    final deep = '${'<extension>' * 129}${'</extension>' * 129}';
    final wide = '<extension/>' * 65537;
    for (final payload in [deep, wide]) {
      expect(
        () => parsePageXmlDocument(_bytes(_doc(body: payload))),
        throwsA(isA<PageXmlException>()),
      );
    }
    expect(
      () => parsePageXmlDocument(_bytes('<?xml version="1.0"?><PcGts')),
      throwsA(isA<PageXmlException>()),
      reason: 'malformed XML',
    );
    expect(
      () => parsePageXmlDocument(
        _bytes('<?xml version="1.0"?><alto xmlns="$_v2019"><Metadata/></alto>'),
      ),
      throwsA(isA<PageXmlException>()),
      reason: 'wrong root element',
    );
  });

  test('polygon point and TextEquiv budgets hold', () {
    final points = List.generate(4097, (i) => '$i,${i % 97}').join(' ');
    expect(
      () => parsePageXmlDocument(
        _bytes(_doc(body: '<TextRegion id="r"><Coords points="$points"/></TextRegion>')),
      ),
      throwsA(isA<PageXmlException>()),
      reason: '4097 points',
    );
    final alternatives = List.generate(
      33,
      (i) => '<TextEquiv index="$i"><Unicode>t$i</Unicode></TextEquiv>',
    ).join();
    expect(
      () => parsePageXmlDocument(
        _bytes(
          _doc(
            body: _textRegion(id: 'r', textEquiv: alternatives),
          ),
        ),
      ),
      throwsA(isA<PageXmlException>()),
      reason: '33 alternatives',
    );
  });

  test('group nesting beyond the limit fails typed', () {
    var inner = '<RegionRefIndexed index="0" regionRef="r1"/>';
    for (var i = 0; i < 9; i++) {
      inner = '<OrderedGroupIndexed id="g$i" index="0">$inner</OrderedGroupIndexed>';
    }
    final payload = _doc(
      body:
          '${_textRegion(id: 'r1', textEquiv: '<TextEquiv><Unicode>a</Unicode></TextEquiv>')}'
          '<ReadingOrder><OrderedGroup id="root">$inner</OrderedGroup></ReadingOrder>',
    );
    expect(() => parsePageXmlDocument(_bytes(payload)), throwsA(isA<PageXmlException>()));
  });
}
