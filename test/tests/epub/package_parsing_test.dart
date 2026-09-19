import 'dart:convert' as convert;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/features/epub/container/epub_root_file.dart';
import 'package:unseal/src/features/epub/entities/entities.dart';
import 'package:unseal/src/features/epub/exceptions/epub_exception.dart';
import 'package:unseal/src/features/epub/package/parse_epub_package.dart';

void main() {
  final books = [
    _TestBookPackageInfo(
      file: 'test/resources/epub/Alices Adventures in Wonderland.epub',
      uniqueIdentifier: 'uuid_id',
      version: '2.0',
      title: "Alice's Adventures in Wonderland",
      date: '1865-07-04T00:00:00+00:00',
      subject: 'fiction',
      language: 'en',
      identifiers: ['eb2934ae-bb1a-4652-bce7-9f78fc5ca496'],
      uniqueIdentifierValue: 'eb2934ae-bb1a-4652-bce7-9f78fc5ca496',
      rights: ['Public Domain'],
      contributor: 'calibre (3.21.0) [http://calibre-ebook.com]',
      creator: 'Lewis Carroll',
      publisher: 'D. Appleton and Co',
      manifestItems: 45,
      spineItems: 14,
    ),
    _TestBookPackageInfo(
      file: 'test/resources/epub/linear-algebra.epub',
      uniqueIdentifier: 'uid',
      version: '3.0',
      title: 'A First Course in Linear Algebra',
      subject: 'education',
      language: 'en',
      identifiers: ['https://github.com/IDPF/edupub/tree/master/samples/linear-algebra'],
      uniqueIdentifierValue: 'https://github.com/IDPF/edupub/tree/master/samples/linear-algebra',
      rights: [
        'This work is shared with the public using the GNU Free Documentation License, Version 1.2.',
        '© 2004 by Robert A. Beezer.',
      ],
      creator: 'Robert A. Beezer',
      manifestItems: 127,
      spineItems: 111,
      educationalRole: 'student',
      accessibilityFeatures: [
        'mathml',
        'readingOrder',
        'structuralNavigation',
        'tableOfContents',
        'unlocked',
      ],
      typicalAgeRange: '18+',
    ),
    _TestBookPackageInfo(
      file: 'test/resources/books/epub/accessible-epub-3.epub',
      uniqueIdentifier: 'pub-identifier',
      version: '3.0',
      title: 'Accessible EPUB 3',
      subject: '',
      language: 'en',
      identifiers: ['urn:isbn:9781449328030'],
      uniqueIdentifierValue: 'urn:isbn:9781449328030',
      creator: 'Matt Garrish',
      manifestItems: 35,
      spineItems: 22,
      accessibilityFeatures: ['tableOfContents', 'readingOrder', 'alternativeText'],
      date: '2012-02-20',
      contributor: 'O’Reilly Production Services',
      publisher: 'O’Reilly Media, Inc.',
      rights: ['Copyright © 2012 O’Reilly Media, Inc'],
    ),
    _TestBookPackageInfo(
      file: 'test/resources/epub/structure-sample-01.epub',
      uniqueIdentifier: 'pub-id',
      version: '3.0',
      title: 'Education Structure Sample',
      subject: 'education',
      language: 'en',
      identifiers: ['test-sample-uc'],
      uniqueIdentifierValue: 'test-sample-uc',
      creator: 'Jane Doe',
      manifestItems: 45,
      spineItems: 23,
      accessibilityFeatures: [
        'alternativeText',
        'mathml',
        'index',
        'printPageNumbers',
        'readingOrder',
        'structuralNavigation',
        'tableOfContents',
      ],
      date: '2011-01-07',
      publisher: 'Pearson',
      educationalRole: 'student',
      typicalAgeRange: '18+',
    ),
    _TestBookPackageInfo(
      file: 'test/resources/books/epub/dom-casmurro-pt.epub',
      uniqueIdentifier: 'id',
      version: '3.0',
      title: 'Dom Casmurro',
      subject: 'Adultery -- Fiction',
      language: 'pt',
      identifiers: ['http://www.gutenberg.org/55752'],
      uniqueIdentifierValue: 'http://www.gutenberg.org/55752',
      creator: 'Machado de Assis',
      date: '2017-10-15',
      rights: ['Public domain in the USA.'],
      manifestItems: 11,
      spineItems: 5,
      accessibilityFeatures: ['readingOrder'],
    ),
    _TestBookPackageInfo(
      file: 'test/resources/books/epub/vertical-writing-ja.epub',
      uniqueIdentifier: 'pub-id',
      version: '3.0',
      title: 'ガリ版の話',
      subject: '',
      language: 'ja',
      identifiers: ['urn:uuid:8B3EBB46-DA57-11E2-AB84-32F5FD9156E7'],
      uniqueIdentifierValue: 'urn:uuid:8B3EBB46-DA57-11E2-AB84-32F5FD9156E7',
      creator: '津野海太郎',
      manifestItems: 19,
      spineItems: 7,
      date: '2013-06-21T09:47:11Z',
      publisher: '株式会社ボイジャー',
    ),
  ];

  for (final book in books) {
    test('EpubPackage parsing for ${book.title}', () async {
      final bytes = File(book.file).readAsBytesSync();
      final archive = ZipDecoder().decodeBytes(bytes);

      final rootFilePath = getEpubRootFilePath(archive);
      final rootFile = _getRootFile(archive, rootFilePath);

      final epubPackage = parsePackage(convert.utf8.decode(rootFile.content as List<int>));

      expect(epubPackage.uniqueIdentifier, book.uniqueIdentifier);
      expect(epubPackage.version, book.version);
      expect(epubPackage.metadata.uniqueIdentifierValue, book.uniqueIdentifierValue);

      // Metadata
      if (epubPackage.metadata is Epub2Metadata) {
        final metadata = epubPackage.metadata as Epub2Metadata;
        _checkCommonMetadataProperties(metadata, book);
      } else if (epubPackage.metadata is Epub3Metadata) {
        final metadata = epubPackage.metadata as Epub3Metadata;
        _checkCommonMetadataProperties(metadata, book);
        // expect(metadata.schemaOrg, book.schemaOrg);
        // expect(metadata.accessibilitySummary, book.accessibilitySummary);
        expect(metadata.accessibilityFeatures, book.accessibilityFeatures);
        expect(metadata.educationalRole, book.educationalRole);
        expect(metadata.typicalAgeRange, book.typicalAgeRange);
      } else {
        fail('Unknown metadata type');
      }

      // Manifest
      expect(epubPackage.manifest.items.length, book.manifestItems);

      // Spine
      expect(epubPackage.spine.items.length, book.spineItems);
    });
  }

  test('parses rich metadata without a commercial book fixture', () {
    final epubPackage = parsePackage('''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">1234</dc:identifier>
    <dc:identifier>urn:isbn:9780000000000</dc:identifier>
    <dc:title>Metadata Fixture</dc:title>
    <dc:language>en</dc:language>
    <dc:description>Fixture description</dc:description>
    <meta property="schema:accessibilityFeature">longDescription</meta>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="chapter"><itemref idref="chapter"/></spine>
</package>
''');
    final metadata = epubPackage.metadata as Epub3Metadata;

    expect(metadata.identifiers, ['1234', 'urn:isbn:9780000000000']);
    expect(metadata.description, 'Fixture description');
    expect(metadata.accessibilityFeatures, ['longDescription']);
  });

  test('parsePackage tolerates guide references without title', () {
    const opf = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:guide-test</dc:identifier>
    <dc:title>Guide Test</dc:title>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
  </spine>
  <guide>
    <reference type="text" href="chapter1.xhtml"/>
    <reference type="toc" title="Contents" href="nav.xhtml"/>
  </guide>
</package>
''';

    final epubPackage = parsePackage(opf);

    final guide = epubPackage.guide;
    expect(guide, isNotNull);
    expect(guide!.references, hasLength(2));
    expect(guide.references.first.title, isEmpty);
    expect(guide.references.first.href, 'chapter1.xhtml');
    expect(guide.references.last.title, 'Contents');
  });

  test('reads the spine page-progression-direction', () {
    for (final version in ['2.0', '3.0']) {
      final epubPackage = parsePackage(_packageWithSpineDirection('rtl', version: version));
      expect(epubPackage.spine.pageProgressionDirection, PageProgressionDirection.rtl);
      expect(epubPackage.spine.pageProgressionDirection.name, 'rtl');
    }
  });

  test('reads an explicit ltr spine page-progression-direction', () {
    final epubPackage = parsePackage(_packageWithSpineDirection('ltr'));

    expect(epubPackage.spine.pageProgressionDirection, PageProgressionDirection.ltr);
  });

  test('a missing spine page-progression-direction degrades to unspecified', () {
    final epubPackage = parsePackage(_packageWithSpineDirection(null));

    expect(epubPackage.spine.pageProgressionDirection, PageProgressionDirection.unspecified);
  });

  test(
    'the default and malformed spine page-progression-direction values degrade to unspecified',
    () {
      for (final value in ['default', 'RTL', 'bogus']) {
        final epubPackage = parsePackage(_packageWithSpineDirection(value));

        expect(
          epubPackage.spine.pageProgressionDirection,
          PageProgressionDirection.unspecified,
          reason: 'attribute value "$value"',
        );
      }
    },
  );
}

const String _spineDirectionPackageTemplate = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="%VERSION%" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:progression-test</dc:identifier>
    <dc:title>Progression Test</dc:title>
    <dc:language>ar</dc:language>
  </metadata>
  <manifest>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ch1"%PPD_ATTRIBUTE%>
    <itemref idref="ch1"/>
  </spine>
</package>
''';

String _packageWithSpineDirection(final String? direction, {final String version = '3.0'}) {
  final attribute = direction == null ? '' : ' page-progression-direction="$direction"';

  return _spineDirectionPackageTemplate
      .replaceFirst('%VERSION%', version)
      .replaceFirst('%PPD_ATTRIBUTE%', attribute);
}

void _checkCommonMetadataProperties(
  final Metadata metadata,
  final _TestBookPackageInfo testPackageInfo,
) {
  expect(metadata.title, testPackageInfo.title);
  expect(metadata.date, testPackageInfo.date);
  expect(metadata.subject, testPackageInfo.subject);
  expect(metadata.language, testPackageInfo.language);
  expect(metadata.identifiers, testPackageInfo.identifiers);
  expect(metadata.rights, testPackageInfo.rights);
  expect(metadata.contributor, testPackageInfo.contributor);
  expect(metadata.creator, testPackageInfo.creator);
  expect(metadata.publisher, testPackageInfo.publisher);
}

ArchiveFile _getRootFile(final Archive archive, final String? rootFilePath) {
  if (rootFilePath == null) throw EpubException('No root file found');
  final rootFile = archive.findFile(rootFilePath);
  return rootFile ?? (throw EpubException('No root file found'));
}

class _TestBookPackageInfo {
  _TestBookPackageInfo({
    required this.file,
    required this.uniqueIdentifier,
    required this.version,
    required this.title,
    required this.subject,
    required this.language,
    required this.identifiers,
    required this.creator,
    required this.manifestItems,
    required this.spineItems,
    required this.uniqueIdentifierValue,
    this.accessibilityFeatures = const [],
    this.date = '',
    this.contributor = '',
    this.publisher = '',
    this.rights = const [],
    this.educationalRole = '',
    this.typicalAgeRange = '',
  });

  final String file;
  final String uniqueIdentifier;
  final String version;
  final String title;
  final String date;
  final String subject;
  final String language;
  final List<String> identifiers;
  final String uniqueIdentifierValue;
  final List<String> rights;
  final String contributor;
  final String creator;
  final String publisher;
  final int manifestItems;
  final int spineItems;
  // final String schemaOrg;
  // final String accessibilitySummary;
  final String educationalRole;
  final String typicalAgeRange;
  final List<String> accessibilityFeatures;
}
