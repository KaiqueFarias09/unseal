@TestOn('browser')
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/epub.dart';
import 'package:unseal/src/platform/web/book_wire.dart';

void main() {
  test('Fixed-layout viewports, linearity, and rendition helpers survive the browser wire', () {
    final archive = Archive();
    void add(final String path, final String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add('META-INF/container.xml', '''
<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
    add('content.opf', '''
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Wire fixed layout</dc:title><dc:language>en</dc:language>
    <dc:identifier id="uid">urn:uuid:wire-fixed-layout</dc:identifier>
    <meta property="rendition:layout">pre-paginated</meta>
  </metadata>
  <manifest>
    <item id="p1" href="page1.xhtml" media-type="application/xhtml+xml"/>
    <item id="p2" href="page2.xhtml" media-type="application/xhtml+xml"/>
    <item id="p3" href="page3.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="p1"/>
    <itemref idref="p2" linear="no" properties="page-spread-left"/>
    <itemref idref="p3" properties="rendition:layout-reflowable"/>
  </spine>
</package>''');
    add('page1.xhtml', '''
<html xmlns="http://www.w3.org/1999/xhtml"><head>
<meta name="viewport" content="width=1200, height=1600"/></head>
<body><p>Page 1 of the wire fixture.</p></body></html>''');
    add('page2.xhtml', '''
<html xmlns="http://www.w3.org/1999/xhtml"><head>
<meta name="viewport" content="width=1200, height=1600"/></head>
<body><p>Page 2 of the wire fixture.</p></body></html>''');
    add('page3.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml"><body>Page 3.</body></html>');

    final book = parseEpubArchive(archive, rootFilePath: 'content.opf');
    expect(book.contentViewports, hasLength(2));
    expect(book.nonLinearSpinePaths, hasLength(1));

    // The JSON hop mirrors the structured-clone pass a worker payload
    // takes; blobs travel untouched.
    final (json, blobs) = encodeBookWire(book);
    final roundtrip = decodeBookWire(decodeJson(encodeJson(json)), blobs) as EpubBook;

    expect(roundtrip.contentViewports, {
      'page1.xhtml': const EpubViewport(width: 1200, height: 1600),
      'page2.xhtml': const EpubViewport(width: 1200, height: 1600),
    });
    expect(roundtrip.nonLinearSpinePaths, ['page2.xhtml']);
    expect(roundtrip.spineIdrefs, ['p1', 'p2', 'p3']);
    expect(roundtrip.spinePaths, ['page1.xhtml', 'page2.xhtml', 'page3.xhtml']);
    expect(roundtrip.layoutForSpineIndex(0), EpubLayout.prePaginated);
    expect(roundtrip.layoutForSpineIndex(2), EpubLayout.reflowable);
    expect(roundtrip.pageSpreadForSpineIndex(1), EpubPageSpread.left);
    expect(roundtrip.spineItemIsLinear(0), isTrue);
    expect(roundtrip.spineItemIsLinear(1), isFalse);
    expect(roundtrip.viewportForSpineIndex(2), isNull);
  });
}
