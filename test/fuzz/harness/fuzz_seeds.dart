/// Deterministic, minimal-but-valid seed documents per format family.
///
/// Seeds are built PROGRAMMATICALLY (no tracked binaries) so the fuzz
/// front works on any checkout. Valid seeds matter as much as hostile
/// ones: mutations of a seed that parses cleanly exercise the deep
/// parser paths, not just the sniffers.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../tests/mobi/mobi_fixture_builder.dart' as mobi_fixtures;
import '../../tests/pdf/pdf_fixture_builder.dart' as pdf_fixtures;

/// Builds the default seed set: name → bytes.
Map<String, Uint8List> fuzzSeeds() {
  final seeds = <String, Uint8List>{
    'pdf-minimal': pdf_fixtures.textPageFixture().build(),
    'txt-plain': _text(_plainTxt),
    'html-plain': _text(_plainHtml),
    'txtz': _zip(<String, List<int>>{
      'metadata.opf': _text(_opf('TXTZ')),
      'chapter1.txt': _text('# Chapter\n\nDeterministic TXTZ body.\n'),
      'cover.png': Uint8List.fromList(mobi_fixtures.tinyPng),
    }),
    'htmlz': _zip(<String, List<int>>{
      'index.html': _text(_plainHtml),
      'metadata.opf': _text(_opf('HTMLZ')),
      'cover.png': Uint8List.fromList(mobi_fixtures.tinyPng),
    }),
    'docx': _zip(<String, List<int>>{
      'word/document.xml': _text(_docxDocument),
      'docProps/core.xml': _text(_core('DOCX')),
    }),
    'odt': _zip(<String, List<int>>{
      'mimetype': _text('application/vnd.oasis.opendocument.text'),
      'content.xml': _text(_odtContent),
      'meta.xml': _text(_odtMeta),
    }),
    'epub': _zip(<String, List<int>>{
      'mimetype': _text('application/epub+zip'),
      'META-INF/container.xml': _text(_containerXml),
      'content.opf': _text(_opf('EPUB')),
      'chapter1.xhtml': _text(_chapterXhtml),
      'cover.png': Uint8List.fromList(mobi_fixtures.tinyPng),
    }),
    'fb2': _text(_fb2Document),
    'cbz': _zip(<String, List<int>>{
      '001.png': Uint8List.fromList(mobi_fixtures.tinyPng),
      '002.png': Uint8List.fromList(mobi_fixtures.tinyPng),
      'ComicInfo.xml': _text('<ComicInfo><Title>CBZ</Title></ComicInfo>'),
    }),
    'mobi-palmdoc': mobi_fixtures.buildPdb('Fuzz seed', <Uint8List>[
      mobi_fixtures.buildMobiRecord0(title: 'Fuzz seed'),
      Uint8List.fromList(utf8.encode('Deterministic MOBI body for the fuzz harness. ' * 4)),
    ]),
    'azw4': mobi_fixtures.buildPdb('Fuzz AZW4', <Uint8List>[
      mobi_fixtures.buildMobiRecord0(title: 'Fuzz AZW4'),
      pdf_fixtures.textPageFixture().build(),
    ]),
  };
  return seeds;
}

/// Zip-building helper shared by the seeds (deflate by default).
Uint8List fuzzZip(final Map<String, List<int>> entries) => _zip(entries);

Uint8List _zip(final Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = Uint8List.fromList(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes)..lastModTime = 946684800);
  }

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _text(final String value) => Uint8List.fromList(utf8.encode(value));

const _plainTxt = '''
Fuzz Seed Book


Ada Lovelace

Deterministic plain text for the fuzz harness.
Second paragraph with café and 漢字.
''';

const _plainHtml = '''
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Fuzz seed</title></head>
<body><h1>Chapter</h1><p>Deterministic HTML seed.</p></body></html>
''';

const _containerXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
''';

const _chapterXhtml = '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter</title></head>
<body><h1>Chapter one</h1><p>Deterministic EPUB chapter.</p></body></html>
''';

String _opf(final String label) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="id">urn:uuid:00000000-0000-0000-0000-000000000001</dc:identifier>
    <dc:title>$label fuzz seed</dc:title>
    <dc:language>en</dc:language>
    <dc:creator>Ada Lovelace</dc:creator>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
  </manifest>
  <spine><itemref idref="chapter1"/></spine>
</package>
''';

String _core(final String label) =>
    '''
<?xml version="1.0" encoding="UTF-8"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:title>$label fuzz seed</dc:title>
  <dc:creator>Ada Lovelace</dc:creator>
  <dc:language>en</dc:language>
</cp:coreProperties>
''';

const _docxDocument = '''
<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p><w:r><w:t>DOCX fuzz seed</w:t></w:r></w:p>
    <w:p><w:r><w:t>Deterministic body.</w:t></w:r></w:p>
    <w:sectPr/>
  </w:body>
</w:document>
''';

const _odtContent = '''
<?xml version="1.0" encoding="UTF-8"?>
<office:document-content
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
  <office:body><office:text>
    <text:h text:outline-level="1">ODT fuzz seed</text:h>
    <text:p>Deterministic body.</text:p>
  </office:text></office:body>
</office:document-content>
''';

const _odtMeta = '''
<?xml version="1.0" encoding="UTF-8"?>
<office:document-meta
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
  <office:meta><dc:title>ODT fuzz seed</dc:title><dc:language>en</dc:language></office:meta>
</office:document-meta>
''';

const _fb2Document = '''
<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
  <description><title-info><book-title>FB2 fuzz seed</book-title>
  <author><first-name>Ada</first-name><last-name>Lovelace</last-name></author>
  </title-info><body-title/><document-info><id>fuzz-seed</id></document-info></description>
  <body>
    <section><title><p>Chapter</p></title>
      <p>Deterministic FB2 body.</p>
    </section>
  </body>
</FictionBook>
''';
