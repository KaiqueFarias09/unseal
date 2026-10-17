import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

Uint8List _bytes(final String xml) => Uint8List.fromList(utf8.encode(xml));

const String _v3Doc = '''
<?xml version="1.0" encoding="UTF-8"?>
<alto xmlns="http://www.loc.gov/standards/alto/ns-v3#">
  <Description>
    <MeasurementUnit>pixel</MeasurementUnit>
    <OCRProcessing ID="ID1"><ocrProcessingStep>
      <processingSoftware><softwareName>TestOCR</softwareName><softwareVersion>9.9</softwareVersion></processingSoftware>
    </ocrProcessingStep></OCRProcessing>
  </Description>
  <Layout><Page WIDTH="200" HEIGHT="100" PHYSICAL_IMG_NR="1" PC="0.9">
    <PrintSpace HPOS="0" VPOS="0" WIDTH="200" HEIGHT="100">
      <TextBlock ID="B1" HPOS="10" VPOS="20" WIDTH="150" HEIGHT="40">
        <TextLine ID="L1" HPOS="10" VPOS="20" WIDTH="150" HEIGHT="10" WC="0.8">
          <String ID="S1" HPOS="10" VPOS="20" WIDTH="40" HEIGHT="10" CONTENT="café" WC="0.7"/>
          <SP WIDTH="6"/>
          <String ID="S2" HPOS="56" VPOS="20" WIDTH="30" HEIGHT="10" CONTENT="𝄞" WC="0.6"/>
        </TextLine>
      </TextBlock>
      <Illustration HPOS="10" VPOS="60" WIDTH="80" HEIGHT="30"/>
    </PrintSpace>
  </Page></Layout>
</alto>
''';

CanonicalTextSnapshot _snapshot(final String text) => CanonicalTextSnapshot(
  identity: PublicationRevision(publicationId: 'test:alto-target'),
  occurrence: SectionOccurrence(
    sectionIndex: 0,
    resourcePath: 'page.html',
    readingOrderRevision: 'sha256:${'1' * 64}',
  ),
  profile: TextProfile.of(
    algorithm: 'test.target',
    options: const <String, String>{},
    planRevision: 'sha256:${'0' * 64}',
  ),
  text: text,
);

