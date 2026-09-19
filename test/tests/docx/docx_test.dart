import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/docx.dart';
import 'package:unseal/src/foundation/images/image_type_sniffer.dart';

void main() {
  group('DOCX parser', () {
    test('converts paragraphs, runs, headings, lists, tables and breaks', () {
      final book = parseDocxBook(
        _docxBytes({
          'word/document.xml': _documentXml,
          'word/styles.xml': _stylesXml,
          'word/numbering.xml': _numberingXml,
          'docProps/core.xml': _corePropertiesXml,
        }),
      );

      expect(book, isA<DocumentBook>());
      expect(book.format, BookFormat.docx);
      expect(book.files.html, hasLength(1));
      final content = book.files.html.single.content;
      expect(content, contains('<h1 id="heading-1">Chapter title</h1>'));
      expect(content, contains('<strong>bold</strong>'));
      expect(content, contains('<em>italic</em>'));
      expect(content, contains('<u>underlined</u>'));
      expect(content, contains('not underlined'));
      expect(content, isNot(contains('<u>not underlined</u>')));
      expect(content, contains('before<br/>after'));
      expect(content, contains('<ol><li data-list-level="0">first item</li>'));
      expect(content, contains('<table class="docx-table"><tbody>'));
      expect(content, contains('<td><p>left</p></td>'));
      expect(content, contains('<td><p>right</p></td>'));
      expect(book.navigation.navPoints.single.label, 'Chapter title');
      expect(book.navigation.navPoints.single.content, '#heading-1');
    });

    test('resolves document relationships and exposes embedded media', () {
      final image = Uint8List.fromList(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      final book = parseDocxBook(
        _docxBytes(
          {
            'word/document.xml': _imageDocumentXml,
            'word/_rels/document.xml.rels': _relationshipsXml,
          },
          binaryEntries: <String, Uint8List>{'word/media/image1.png': image},
        ),
      );

      expect(book.files.images, hasLength(1));
      expect(book.files.images.single.path, 'word/media/image1.png');
      expect(book.files.images.single.content, orderedEquals(image));
      expect(book.cover?.content, orderedEquals(image));
      expect(book.metadata.cover?.type, ImageType.png);
      expect(book.files.html.single.content, contains('src="media/image1.png"'));
      expect(book.files.html.single.content, contains('alt="Cover illustration"'));
    });

    test('maps core properties into format-agnostic metadata', () {
      final metadata = readDocxMetadata(
        _docxBytes({
          'word/document.xml': _minimalDocumentXml,
          'docProps/core.xml': _corePropertiesXml,
        }),
      );

      expect(metadata.format, BookFormat.docx);
      expect(metadata.title, 'A DOCX title');
      expect(metadata.authors, ['Ada Lovelace', 'Grace Hopper']);
      expect(metadata.subjects, ['ebooks', 'parsing']);
      expect(metadata.description, 'A document description.');
      expect(metadata.languages, ['en-US']);
      expect(metadata.identifiers, {'identifier': 'urn:isbn:9780000000000'});
      expect(metadata.publishedAt, DateTime.utc(2024, 2, 3, 4, 5, 6));
    });

    test('does not normalize an invalid core-properties date', () {
      final metadata = readDocxMetadata(
        _docxBytes({
          'word/document.xml': _minimalDocumentXml,
          'docProps/core.xml': _corePropertiesXml.replaceFirst(
            '2024-02-03T04:05:06Z',
            '2024-02-31T04:05:06Z',
          ),
        }),
      );

      expect(metadata.publishedAt, isNull);
    });

    test('throws a typed error for a non-ZIP package', () {
      expect(
        () => parseDocxBook(Uint8List.fromList('not a docx'.codeUnits)),
        throwsA(isA<InvalidDocxPackageException>()),
      );
    });

    test('throws a typed error when the main document part is missing', () {
      expect(
        () => parseDocxBook(_docxBytes({'docProps/core.xml': _corePropertiesXml})),
        throwsA(
          isA<MissingDocxPartException>().having(
            (final error) => error.part,
            'part',
            'word/document.xml',
          ),
        ),
      );
    });

    test('throws a typed error when document.xml is malformed', () {
      expect(
        () => parseDocxBook(_docxBytes({'word/document.xml': '<w:document>'})),
        throwsA(isA<InvalidDocxXmlException>()),
      );
    });
  });
}

final String _documentXml = '''
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="HeadingCustom"/></w:pPr>
      <w:r><w:t>Chapter title</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:rPr><w:b/></w:rPr><w:t>bold</w:t></w:r>
      <w:r><w:rPr><w:i/></w:rPr><w:t>italic</w:t></w:r>
      <w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t>underlined</w:t></w:r>
      <w:r><w:rPr><w:u w:val="none"/></w:rPr><w:t>not underlined</w:t></w:r>
    </w:p>
    <w:p><w:r><w:t>before</w:t><w:br/><w:t>after</w:t></w:r></w:p>
    <w:p>
      <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
      <w:r><w:t>first item</w:t></w:r>
    </w:p>
    <w:p>
      <w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr>
      <w:r><w:t>second item</w:t></w:r>
    </w:p>
    <w:tbl>
      <w:tr>
        <w:tc><w:p><w:r><w:t>left</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>right</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
    <w:sectPr/>
  </w:body>
</w:document>
''';

const String _minimalDocumentXml = '''
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>Text</w:t></w:r></w:p><w:sectPr/></w:body>
</w:document>
''';

const String _stylesXml = '''
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="HeadingCustom">
    <w:name w:val="Heading 1"/>
  </w:style>
</w:styles>
''';

const String _numberingXml = '''
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:abstractNum w:abstractNumId="0">
    <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
  </w:abstractNum>
  <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
</w:numbering>
''';

const String _corePropertiesXml = '''
<cp:coreProperties
    xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:dcterms="http://purl.org/dc/terms/"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <dc:title>A DOCX title</dc:title>
  <dc:creator>Ada Lovelace; Grace Hopper</dc:creator>
  <dc:subject>ebooks, parsing</dc:subject>
  <dc:description>A document description.</dc:description>
  <dc:language>en-US</dc:language>
  <dc:identifier>urn:isbn:9780000000000</dc:identifier>
  <dcterms:created xsi:type="dcterms:W3CDTF">2024-02-03T04:05:06Z</dcterms:created>
</cp:coreProperties>
''';

const String _imageDocumentXml = '''
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
  <w:body>
    <w:p><w:r><w:drawing><wp:inline><wp:docPr id="1" name="Picture 1" descr="Cover illustration"/>
      <a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rId1"/></pic:blipFill></pic:pic></a:graphicData></a:graphic>
    </wp:inline></w:drawing></w:r></w:p>
    <w:sectPr/>
  </w:body>
</w:document>
''';

const String _relationshipsXml = '''
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1"
      Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
      Target="media/image1.png"/>
</Relationships>
''';

Uint8List _docxBytes(
  final Map<String, String> textEntries, {
  Map<String, Uint8List> binaryEntries = const <String, Uint8List>{},
}) {
  final archive = Archive();
  for (final entry in textEntries.entries) {
    final bytes = Uint8List.fromList(entry.value.codeUnits);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  for (final entry in binaryEntries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }

  return Uint8List.fromList(ZipEncoder().encode(archive));
}
