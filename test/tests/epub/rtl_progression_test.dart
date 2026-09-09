import 'package:e_livre/src/features/epub/entities/entities.dart';
import 'package:e_livre/src/features/epub/package/parse_epub_package.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/language/rtl_languages.dart';
import 'package:test/test.dart';

void main() {
  group('isRtlLanguage', () {
    test('matches Calibre\'s right-to-left language list', () {
      for (final code in ['ara', 'heb', 'aze', 'div', 'arc', 'syc', 'myz', 'ckb', 'urd', 'fas']) {
        expect(isRtlLanguage(code), isTrue, reason: code);
      }
    });

    test('matches the two-letter forms of the same languages', () {
      for (final code in ['ar', 'he', 'az', 'dv', 'ur', 'fa']) {
        expect(isRtlLanguage(code), isTrue, reason: code);
      }
    });

    test('rejects left-to-right languages', () {
      for (final code in ['en', 'pt', 'fr', 'de', 'ja', 'zh', 'ko', 'es']) {
        expect(isRtlLanguage(code), isFalse, reason: code);
      }
    });

    test('normalizes case, whitespace and region subtags', () {
      expect(isRtlLanguage('AR'), isTrue);
      expect(isRtlLanguage(' Ar '), isTrue);
      expect(isRtlLanguage('ar-SA'), isTrue);
      expect(isRtlLanguage('ar_SA'), isTrue);
      expect(isRtlLanguage('ARA'), isTrue);
      expect(isRtlLanguage('urd-PK'), isTrue);
      expect(isRtlLanguage('pt-BR'), isFalse);
      expect(isRtlLanguage('PT'), isFalse);
    });

    test('rejects null, empty and malformed tags', () {
      expect(isRtlLanguage(null), isFalse);
      expect(isRtlLanguage(''), isFalse);
      expect(isRtlLanguage('   '), isFalse);
      expect(isRtlLanguage('-'), isFalse);
      expect(isRtlLanguage('xyz'), isFalse);
    });
  });

  group('effectivePageProgressionDirection', () {
    test('prefers the declared spine direction over language inference', () {
      for (final direction in [PageProgressionDirection.ltr, PageProgressionDirection.rtl]) {
        final book = _book(language: 'ar', spineAttribute: direction.name);
        expect(
          book.effectivePageProgressionDirection,
          direction,
          reason: 'declared ${direction.name} must beat the ar inference',
        );
      }
    });

    test('infers rtl from right-to-left book languages when the spine is silent', () {
      for (final language in ['ar', 'he', 'fa', 'ur', 'AR', 'ar-SA', 'ckb']) {
        final book = _book(language: language);
        expect(
          book.effectivePageProgressionDirection,
          PageProgressionDirection.rtl,
          reason: language,
        );
      }
    });

    test('stays unspecified for left-to-right books without a declared direction', () {
      for (final language in ['en', 'pt', 'pt-BR', 'ja']) {
        final book = _book(language: language);
        expect(
          book.effectivePageProgressionDirection,
          PageProgressionDirection.unspecified,
          reason: language,
        );
      }
    });
  });
}

EpubBook _book({required final String language, final String? spineAttribute}) {
  final attribute = spineAttribute == null ? '' : ' page-progression-direction="$spineAttribute"';
  final opf =
      '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:rtl-inference</dc:identifier>
    <dc:title>RTL Inference</dc:title>
    <dc:language>$language</dc:language>
  </metadata>
  <manifest>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ch1"$attribute>
    <itemref idref="ch1"/>
  </spine>
</package>
''';

  return EpubBook(
    navigation: Navigation(title: 'RTL Inference', navPoints: const <NavPoint>[]),
    files: Files(
      html: const <TextFile>[],
      css: const <TextFile>[],
      images: const <BinaryFile>[],
      fonts: const <BinaryFile>[],
      others: const <BinaryFile>[],
    ),
    cover: BinaryFile.empty(),
    package: parsePackage(opf),
  );
}
