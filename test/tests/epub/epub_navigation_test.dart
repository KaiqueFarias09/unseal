import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/epub.dart';

void main() {
  test('EPUB 3 nav wins over NCX and exposes page list and typed landmarks', () {
    final book = _book(nav: _navWithSections, ncx: _ncx);

    expect(book.navigation.navPoints.single.label, 'Chapter from nav');
    expect(book.pageList?.navPoints.map((final point) => (point.label, point.content)), [
      ('i', 'chapter.xhtml#front'),
      ('1', 'chapter.xhtml#page-1'),
    ]);
    expect(book.landmarks, hasLength(2));
    expect(book.landmarks.first, isA<EpubLandmark>());
    expect(book.landmarks.first.label, 'Cover');
    expect(book.landmarks.first.href, 'cover.xhtml');
    expect(book.landmarks.first.types, ['cover']);
    expect(book.landmarks.last.types, ['bodymatter', 'z3998:fiction']);
  });

  test('falls back to NCX without confusing a page list with the TOC', () {
    final book = _book(
      nav: '''
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Pages only</title></head><body>
    <nav epub:type="page-list"><ol><li><a href="chapter.xhtml#page-1">1</a></li></ol></nav>
  </body>
</html>''',
      ncx: _ncx,
    );

    expect(book.navigation.navPoints.single.label, 'Chapter from NCX');
    expect(book.pageList?.navPoints.single.label, '1');
    expect(book.landmarks, isEmpty);
  });

  test('EPUB 2 continues to prefer NCX when both resources exist', () {
    final book = _book(nav: _navWithSections, ncx: _ncx, version: '2.0');

    expect(book.navigation.navPoints.single.label, 'Chapter from NCX');
  });

  test('an EPUB 3 nav without a page list keeps it absent', () {
    final book = _book(
      nav: '''
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">Chapter</a></li></ol></nav></body>
</html>''',
    );

    expect(book.navigation.navPoints.single.label, 'Chapter');
    expect(book.pageList, isNull);
    expect(book.landmarks, isEmpty);
  });

  test('keeps an untyped legacy nav as a TOC fallback', () {
    final book = _book(
      nav: '''
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <nav><ol><li><a href="chapter.xhtml">Legacy nav</a></li></ol></nav>
</body></html>''',
    );

    expect(book.navigation.navPoints.single.label, 'Legacy nav');
  });
}

EpubBook _book({required final String nav, final String? ncx, final String version = '3.0'}) {
  const chapter = '<html xmlns="http://www.w3.org/1999/xhtml"><body>Text</body></html>';
  final opf =
      '''
<package xmlns="http://www.idpf.org/2007/opf" version="$version" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Navigation test</dc:title><dc:language>en</dc:language>
    <dc:identifier id="uid">urn:uuid:navigation-test</dc:identifier>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    ${ncx == null ? '' : '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'}
  </manifest>
  <spine ${ncx == null ? '' : 'toc="ncx"'}><itemref idref="chapter"/></spine>
</package>''';
  final archive = Archive();
  void add(final String path, final String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add('content.opf', opf);
  add('chapter.xhtml', chapter);
  add('nav.xhtml', nav);
  if (ncx != null) add('toc.ncx', ncx);
  return parseEpubArchive(archive, rootFilePath: 'content.opf');
}

const _navWithSections = '''
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:ops="http://www.idpf.org/2007/ops">
  <head><title>Navigation document</title></head><body>
    <nav ops:type="landmarks"><h2>Landmarks</h2><ol>
      <li><a ops:type="cover" href="cover.xhtml">Cover</a></li>
      <li><a ops:type="bodymatter z3998:fiction" href="chapter.xhtml">Start reading</a></li>
    </ol></nav>
    <nav ops:type="page-list"><h2>Pages</h2><ol>
      <li><a href="chapter.xhtml#front">i</a></li>
      <li><a href="chapter.xhtml#page-1">1</a></li>
    </ol></nav>
    <nav ops:type="toc"><h2>Contents</h2><ol>
      <li><a href="chapter.xhtml">Chapter from nav</a></li>
    </ol></nav>
  </body>
</html>''';

const _ncx = '''
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/">
  <docTitle><text>Legacy contents</text></docTitle><navMap>
    <navPoint id="chapter"><navLabel><text>Chapter from NCX</text></navLabel>
      <content src="chapter.xhtml"/>
    </navPoint>
  </navMap>
</ncx>''';
