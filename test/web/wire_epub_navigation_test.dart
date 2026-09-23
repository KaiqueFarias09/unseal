@TestOn('browser')
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/epub.dart';
import 'package:unseal/src/platform/web/book_wire.dart';

void main() {
  test('EPUB page list and landmark types survive the browser wire', () {
    final archive = Archive();
    void add(final String path, final String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add('content.opf', '''
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Wire navigation</dc:title><dc:language>en</dc:language>
    <dc:identifier id="uid">urn:uuid:wire-navigation</dc:identifier>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine><itemref idref="chapter"/></spine>
</package>''');
    add('chapter.xhtml', '<html xmlns="http://www.w3.org/1999/xhtml"><body>Text</body></html>');
    add('nav.xhtml', '''
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
  <nav epub:type="toc"><ol><li><a href="chapter.xhtml">Chapter</a></li></ol></nav>
  <nav epub:type="page-list"><ol><li><a href="chapter.xhtml#page-7">7</a></li></ol></nav>
  <nav epub:type="landmarks"><ol><li><a epub:type="bodymatter" href="chapter.xhtml">Start</a></li></ol></nav>
</body></html>''');

    final book = parseEpubArchive(archive, rootFilePath: 'content.opf');
    final (json, blobs) = encodeBookWire(book);
    final roundtrip = decodeBookWire(decodeJson(encodeJson(json)), blobs) as EpubBook;

    expect(roundtrip.navigation.navPoints.single.label, 'Chapter');
    expect(roundtrip.pageList?.navPoints.single.label, '7');
    expect(roundtrip.pageList?.navPoints.single.content, 'chapter.xhtml#page-7');
    expect(roundtrip.landmarks.single.label, 'Start');
    expect(roundtrip.landmarks.single.href, 'chapter.xhtml');
    expect(roundtrip.landmarks.single.types, ['bodymatter']);
  });
}
