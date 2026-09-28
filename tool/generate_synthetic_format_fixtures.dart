import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:koni_archive/koni_archive.dart' as koni;

import '../test/tests/mobi/mobi_fixture_builder.dart' as mobi_fixtures;
import '../test/tests/pdf/pdf_fixture_builder.dart' as pdf_fixtures;

const _booksDirectory = 'test/resources/books';
const _comicDirectory = '$_booksDirectory/comic';

Future<void> main() async {
  final directory = Directory(_comicDirectory)..createSync(recursive: true);
  File('${directory.path}/synthetic-pages.cbz').writeAsBytesSync(_buildCbz(), flush: true);
  File('${directory.path}/synthetic-stored-pages.cbr').writeAsBytesSync(_buildCbr(), flush: true);

  _writeText('txt/synthetic.txt', '''unseal TXT Fixture


Ada Lovelace

This is a deterministic plain-text fixture.
It keeps paragraph boundaries and Unicode: café, 漢字.
''');
  _writeText('html/synthetic.html', '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>unseal HTML Fixture</title></head>
<body><h1>HTML chapter</h1><p>A deterministic HTML fixture.</p></body></html>
''');
  _writeBytes('txt/synthetic.txtz', _buildTxtz());
  _writeBytes('html/synthetic.htmlz', _buildHtmlz());
  _writeBytes('docx/synthetic.docx', _buildDocx());
  _writeBytes('odt/synthetic.odt', _buildOdt());

  final azw4 = mobi_fixtures.buildPdb('Synthetic AZW4 fixture', <Uint8List>[
    mobi_fixtures.buildMobiRecord0(title: 'AZW4 fixture'),
    pdf_fixtures.textPageFixture().build(),
  ]);
  _writeBytes('mobi/synthetic.azw4', azw4);

  final cb7 = await _buildCb7();
  _writeBytes('comic/synthetic-pages.cb7', cb7);
  _writeBytes('comic/synthetic-collection.cbc', _buildCbc(cb7));

  final fxlBooks = buildFxlEpubFixtures();
  for (final entry in fxlBooks.entries) {
    _writeBytes('epub/${entry.key}', entry.value);
  }
}

void _writeText(final String relativePath, final String value) {
  _writeBytes(relativePath, Uint8List.fromList(utf8.encode(value)));
}

void _writeBytes(final String relativePath, final Uint8List bytes) {
  final file = File('$_booksDirectory/$relativePath');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes, flush: true);
}

Uint8List _zip(final Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = Uint8List.fromList(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes)..lastModTime = 946684800);
  }

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _buildTxtz() {
  const metadata = '''<?xml version="1.0" encoding="utf-8"?>
<package><metadata>
  <title>unseal TXTZ Fixture</title>
  <creator>Ada Lovelace</creator>
  <language>en</language>
  <subject>text parsing</subject>
  <meta name="text-formatting" content="markdown"/>
  <meta name="cover" content="cover"/>
</metadata><manifest>
  <item id="cover" href="cover.png" properties="cover-image"/>
</manifest></package>''';
  const chapter = '''# TXTZ chapter

This is **Markdown** inside a TXTZ archive.
''';

  return _zip(<String, List<int>>{
    'metadata.opf': utf8.encode(metadata),
    'chapter1.txt': utf8.encode(chapter),
    'chapter10.txt': utf8.encode('The second deterministic chapter.'),
    'cover.png': mobi_fixtures.tinyPng,
    'styles/book.css': utf8.encode('body { font-family: sans-serif; }'),
  });
}

Uint8List _buildHtmlz() {
  const html = '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>HTML fallback title</title></head>
<body><h1>HTMLZ chapter</h1><p>Archive-backed HTML.</p></body></html>''';
  const metadata = '''<?xml version="1.0" encoding="utf-8"?>
<package><metadata>
  <dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">unseal HTMLZ Fixture</dc:title>
  <dc:creator xmlns:dc="http://purl.org/dc/elements/1.1/">Grace Hopper</dc:creator>
  <dc:language xmlns:dc="http://purl.org/dc/elements/1.1/">en</dc:language>
</metadata><manifest>
  <item id="cover" href="images/cover.png" properties="cover-image"/>
</manifest></package>''';

  return _zip(<String, List<int>>{
    'index.html': utf8.encode(html),
    'metadata.opf': utf8.encode(metadata),
    'images/cover.png': mobi_fixtures.tinyPng,
    'styles/main.css': utf8.encode('h1 { color: black; }'),
    'notes.txt': utf8.encode('retained as a resource'),
  });
}

Uint8List _buildDocx() {
  const document = '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>DOCX chapter</w:t></w:r></w:p>
    <w:p><w:r><w:t>A deterministic Open XML document.</w:t></w:r></w:p>
    <w:sectPr/>
  </w:body>
</w:document>''';
  const core = '''<?xml version="1.0" encoding="UTF-8"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:title>unseal DOCX Fixture</dc:title>
  <dc:creator>Ada Lovelace</dc:creator>
  <dc:language>en</dc:language>
</cp:coreProperties>''';
  const styles =
      '''<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="Heading 1"/></w:style>
</w:styles>''';

  return _zip(<String, List<int>>{
    'word/document.xml': utf8.encode(document),
    'word/styles.xml': utf8.encode(styles),
    'docProps/core.xml': utf8.encode(core),
  });
}

Uint8List _buildOdt() {
  const content = '''<?xml version="1.0" encoding="UTF-8"?>
<office:document-content
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
  <office:body><office:text>
    <text:h text:outline-level="1">ODT chapter</text:h>
    <text:p>A deterministic OpenDocument text file.</text:p>
  </office:text></office:body>
</office:document-content>''';
  const metadata = '''<?xml version="1.0" encoding="UTF-8"?>
<office:document-meta
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0">
  <office:meta><dc:title>unseal ODT Fixture</dc:title>
    <meta:initial-creator>Grace Hopper</meta:initial-creator>
    <dc:language>en</dc:language>
  </office:meta>
</office:document-meta>''';

  return _zip(<String, List<int>>{
    'mimetype': utf8.encode('application/vnd.oasis.opendocument.text'),
    'content.xml': utf8.encode(content),
    'meta.xml': utf8.encode(metadata),
  });
}

Future<Uint8List> _buildCb7() async {
  final sink = koni.BytesBuilderSink();
  final writer = koni.Archive.create(sink, format: const koni.SevenZWriteFormat());
  await writer.addBytes(koni.ArchiveEntrySpec(path: '001/page1.png'), mobi_fixtures.tinyPng);
  const comicInfo =
      '<ComicInfo><Title>unseal CB7 Fixture</Title>'
      '<Writer>unseal contributors</Writer><LanguageISO>mul</LanguageISO></ComicInfo>';

  await writer.addBytes(
    koni.ArchiveEntrySpec(path: 'ComicInfo.xml'),
    Uint8List.fromList(utf8.encode(comicInfo)),
  );
  await writer.close();
  await sink.close();

  return sink.takeBytes();
}

Uint8List _buildCbc(final Uint8List cb7) {
  return _zip(<String, List<int>>{
    'comics.txt': utf8.encode('first.cb7:First collection title\nsecond.cb7:Second title\n'),
    'first.cb7': cb7,
    'second.cb7': cb7,
  });
}

Uint8List _buildCbz() {
  const comicInfo = '''
<?xml version="1.0"?>
<ComicInfo>
  <Title>unseal Synthetic Comic</Title>
  <Series>Parser Fixtures</Series>
  <Number>1</Number>
  <Writer>unseal contributors</Writer>
  <LanguageISO>mul</LanguageISO>
  <Summary>Generated test data with no third-party creative content.</Summary>
</ComicInfo>
''';
  final png = base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
  );
  final archive = Archive()
    ..addFile(_archiveFile('002.png', png))
    ..addFile(_archiveFile('001.png', png))
    ..addFile(_archiveFile('ComicInfo.xml', utf8.encode(comicInfo)));

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

ArchiveFile _archiveFile(final String name, final List<int> bytes) {
  return ArchiveFile(name, bytes.length, bytes)..lastModTime = 946684800;
}

void _addStoredCbrFile(final BytesBuilder builder, final String name, final List<int> data) {
  final nameBytes = ascii.encode(name);
  final headerSize = 32 + nameBytes.length;
  final header = ByteData(headerSize);
  var offset = 2; // Header CRC is intentionally unchecked by the fixture reader.
  header.setUint8(offset, 0x74);
  offset += 1;
  header.setUint16(offset, 0x8000, Endian.little);
  offset += 2;
  header.setUint16(offset, headerSize, Endian.little);
  offset += 2;
  header.setUint32(offset, data.length, Endian.little);
  offset += 4;
  header.setUint32(offset, data.length, Endian.little);
  offset += 4;
  header.setUint8(offset, 0);
  offset += 1;
  offset += 8; // File CRC and DOS timestamp.
  header.setUint8(offset, 29);
  offset += 1;
  header.setUint8(offset, 0x30); // Stored, not compressed.
  offset += 1;
  header.setUint16(offset, nameBytes.length, Endian.little);
  offset += 2;
  header.setUint32(offset, 0x20, Endian.little);
  offset += 4;
  header.buffer.asUint8List().setRange(offset, offset + nameBytes.length, nameBytes);
  builder
    ..add(header.buffer.asUint8List())
    ..add(data);
}

Uint8List _buildCbr() {
  final builder = BytesBuilder(copy: false)..add(const [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]);

  _addStoredCbrFile(builder, '002.jpg', const [0xFF, 0xD8, 0xFF, 0xE0, 4, 5, 6]);
  _addStoredCbrFile(builder, '001.jpg', const [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]);

  final end = ByteData(7)
    ..setUint8(2, 0x7B)
    ..setUint16(3, 0x4000, Endian.little)
    ..setUint16(5, 7, Endian.little);
  builder.add(end.buffer.asUint8List());

  return builder.takeBytes();
}

/// One EPUB content document: a manifest item and its file body.
final class _EpubContent {
  const _EpubContent({
    required this.id,
    required this.href,
    required this.mediaType,
    required this.bytes,
    this.properties,
    this.mediaOverlay,
  });

  final String id;
  final String href;
  final String mediaType;
  final List<int> bytes;
  final String? properties;
  final String? mediaOverlay;
}

/// One `<itemref>` of the spine.
final class _EpubSpineItem {
  const _EpubSpineItem(this.idref, {this.properties, this.linear = 'yes'});

  final String idref;
  final String? properties;
  final String linear;
}

/// Viewport `content` attribute of a fixed-layout XHTML page.
String _vp(final int width, final int height) => 'width=$width, height=$height';

/// Builds the thirteen deterministic EPUB fixed-layout fixtures under
/// `test/resources/books/epub/`.
///
/// Every book is a few kilobytes, uses only generated prose (no
/// third-party content), pins its zip entry dates like the other
/// synthetic fixtures, and prints visible page numbers so rendered
/// screenshots stay verifiable. The generator rewrites files in place;
/// byte stability across runs keeps the books manifest hashes valid.
Map<String, Uint8List> buildFxlEpubFixtures() {
  return <String, Uint8List>{
    'fxl-xhtml-viewport.epub': _epub(
      slug: 'xhtml-viewport',
      title: 'unseal FXL XHTML Viewport Fixture',
      renditionMetadata: '<meta property="rendition:layout">pre-paginated</meta>',
      content: [
        for (var page = 1; page <= 3; page++)
          _xhtmlPage(id: 'p$page', href: 'page$page.xhtml', number: page),
      ],
      spine: const [_EpubSpineItem('p1'), _EpubSpineItem('p2'), _EpubSpineItem('p3')],
    ),
    'fxl-spread-hints.epub': _epub(
      slug: 'spread-hints',
      title: 'unseal FXL Spread Hints Fixture',
      renditionMetadata:
          '<meta property="rendition:layout">pre-paginated</meta>'
          '<meta property="rendition:spread">both</meta>',
      content: [
        for (var page = 1; page <= 5; page++)
          _xhtmlPage(id: 'p$page', href: 'page$page.xhtml', number: page, viewport: _vp(800, 1200)),
      ],
      spine: const [
        _EpubSpineItem('p1', properties: 'page-spread-left'),
        _EpubSpineItem('p2', properties: 'page-spread-right'),
        _EpubSpineItem('p3', properties: 'rendition:page-spread-center'),
        _EpubSpineItem('p4'),
        _EpubSpineItem('p5'),
      ],
    ),
    'fxl-spread-portrait.epub': _epub(
      slug: 'spread-portrait',
      title: 'unseal FXL Portrait Spread Fixture',
      renditionMetadata:
          '<meta property="rendition:layout">pre-paginated</meta>'
          '<meta property="rendition:spread">portrait</meta>',
      content: [
        for (var page = 1; page <= 4; page++)
          _xhtmlPage(id: 'p$page', href: 'page$page.xhtml', number: page, viewport: _vp(900, 1300)),
      ],
      spine: const [
        _EpubSpineItem('p1'),
        _EpubSpineItem('p2'),
        _EpubSpineItem('p3'),
        _EpubSpineItem('p4'),
      ],
    ),
    'fxl-rtl.epub': _epub(
      slug: 'rtl',
      title: 'unseal FXL Right-to-Left Fixture',
      language: 'ar',
      renditionMetadata: '<meta property="rendition:layout">pre-paginated</meta>',
      pageProgressionDirection: 'rtl',
      content: [
        for (var page = 1; page <= 4; page++)
          _xhtmlPage(
            id: 'p$page',
            href: 'page$page.xhtml',
            number: page,
            lang: 'ar',
            viewport: _vp(1000, 1400),
            heading: 'صفحة ثابتة',
          ),
      ],
      spine: const [
        _EpubSpineItem('p1', properties: 'page-spread-right'),
        _EpubSpineItem('p2'),
        _EpubSpineItem('p3'),
        _EpubSpineItem('p4'),
      ],
    ),
    'fxl-orientation.epub': _epub(
      slug: 'orientation',
      title: 'unseal FXL Orientation Fixture',
      renditionMetadata:
          '<meta property="rendition:layout">pre-paginated</meta>'
          '<meta property="rendition:orientation">landscape</meta>',
      content: [
        for (var page = 1; page <= 3; page++)
          _xhtmlPage(id: 'p$page', href: 'page$page.xhtml', number: page, viewport: _vp(1600, 900)),
      ],
      spine: const [
        _EpubSpineItem('p1'),
        _EpubSpineItem('p2', properties: 'rendition:orientation-portrait'),
        _EpubSpineItem('p3'),
      ],
    ),
    'fxl-mixed-fixed-override.epub': _epub(
      slug: 'mixed-fixed-override',
      title: 'unseal FXL Mixed Fixed Override Fixture',
      content: [
        _xhtmlPage(id: 'p1', href: 'prose1.xhtml', number: 1, prose: true, viewport: null),
        _xhtmlPage(id: 'p2', href: 'fixed2.xhtml', number: 2, viewport: _vp(1000, 1400)),
        _xhtmlPage(id: 'p3', href: 'prose3.xhtml', number: 3, prose: true, viewport: null),
        _xhtmlPage(id: 'p4', href: 'fixed4.xhtml', number: 4, viewport: _vp(1000, 1400)),
      ],
      spine: const [
        _EpubSpineItem('p1'),
        _EpubSpineItem('p2', properties: 'rendition:layout-pre-paginated'),
        _EpubSpineItem('p3'),
        _EpubSpineItem('p4', properties: 'rendition:layout-pre-paginated'),
      ],
    ),
    'fxl-mixed-reflow-override.epub': _epub(
      slug: 'mixed-reflow-override',
      title: 'unseal FXL Mixed Reflow Override Fixture',
      renditionMetadata: '<meta property="rendition:layout">pre-paginated</meta>',
      content: [
        _xhtmlPage(id: 'p1', href: 'page1.xhtml', number: 1),
        _xhtmlPage(id: 'p2', href: 'page2.xhtml', number: 2, prose: true, viewport: null),
        _xhtmlPage(id: 'p3', href: 'page3.xhtml', number: 3),
      ],
      spine: const [
        _EpubSpineItem('p1'),
        _EpubSpineItem('p2', properties: 'rendition:layout-reflowable'),
        _EpubSpineItem('p3'),
      ],
    ),
    'fxl-svg.epub': _epub(
      slug: 'svg',
      title: 'unseal FXL SVG Content Fixture',
      renditionMetadata: '<meta property="rendition:layout">pre-paginated</meta>',
      content: [
        _svgPage(id: 'svg1', href: 'page1.svg', number: 1),
        _svgPage(id: 'svg2', href: 'page2.svg', number: 2),
        _xhtmlPage(
          id: 'p3',
          href: 'page3.xhtml',
          number: 3,
          bodyExtra:
              '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="200" '
              'viewBox="0 0 600 200"><text x="40" y="120" font-size="40">'
              'Inline SVG frame</text></svg>',
        ),
      ],
      spine: const [_EpubSpineItem('svg1'), _EpubSpineItem('svg2'), _EpubSpineItem('p3')],
    ),
    'fxl-nonlinear.epub': _epub(
      slug: 'nonlinear',
      title: 'unseal FXL Non-linear Fixture',
      renditionMetadata: '<meta property="rendition:layout">pre-paginated</meta>',
      content: [
        _xhtmlPage(
          id: 'p1',
          href: 'page1.xhtml',
          number: 1,
          bodyExtra:
              '<p>Detours: <a href="page2.xhtml">a footnote page</a> and '
              '<a href="page3.xhtml">a plate page</a> stay outside the linear flow.</p>',
        ),
        _xhtmlPage(id: 'p2', href: 'page2.xhtml', number: 2),
        _xhtmlPage(id: 'p3', href: 'page3.xhtml', number: 3),
      ],
      spine: const [
        _EpubSpineItem('p1'),
        _EpubSpineItem('p2', linear: 'no'),
        _EpubSpineItem('p3', linear: 'no'),
      ],
    ),
    'fxl-repeated-spine.epub': _epub(
      slug: 'repeated-spine',
      title: 'unseal FXL Repeated Spine Fixture',
      renditionMetadata: '<meta property="rendition:layout">pre-paginated</meta>',
      content: [
        _xhtmlPage(id: 'shared', href: 'shared.xhtml', number: 1),
        _xhtmlPage(id: 'other', href: 'other.xhtml', number: 2),
      ],
      spine: const [_EpubSpineItem('shared'), _EpubSpineItem('other'), _EpubSpineItem('shared')],
    ),
    'fxl-overlays.epub': _epub(
      slug: 'overlays',
      title: 'unseal FXL Media Overlays Fixture',
      renditionMetadata: '<meta property="rendition:layout">pre-paginated</meta>',
      metadataExtras:
          '<meta property="media:active-class">-epub-media-overlay-active</meta>'
          '<meta property="media:duration" refines="#overlay1">0:00:04.000</meta>',
      content: [
        _xhtmlPage(
          id: 'p1',
          href: 'page1.xhtml',
          number: 1,
          bodyExtra:
              '<p id="s1">Sentence one of the first fixed page.</p>'
              '<p id="s2">Sentence two carries its own narration clip.</p>',
          mediaOverlay: 'overlay1',
        ),
        _xhtmlPage(
          id: 'p2',
          href: 'page2.xhtml',
          number: 2,
          textFree: true,
          bodyExtra: '<img src="plate.png" alt="A full-page plate without text"/>',
          mediaOverlay: 'overlay1',
        ),
        _EpubContent(
          id: 'plate-image',
          href: 'plate.png',
          mediaType: 'image/png',
          bytes: mobi_fixtures.tinyPng,
        ),
        _EpubContent(
          id: 'overlay1',
          href: 'overlay1.smil',
          mediaType: 'application/smil+xml',
          bytes: _utf8Bytes('''
<?xml version="1.0" encoding="utf-8"?>
<smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
  <body>
    <seq id="s1" epub:textref="page1.xhtml">
      <par id="sentence1">
        <text src="page1.xhtml#s1"/><audio src="audio/narration.mp3" clipBegin="0s" clipEnd="2s"/>
      </par>
      <par id="sentence2">
        <text src="page1.xhtml#s2"/><audio src="audio/narration.mp3" clipBegin="2s" clipEnd="4s"/>
      </par>
    </seq>
  </body>
</smil>
'''),
        ),
      ],
      spine: const [_EpubSpineItem('p1'), _EpubSpineItem('p2')],
    ),
    'fxl-scripted.epub': _epub(
      slug: 'scripted',
      title: 'unseal FXL Scripted Fixture',
      renditionMetadata: '<meta property="rendition:layout">pre-paginated</meta>',
      content: [
        _xhtmlPage(id: 'p1', href: 'page1.xhtml', number: 1),
        _xhtmlPage(
          id: 'p2',
          href: 'page2.xhtml',
          number: 2,
          properties: 'scripted',
          bodyExtra:
              '<script type="application/javascript">'
              "document.body.setAttribute('data-script-ran', 'yes');"
              '</script>',
        ),
      ],
      spine: const [_EpubSpineItem('p1'), _EpubSpineItem('p2')],
    ),
    'fxl-viewport-quirks.epub': _epub(
      slug: 'viewport-quirks',
      title: 'unseal FXL Viewport Quirks Fixture',
      renditionMetadata: '<meta property="rendition:layout">pre-paginated</meta>',
      content: [
        _xhtmlPage(id: 'p1', href: 'no-viewport.xhtml', number: 1, viewport: null),
        _xhtmlPage(id: 'p2', href: 'malformed.xhtml', number: 2, viewport: 'width=abc, height=0'),
        _xhtmlPage(
          id: 'p3',
          href: 'oversized.xhtml',
          number: 3,
          viewport: 'width=25000, height=30000',
        ),
        _xhtmlPage(id: 'p4', href: 'valid.xhtml', number: 4, viewport: _vp(900, 1200)),
      ],
      spine: const [
        _EpubSpineItem('p1'),
        _EpubSpineItem('p2'),
        _EpubSpineItem('p3'),
        _EpubSpineItem('p4'),
      ],
    ),
  };
}

const _fxlProse =
    'The fixed page keeps its geometry while the reader turns it. '
    'Every sentence stays inside the declared viewport. '
    'A reader that honors the layout never reflows this text.';

List<int> _utf8Bytes(final String value) => value.codeUnits;

_EpubContent _xhtmlPage({
  required final String id,
  required final String href,
  required final int number,
  final String lang = 'en',
  final String? properties,
  final String? mediaOverlay,
  final String? viewport = _defaultViewport,
  final bool prose = false,
  final bool textFree = false,
  final String heading = 'Fixed Page',
  final String? bodyExtra,
}) {
  final meta = viewport == null ? '' : '<meta name="viewport" content="$viewport"/>';
  final body = StringBuffer();
  if (!textFree) {
    body
      ..write('<h1>$heading $number</h1>')
      ..write(
        prose
            ? '<p>Reflowable prose follows the reading system layout instead of a '
                  'declared page geometry. The folio still reads Page $number.</p>'
            : '<p>Page $number. $_fxlProse</p>',
      )
      ..write('<p class="folio">Page $number.</p>');
  }
  body.write(bodyExtra ?? '');

  return _EpubContent(
    id: id,
    href: href,
    mediaType: 'application/xhtml+xml',
    properties: properties,
    mediaOverlay: mediaOverlay,
    bytes: _utf8Bytes('''
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="$lang">
<head>${textFree ? '' : '<title>$heading $number</title>'}$meta</head>
<body>
${body.toString()}
</body>
</html>
'''),
  );
}

const _defaultViewport = 'width=1200, height=1600';

_EpubContent _svgPage({
  required final String id,
  required final String href,
  required final int number,
}) {
  return _EpubContent(
    id: id,
    href: href,
    mediaType: 'image/svg+xml',
    bytes: _utf8Bytes('''
<?xml version="1.0" encoding="utf-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="1600" viewBox="0 0 1200 1600">
  <rect x="0" y="0" width="1200" height="1600" fill="white"/>
  <text x="120" y="240" font-size="64">Fixed Page $number</text>
  <text x="120" y="320" font-size="32">Page $number of the SVG fixed layout.</text>
</svg>
'''),
  );
}

Uint8List _epub({
  required final String slug,
  required final String title,
  final String language = 'en',
  final String renditionMetadata = '',
  final String metadataExtras = '',
  final String pageProgressionDirection = 'ltr',
  required final List<_EpubContent> content,
  required final List<_EpubSpineItem> spine,
}) {
  const opfPath = 'OEBPS/content.opf';
  const navPath = 'OEBPS/nav.xhtml';

  final manifestItems = StringBuffer()
    ..write(
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
    );
  for (final item in content) {
    manifestItems.write('<item id="${item.id}" href="${item.href}" media-type="${item.mediaType}"');
    if (item.properties != null) manifestItems.write(' properties="${item.properties}"');
    if (item.mediaOverlay != null) manifestItems.write(' media-overlay="${item.mediaOverlay}"');
    manifestItems.write('/>');
  }

  final itemrefs = StringBuffer();
  for (final item in spine) {
    itemrefs.write('<itemref idref="${item.idref}"');
    if (item.linear != 'yes') itemrefs.write(' linear="${item.linear}"');
    if (item.properties != null) itemrefs.write(' properties="${item.properties}"');
    itemrefs.write('/>');
  }

  final navList = StringBuffer();
  for (final item in content.where(
    (final candidate) => candidate.mediaType == 'application/xhtml+xml',
  )) {
    navList.write('<li><a href="${item.href}">${item.id}</a></li>');
  }

  final opf =
      '''
<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="$language">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:unseal-fxl-$slug</dc:identifier>
    <dc:title>$title</dc:title>
    <dc:language>$language</dc:language>
    <dc:creator>unseal contributors</dc:creator>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
    $renditionMetadata
    $metadataExtras
  </metadata>
  <manifest>$manifestItems</manifest>
  <spine${pageProgressionDirection.isEmpty ? '' : ' page-progression-direction="$pageProgressionDirection"'}>$itemrefs</spine>
</package>
''';

  final entries = <String, List<int>>{
    'mimetype': 'application/epub+zip'.codeUnits,
    'META-INF/container.xml': _utf8Bytes('''
<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="$opfPath" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
'''),
    opfPath: _utf8Bytes(opf),
    navPath: _utf8Bytes('''
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Navigation</title></head>
<body>
  <nav epub:type="toc"><ol>${navList.toString()}</ol></nav>
</body>
</html>
'''),
  };
  for (final item in content) {
    final name = 'OEBPS/${item.href}';
    if (entries.containsKey(name)) {
      throw ArgumentError('duplicate EPUB entry $name');
    }
    entries[name] = item.bytes;
  }

  return _zip(entries);
}
