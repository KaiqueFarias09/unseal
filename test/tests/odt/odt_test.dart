import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/src/features/odt/exceptions/exceptions.dart';
import 'package:e_livre/src/features/odt/utils/parse_odt_book.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:test/test.dart';

void main() {
  test('renders ODT headings, inline styles, lists, tables and images', () {
    final book = parseOdtBook(_odtBytes());

    expect(book, isA<DocumentBook>());
    expect(book.format, BookFormat.odt);
    expect(book.metadata.title, 'ODT title');
    expect(book.metadata.authors, ['Ada Lovelace']);
    expect(book.metadata.languages, ['en-US']);
    expect(book.metadata.subjects, ['ebooks', 'parsing']);
    expect(book.metadata.bookProducer, 'LibreOffice');
    expect(book.metadata.publishedAt, DateTime.utc(2024, 3, 4, 5, 6, 7));
    expect(book.files.images.single.path, 'Pictures/cover.png');
    expect(book.metadata.cover, isNotNull);

    final content = book.files.html.single.content;
    expect(content, contains('<h1>Chapter one</h1>'));
    expect(content, contains('<strong>bold</strong>'));
    expect(content, contains('before<br/>after'));
    expect(content, contains('<ol><li><p>first item</p></li></ol>'));
    expect(content, contains('<table><tbody><tr><td><p>left</p></td>'));
    expect(content, contains('src="Pictures/cover.png"'));
    expect(book.navigation.navPoints.single.label, 'Chapter one');
    expect(book.readingOrder.single.name, 'content.xhtml');
  });

  test('reads metadata without rendering the ODT body', () {
    final metadata = readOdtMetadata(_odtBytes());

    expect(metadata.format, BookFormat.odt);
    expect(metadata.title, 'ODT title');
    expect(metadata.authors, ['Ada Lovelace']);
    expect(metadata.publisher, 'Open Publisher');
  });

  test('rejects a package without content.xml', () {
    final archive = Archive()..addFile(ArchiveFile('meta.xml', 4, utf8.encode('<meta/>')));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);

    expect(
      () => parseOdtBook(bytes),
      throwsA(
        isA<MissingOdtPartException>().having((final error) => error.part, 'part', 'content.xml'),
      ),
    );
  });
}

Uint8List _odtBytes() {
  final archive = Archive()
    ..addFile(ArchiveFile('mimetype', 39, utf8.encode('application/vnd.oasis.opendocument.text')))
    ..addFile(ArchiveFile('content.xml', _contentXml.length, utf8.encode(_contentXml)))
    ..addFile(ArchiveFile('meta.xml', _metaXml.length, utf8.encode(_metaXml)))
    ..addFile(ArchiveFile('styles.xml', _stylesXml.length, utf8.encode(_stylesXml)))
    ..addFile(ArchiveFile('Pictures/cover.png', _png.length, _png));

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

const _contentXml = '''<?xml version="1.0" encoding="UTF-8"?>
<office:document-content
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0"
    xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    xmlns:xlink="http://www.w3.org/1999/xlink"
    xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
    xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0">
  <office:automatic-styles>
    <style:style style:name="Tbold" style:family="text">
      <style:text-properties fo:font-weight="bold"/>
    </style:style>
    <text:list-style style:name="Lnumber">
      <text:list-level-style-number text:level="1" style:num-format="1"/>
    </text:list-style>
  </office:automatic-styles>
  <office:body><office:text>
    <text:h text:outline-level="1">Chapter one</text:h>
    <text:p>before<text:line-break/>after <text:span text:style-name="Tbold">bold</text:span>
      <draw:frame draw:name="Cover"><draw:image xlink:href="Pictures/cover.png"/></draw:frame>
    </text:p>
    <text:list text:style-name="Lnumber"><text:list-item><text:p>first item</text:p></text:list-item></text:list>
    <table:table><table:table-row>
      <table:table-cell><text:p>left</text:p></table:table-cell>
      <table:table-cell><text:p>right</text:p></table:table-cell>
    </table:table-row></table:table>
  </office:text></office:body>
</office:document-content>''';

const _stylesXml = '''<office:document-styles
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0">
</office:document-styles>''';

const _metaXml = '''<?xml version="1.0" encoding="UTF-8"?>
<office:document-meta
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0">
  <office:meta>
    <dc:title>ODT title</dc:title>
    <meta:initial-creator>Ada Lovelace</meta:initial-creator>
    <dc:language>en-US</dc:language>
    <dc:subject>ebooks</dc:subject>
    <meta:keyword>parsing</meta:keyword>
    <dc:publisher>Open Publisher</dc:publisher>
    <meta:generator>LibreOffice</meta:generator>
    <meta:creation-date>2024-03-04T05:06:07Z</meta:creation-date>
  </office:meta>
</office:document-meta>''';

final Uint8List _png = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);