void main() {
  test('ALTO numeric corruption fails typed, including non-finite values', () {
    for (final value in ['-1', 'NaN', 'Infinity', '-Infinity']) {
      expect(
        () => parseAltoDocument(_bytes(_v3Doc.replaceFirst('WIDTH="150"', 'WIDTH="$value"'))),
        throwsA(isA<AltoException>()),
        reason: value,
      );
    }
    expect(
      () => parseAltoDocument(_bytes(_v3Doc.replaceFirst('WC="0.7"', 'WC="NaN"'))),
      throwsA(isA<AltoException>()),
    );
  });

  test('ignored XML extensions respect depth and page element budgets', () {
    final deep = '${'<extension>' * 129}${'</extension>' * 129}';
    final wide = '<extension/>' * 65537;
    for (final payload in [deep, wide]) {
      expect(
        () => parseAltoDocument(
          _bytes(_v3Doc.replaceFirst('</PrintSpace>', '$payload</PrintSpace>')),
        ),
        throwsA(isA<AltoException>()),
      );
    }
  });

  test('ambiguity cannot be disabled by a one-candidate scan', () {
    final document = parseAltoDocument(_bytes(_v3Doc));
    expect(
      () => bindAltoToSnapshot(
        document: document,
        target: _snapshot('café café'),
        limits: const AltoBindLimits(maxCandidateOccurrences: 1),
      ),
      throwsArgumentError,
    );
  });

  group('parseAltoDocument', () {
    test('reads the real Tesseract fixture with its provenance', () {
      final document = parseAltoDocument(
        File('test/resources/alto/goody-page2-tesseract.xml').readAsBytesSync(),
      );
      expect(document.version, 3);
      expect(document.unit, SpatialUnit.pixel);
      expect(document.softwareName, 'Tesseract');
      expect(document.softwareVersion, '5.5.3');
      expect(document.pages, hasLength(1));
      final page = document.pages[0];
      expect(page.width, 2346);
      expect(page.height, 3140);
      // Tesseract nests its text blocks inside composed blocks; the
      // block kinds stay in the document model either way.
      final textBlocks = <AltoBlock>[];
      void collect(final AltoBlock block) {
        if (block.kind == AltoBlockKind.text) textBlocks.add(block);
        block.children.forEach(collect);
      }

      for (final block in page.blocks) {
        collect(block);
      }
      expect(textBlocks, isNotEmpty);
      final strings = <AltoString>[
        for (final block in textBlocks)
          for (final line in block.lines) ...line.strings,
      ];
      expect(strings, isNotEmpty);
      expect(
        strings.any((s) => s.content == 'BOOK'),
        isTrue,
        reason: 'the fixture body carries the page text',
      );
      expect(strings.first.rect, isA<SpatialRect>());
    });

    test('parses the v2 and v4 namespaces into their versions', () {
      final v2 = parseAltoDocument(
        _bytes(
          _v3Doc
              .replaceFirst('ns-v3#', 'ns-v2#')
              .replaceFirst('<Illustration HPOS="10" VPOS="60" WIDTH="80" HEIGHT="30"/>', ''),
        ),
      );
      expect(v2.version, 2);
      final v4 = parseAltoDocument(_bytes(_v3Doc.replaceFirst('ns-v3#', 'ns-v4#')));
      expect(v4.version, 4);
    });

    test('keeps format detail out of the shared projection', () {
      final document = parseAltoDocument(_bytes(_v3Doc));
      final kinds = document.pages[0].blocks.map((b) => b.kind).toList();
      expect(kinds, containsAll(<AltoBlockKind>[AltoBlockKind.text, AltoBlockKind.illustration]));
    });

    test('rejects malformed and out-of-subset documents typed', () {
      // Not XML.
      expect(() => parseAltoDocument(_bytes('not xml')), throwsA(isA<AltoException>()));
      // Unknown namespace.
      expect(
        () => parseAltoDocument(_bytes(_v3Doc.replaceFirst('ns-v3#', 'ns-v9#'))),
        throwsA(isA<AltoUnsupportedFeatureException>()),
      );
      // Missing MeasurementUnit.
      expect(
        () => parseAltoDocument(
          _bytes(_v3Doc.replaceFirst('<MeasurementUnit>pixel</MeasurementUnit>', '')),
        ),
        throwsA(isA<AltoException>()),
      );
      // Unknown unit.
      expect(
        () => parseAltoDocument(_bytes(_v3Doc.replaceFirst('>pixel<', '>furlong<'))),
        throwsA(isA<AltoUnsupportedFeatureException>()),
      );
      // String without CONTENT.
      expect(
        () => parseAltoDocument(_bytes(_v3Doc.replaceFirst(' CONTENT="café"', ''))),
        throwsA(isA<AltoException>()),
      );
      // Page without usable dimensions.
      expect(
        () => parseAltoDocument(
          _bytes(
            _v3Doc.replaceFirst('WIDTH="200" HEIGHT="100" PHYSICAL_IMG_NR', 'PHYSICAL_IMG_NR'),
          ),
        ),
        throwsA(isA<AltoException>()),
      );
      // Confidence outside 0..1.
      expect(
        () => parseAltoDocument(_bytes(_v3Doc.replaceFirst('WC="0.7"', 'WC="7"'))),
        throwsA(isA<AltoException>()),
      );
    });

    test('bounds composed-block nesting and per-line strings', () {
      final deep = List.generate(
        6,
        (i) => '',
      ).join('<ComposedBlock HPOS="0" VPOS="0" WIDTH="10" HEIGHT="10">');
      final deepClose = List.generate(6, (i) => '</ComposedBlock>').join();
      expect(
        () => parseAltoDocument(
          _bytes(
            _v3Doc
                .replaceFirst('<TextBlock ID="B1"', '$deep<TextBlock ID="B1"')
                .replaceFirst('</TextBlock>', '</TextBlock>$deepClose'),
          ),
        ),
        throwsA(isA<AltoException>()),
      );
      final strings = List.generate(
        4097,
        (i) => '<String HPOS="$i" VPOS="0" WIDTH="1" HEIGHT="1" CONTENT="a"/>',
      ).join();
      expect(
        () => parseAltoDocument(
          _bytes(
            _v3Doc.replaceFirst(
              '<String ID="S1" HPOS="10" VPOS="20" WIDTH="40" HEIGHT="10" CONTENT="café" WC="0.7"/>',
              strings,
            ),
          ),
        ),
        throwsA(isA<AltoException>()),
      );
    });
  });

  group('AltoScale', () {
    test('pixel units need no evidence and convert by identity', () {
      final scale = AltoScale.fromUnit(SpatialUnit.pixel, dpi: null);
      expect(scale, isNotNull);
      expect(scale!.factor, 1.0);
    });

    test('physical units refuse to convert without a verifiable scale', () {
      expect(AltoScale.fromUnit(SpatialUnit.millimeter10, dpi: null), isNull);
      expect(AltoScale.fromUnit(SpatialUnit.inch1200, dpi: 0), isNull);
      final scale = AltoScale.fromUnit(SpatialUnit.millimeter10, dpi: 254);
      expect(scale!.factor, closeTo(1.0, 1e-9));
      final rect = scale.convertRect(SpatialRect(x: 0, y: 0, width: 10, height: 5));
      expect(rect.width, closeTo(10.0, 1e-9));
    });

    test('page-dimension agreement builds a scale, mismatch refuses', () {
      final scale = AltoScale.fromPageDimensions(
        documentWidth: 100,
        documentHeight: 200,
        targetWidth: 300,
        targetHeight: 600,
      );
      expect(scale.factor, closeTo(3.0, 1e-9));
      expect(
        () => AltoScale.fromPageDimensions(
          documentWidth: 100,
          documentHeight: 200,
          targetWidth: 300,
          targetHeight: 900,
        ),
        throwsA(isA<AltoUnitConversionException>()),
      );
    });
  });

  group('bindAltoToSnapshot', () {
    test('maps words onto UTF-16 ranges, preserving confidence and origin', () {
      final document = parseAltoDocument(_bytes(_v3Doc));
      final target = _snapshot('um café 𝄞 e fim');
      final binding = bindAltoToSnapshot(document: document, target: target);

      expect(binding.wordsResolved, 2);
      expect(binding.wordsMissing, 0);
      expect(binding.pages, hasLength(1));
      final page = binding.pages[0];
      expect(page.unit, SpatialUnit.pixel);
      expect(page.provenance.origin, SpatialTextOrigin.importedOcr);
      expect(page.provenance.softwareName, 'TestOCR');
      expect(page.provenance.hasConfidence, isTrue);
      final words = page.zones.where((z) => z.kind == SpatialZoneKind.word).toList();
      expect(target.text.substring(words[0].textStart, words[0].textEnd), 'café');
      expect(target.text.substring(words[1].textStart, words[1].textEnd), '𝄞');
      expect(words[0].confidence, 0.7);
      expect(words[1].confidence, 0.6);
      // The line aggregates its words' exact bounds; the region, the
      // block's.
      final line = page.zones.firstWhere((z) => z.kind == SpatialZoneKind.line);
      expect(target.text.substring(line.textStart, line.textEnd), 'café 𝄞');
      expect(line.confidence, 0.8);
      final region = page.zones.firstWhere((z) => z.kind == SpatialZoneKind.region);
      expect(target.text.substring(region.textStart, region.textEnd), 'café 𝄞');
      // Identity travels to the binding for persisted reuse.
      expect(binding.targetIdentity.publicationId, 'test:alto-target');
    });

    test('repeated quotes stay ambiguous with their candidate lists', () {
      final document = parseAltoDocument(
        _bytes(
          _v3Doc
              .replaceFirst('CONTENT="café"', 'CONTENT="ab"')
              .replaceFirst('CONTENT="𝄞"', 'CONTENT="ab"'),
        ),
      );
      final target = _snapshot('x ab y ab');
      final binding = bindAltoToSnapshot(document: document, target: target);
      expect(binding.wordsAmbiguous, 2);
      expect(binding.ambiguousWords, hasLength(2));
      final first = binding.ambiguousWords[0];
      expect(first.content, 'ab');
      expect(first.candidates, hasLength(2));
      expect(first.chosen, (2, 4));
      // The second word's cursor starts after the first choice, so it
      // maps to the later occurrence.
      expect(binding.ambiguousWords[1].chosen, (7, 9));
      final lookup = binding.lookups[0];
      expect(lookup.wordAt(2)!.textEnd, 4);
    });

    test('words absent from the target are missing with empty ranges', () {
      final document = parseAltoDocument(_bytes(_v3Doc));
      final target = _snapshot('nothing matches here');
      final binding = bindAltoToSnapshot(document: document, target: target);
      expect(binding.wordsMissing, 2);
      final words = binding.pages[0].zones.where((z) => z.kind == SpatialZoneKind.word);
      expect(words.every((z) => z.textStart == z.textEnd), isTrue);
    });

    test('the projection work budget refuses hostile bindings typed', () {
      final document = parseAltoDocument(_bytes(_v3Doc));
      final target = _snapshot('a' * 4096);
      expect(
        () => bindAltoToSnapshot(
          document: document,
          target: target,
          limits: const AltoBindLimits(maxProjectionWork: 16),
        ),
        throwsA(isA<AltoException>()),
      );
    });
  });
}
