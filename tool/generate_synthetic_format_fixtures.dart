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

  _writeText('txt/synthetic.txt', '''eLivre TXT Fixture


Ada Lovelace

This is a deterministic plain-text fixture.
It keeps paragraph boundaries and Unicode: café, 漢字.
''');
  _writeText('html/synthetic.html', '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>eLivre HTML Fixture</title></head>
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

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Uint8List _buildTxtz() {
  const metadata = '''<?xml version="1.0" encoding="utf-8"?>
<package><metadata>
  <title>eLivre TXTZ Fixture</title>
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
  <dc:title xmlns:dc="http://purl.org/dc/elements/1.1/">eLivre HTMLZ Fixture</dc:title>
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
  <dc:title>eLivre DOCX Fixture</dc:title>
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
  <office:meta><dc:title>eLivre ODT Fixture</dc:title>
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
      '<ComicInfo><Title>eLivre CB7 Fixture</Title>'
      '<Writer>eLivre contributors</Writer><LanguageISO>mul</LanguageISO></ComicInfo>';

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
  <Title>eLivre Synthetic Comic</Title>
  <Series>Parser Fixtures</Series>
  <Number>1</Number>
  <Writer>eLivre contributors</Writer>
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

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
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
