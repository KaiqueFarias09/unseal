import 'package:test/test.dart';
import 'package:unseal/epub.dart';
import 'package:unseal/src/features/epub/package/parse_epub_package.dart';
import 'package:unseal/src/platform/web/wire/epub_package_wire.dart';

String _opf({final String metadata = '', final String spineProperties = ''}) =>
    '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">'
    '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:title>Test</dc:title><dc:language>en</dc:language>'
    '<dc:identifier id="uid">id</dc:identifier>$metadata</metadata>'
    '<manifest><item id="first" href="first.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="second" href="second.xhtml" media-type="application/xhtml+xml"/></manifest>'
    '<spine><itemref idref="first" properties="$spineProperties"/>'
    '<itemref idref="second"/></spine></package>';

void main() {
  test('reads global and spine-specific rendition properties', () {
    final package =
        parsePackage(
              _opf(
                metadata:
                    '<meta property="rendition:layout">pre-paginated</meta>'
                    '<meta property="rendition:orientation">landscape</meta>'
                    '<meta property="rendition:spread">both</meta>'
                    '<meta property="rendition:flow">paginated</meta>',
                spineProperties:
                    'rendition:layout-reflowable rendition:orientation-portrait '
                    'rendition:spread-none rendition:flow-scrolled-doc rendition:page-spread-left',
              ),
            )
            as Epub3Package;

    final rendition = package.renditionSettings;
    expect(rendition.layout, EpubLayout.prePaginated);
    expect(rendition.layoutFor('first'), EpubLayout.reflowable);
    expect(rendition.layoutFor('second'), EpubLayout.prePaginated);
    expect(rendition.orientationFor('first'), EpubOrientation.portrait);
    expect(rendition.orientationFor('second'), EpubOrientation.landscape);
    expect(rendition.spreadFor('first'), EpubSpread.none);
    expect(rendition.spreadFor('second'), EpubSpread.both);
    expect(rendition.flowFor('first'), EpubFlow.scrolledDoc);
    expect(rendition.flowFor('second'), EpubFlow.paginated);
    expect(rendition.pageSpreadFor('first'), EpubPageSpread.left);
    expect(rendition.pageSpreadFor('second'), isNull);
  });

  test('uses EPUB reading-system defaults when rendition metadata is absent', () {
    final rendition = (parsePackage(_opf()) as Epub3Package).renditionSettings;
    expect(rendition.layout, EpubLayout.reflowable);
    expect(rendition.orientation, EpubOrientation.auto);
    expect(rendition.spread, EpubSpread.auto);
    expect(rendition.flow, EpubFlow.auto);
    expect(rendition.spineItems, isEmpty);
  });

  test('accepts the unprefixed EPUB page-spread properties', () {
    final rendition = (parsePackage(_opf(spineProperties: 'page-spread-right')) as Epub3Package)
        .renditionSettings;
    expect(rendition.pageSpreadFor('first'), EpubPageSpread.right);
  });

  test('groups accessibility modes, alternatives, features, hazards, and summaries', () {
    final package =
        parsePackage(
              _opf(
                metadata:
                    '<meta property="schema:accessMode">textual</meta>'
                    '<meta property="schema:accessMode">visual</meta>'
                    '<meta property="schema:accessModeSufficient">textual, visual</meta>'
                    '<meta property="schema:accessModeSufficient">textual</meta>'
                    '<meta property="schema:accessibilityFeature">alternativeText</meta>'
                    '<meta property="schema:accessibilityHazard">noFlashingHazard</meta>'
                    '<meta property="schema:accessibilitySummary">Descriptions included.</meta>',
              ),
            )
            as Epub3Package;

    final accessibility = (package.metadata as Epub3Metadata).accessibility;
    expect(accessibility.accessModes, ['textual', 'visual']);
    expect(accessibility.sufficientAccessModes, [
      ['textual', 'visual'],
      ['textual'],
    ]);
    expect(accessibility.features, ['alternativeText']);
    expect(accessibility.hazards, ['noFlashingHazard']);
    expect(accessibility.summaries, ['Descriptions included.']);
  });

  test('preserves rendition and accessibility through the browser wire codec', () {
    final package = parsePackage(
      _opf(
        metadata:
            '<meta property="rendition:layout">pre-paginated</meta>'
            '<meta property="schema:accessMode">textual</meta>'
            '<meta property="schema:accessModeSufficient">textual,visual</meta>'
            '<meta property="schema:accessibilityHazard">noFlashingHazard</meta>',
        spineProperties: 'rendition:layout-reflowable rendition:page-spread-center',
      ),
    );

    final restored =
        decodeEpubPackageWireValue(encodeEpubPackageWireValue(package)) as Epub3Package;
    expect(restored.renditionSettings.layout, EpubLayout.prePaginated);
    expect(restored.renditionSettings.layoutFor('first'), EpubLayout.reflowable);
    expect(restored.renditionSettings.spineItems['first']?.pageSpread, EpubPageSpread.center);
    final accessibility = (restored.metadata as Epub3Metadata).accessibility;
    expect(accessibility.accessModes, ['textual']);
    expect(accessibility.sufficientAccessModes, [
      ['textual', 'visual'],
    ]);
    expect(accessibility.hazards, ['noFlashingHazard']);
  });
}
