import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../../support/page_snapshot.dart';

const _namespace = 'http://schema.primaresearch.org/PAGE/gts/pagecontent/2019-07-15';

PageXmlDocument _document(String region) => parsePageXmlDocument(
  Uint8List.fromList(
    utf8.encode(
      '<PcGts xmlns="$_namespace"><Metadata><Creator>Review</Creator>'
      '<Created>2026-01-01T00:00:00Z</Created><LastChange>2026-01-01T00:00:00Z</LastChange>'
      '</Metadata><Page imageFilename="page.png" imageWidth="100" imageHeight="100">'
      '$region</Page></PcGts>',
    ),
  ),
);

const _coords = '<Coords points="0,0 9,0 9,9"/>';
String _readings(String text) =>
    '<TextEquiv index="0"><Unicode>$text</Unicode></TextEquiv>'
    '<TextEquiv index="1"><Unicode>other</Unicode></TextEquiv>';

void main() {
  test('foreign descendants cannot impersonate PAGE elements', () {
    for (final region in [
      '<TextRegion xmlns="urn:foreign" id="r">$_coords</TextRegion>',
      '<TextRegion id="r"><Coords xmlns="" points="0,0 9,0 9,9"/></TextRegion>',
      '<TextRegion id="r">$_coords<TextEquiv xmlns="urn:foreign"><Unicode>alpha</Unicode></TextEquiv></TextRegion>',
    ]) {
      expect(() => _document(region), throwsA(isA<PageXmlUnsupportedFeatureException>()));
    }
  });

  test('present malformed and negative optional indexes fail typed', () {
    for (final index in ['wrong', '-1', '1.5']) {
      expect(
        () => _document(
          '<TextRegion id="r">$_coords'
          '<TextEquiv index="$index"><Unicode>alpha</Unicode></TextEquiv></TextRegion>',
        ),
        throwsA(isA<PageXmlException>()),
      );
    }
  });

  test('distinct readings stay ambiguous at region, line and word granularity', () {
    final word = '<Word id="w">$_coords${_readings('alpha')}</Word>';
    for (final region in [
      '<TextRegion id="r">$_coords${_readings('alpha')}</TextRegion>',
      '<TextRegion id="r">$_coords<TextLine id="l">$_coords${_readings('alpha')}</TextLine></TextRegion>',
      '<TextRegion id="r">$_coords<TextLine id="l">$_coords$word</TextLine></TextRegion>',
      '<TextRegion id="r">$_coords${_readings('alpha')}<TextLine id="l">$_coords'
          '<Word id="w">$_coords<TextEquiv><Unicode>alpha</Unicode></TextEquiv></Word>'
          '</TextLine></TextRegion>',
      '<TextRegion id="r">$_coords<TextLine id="l">$_coords${_readings('alpha')}'
          '<Word id="w">$_coords<TextEquiv><Unicode>alpha</Unicode></TextEquiv></Word>'
          '</TextLine></TextRegion>',
    ]) {
      final binding = bindPageToSnapshot(
        document: _document(region),
        target: pageSnapshot('alpha other'),
      );
      expect(binding.wordsResolved, 0);
      expect(binding.wordsAmbiguous, 1);
      expect(binding.ambiguousWords.single.candidates, [(0, 5)]);
    }
  });

  test('duplicate identical OCR readings do not invent ambiguity', () {
    final binding = bindPageToSnapshot(
      document: _document('<TextRegion id="r">$_coords${_readings('other')}</TextRegion>'),
      target: pageSnapshot('other'),
    );
    expect(binding.wordsResolved, 1);
    expect(binding.wordsAmbiguous, 0);
  });

  test('candidate enumeration pays projection work before scanning', () {
    final document = _document(
      '<TextRegion id="r">$_coords'
      '<TextEquiv><Unicode>alpha</Unicode></TextEquiv></TextRegion>',
    );
    expect(
      () => bindPageToSnapshot(
        document: document,
        target: pageSnapshot('alpha beta'),
        limits: const PageXmlBindLimits(maxProjectionWork: 10),
      ),
      throwsA(isA<PageXmlException>()),
    );
    expect(
      bindPageToSnapshot(
        document: document,
        target: pageSnapshot('alpha beta'),
        limits: const PageXmlBindLimits(maxProjectionWork: 29),
      ).wordsResolved,
      1,
    );
  });
}
