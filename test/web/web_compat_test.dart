@TestOn('browser')
library;

// Web runtime compatibility: the parser must work in a browser with
// no dart:io in scope. Fixtures are assembled in memory so the file
// never touches the filesystem, unlike the VM suites.
//
// Run with: dart test test/web --platform chrome
import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/platform/web/book_wire.dart';
import 'package:koni_archive/koni_archive.dart' as koni;
import 'package:test/test.dart';

import '../tests/mobi/mobi_fixture_builder.dart';
import '../tests/pdf/pdf_fixture_builder.dart';

Uint8List _utf8(final String value) => Uint8List.fromList(convert.utf8.encode(value));

const String _opfContent = '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    version="2.0" unique-identifier="uid">
  <metadata>
    <dc:title>Synthetic Web</dc:title>
    <dc:creator>Web Author</dc:creator>
    <dc:language>en</dc:language>
    <dc:identifier id="uid">urn:uuid:web-compat</dc:identifier>
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx">
    <itemref idref="ch1"/>
  </spine>
</package>
''';

const String _containerContent = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

const String _ncxContent = '''
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:web-compat"/></head>
  <docTitle><text>Synthetic Web</text></docTitle>
  <navMap>
    <navPoint id="np1" playOrder="1" class="chapter">
      <navLabel><text>Chapter One</text></navLabel>
      <content src="ch1.xhtml"/>
    </navPoint>
  </navMap>
</ncx>
''';

const String _chapterContent = '''
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Chapter One</title></head>
  <body><p>Hello from the browser.</p></body>
</html>
''';

const String _fb2Content = '''
<?xml version="1.0" encoding="UTF-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">
  <description>
    <title-info>
      <book-title>Synthetic FB2</book-title>
      <author><first-name>Fb</first-name><last-name>Two</last-name></author>
      <lang>en</lang>
    </title-info>
  </description>
  <body>
    <section><title><p>Section</p></title><p>FB2 body on the web.</p></section>
  </body>
</FictionBook>
''';

Uint8List _zip(final List<(String, Uint8List, bool)> entries) {
  final archive = Archive();
  for (final (name, bytes, store) in entries) {
    final file = ArchiveFile(name, bytes.length, bytes)..compress = !store;
    archive.addFile(file);
  }

  return Uint8List.fromList(ZipEncoder().encode(archive) ?? <int>[]);
}

Uint8List buildSyntheticEpub() => _zip([
  ('mimetype', _utf8('application/epub+zip'), true),
  ('META-INF/container.xml', _utf8(_containerContent), false),
  ('content.opf', _utf8(_opfContent), false),
  ('toc.ncx', _utf8(_ncxContent), false),
  ('ch1.xhtml', _utf8(_chapterContent), false),
]);

Uint8List buildSyntheticCbz() =>
    _zip([('page01.jpg', tinyJpeg, false), ('page02.jpg', tinyJpeg, false)]);

Uint8List buildSyntheticTxtz() => _zip([
  (
    'metadata.opf',
    _utf8('''<package><metadata>
  <title>Browser TXTZ</title><creator>TXT Author</creator><language>en</language>
</metadata></package>'''),
    false,
  ),
  ('book.txt', _utf8('TXTZ body on the browser.'), false),
]);

Uint8List buildSyntheticHtmlz() => _zip([
  (
    'index.html',
    _utf8('''<!doctype html><html lang="en"><head>
  <title>Browser HTMLZ</title></head><body><h1>HTMLZ chapter</h1></body></html>'''),
    false,
  ),
]);

Uint8List buildSyntheticDocx() => _zip([
  (
    'word/document.xml',
    _utf8('''<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>DOCX body on the browser.</w:t></w:r></w:p><w:sectPr/></w:body>
</w:document>'''),
    false,
  ),
]);

Uint8List buildSyntheticOdt() => _zip([
  (
    'content.xml',
    _utf8('''<office:document-content
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
  <office:body><office:text><text:p>ODT body on the browser.</text:p></office:text></office:body>
</office:document-content>'''),
    false,
  ),
]);

Future<Uint8List> buildSyntheticCb7() async {
  final sink = koni.BytesBuilderSink();
  final writer = koni.Archive.create(sink, format: const koni.SevenZWriteFormat());
  await writer.addBytes(koni.ArchiveEntrySpec(path: 'page01.png'), tinyPng);
  await writer.close();
  await sink.close();

  return sink.takeBytes();
}

Uint8List buildSyntheticCbc(final Uint8List nested) => _zip([
  ('comics.txt', _utf8('nested.cbz:Browser collection\n'), false),
  ('nested.cbz', nested, false),
]);

void main() {
  group('parsing on the browser runtime', () {
    test('opens an EPUB through openFromBytes', () async {
      final book = await BookReader.openFromBytes(buildSyntheticEpub());

      expect(book, isA<EpubBook>());
      expect(book.metadata.title, 'Synthetic Web');
      expect(book.metadata.authors, ['Web Author']);
      expect(book.files.html.single.content, contains('Hello from the browser.'));
      expect(book.navigation.navPoints.single.label, 'Chapter One');
      expect(book.archiveEntries, isNotEmpty);
      expect(book.statistics.wordCount, greaterThan(0));
    });

    test('reads EPUB metadata through the fast path', () async {
      final metadata = await BookReader.readMetadataFromBytes(buildSyntheticEpub());

      expect(metadata.title, 'Synthetic Web');
      expect(metadata.format, BookFormat.epub);
    });

    test('opens a synthetic MOBI', () async {
      final book = await BookReader.openFromBytes(
        buildPdb('SyntheticMobiWeb', [
          buildMobiRecord0(textRecordCount: 1, title: 'Synthetic Mobi Web'),
          _utf8('<html><body><p>Mobi on the web.</p></body></html>'),
        ]),
      );

      expect(book, isA<MobiBook>());
      expect(book.metadata.title, 'Synthetic Mobi Web');
      expect(book.files.html.single.content, contains('Mobi on the web.'));
    });

    test('opens an FB2 document', () async {
      final book = await BookReader.openFromBytes(_utf8(_fb2Content));

      expect(book, isA<Fb2Book>());
      expect(book.metadata.title, 'Synthetic FB2');
      expect(book.files.html, isNotEmpty);
    });

    test('opens a CBZ comic', () async {
      final book = await BookReader.openFromBytes(buildSyntheticCbz());

      expect(book, isA<ComicBook>());
      expect((book as ComicBook).pageCount, 2);
      expect(book.readingOrder.every((final item) => !item.isHtml), isTrue);
    });

    test('opens the new document and archive formats', () async {
      final txt = await BookReader.openFromBytes(_utf8('Browser TXT\n\n\nTXT Author\n\nTXT body.'));
      final html = await BookReader.openFromBytes(
        _utf8(
          '<!doctype html><html><head><title>Browser HTML</title></head><body><p>HTML body.</p></body></html>',
        ),
      );
      final txtz = await BookReader.openFromBytes(buildSyntheticTxtz());
      final htmlz = await BookReader.openFromBytes(buildSyntheticHtmlz());
      final docx = await BookReader.openFromBytes(buildSyntheticDocx());
      final odt = await BookReader.openFromBytes(buildSyntheticOdt());
      final azw4 = await BookReader.openFromBytes(
        buildPdb('Browser AZW4', [buildMobiRecord0(), textPageFixture().build()]),
      );
      final cb7 = await BookReader.openFromBytes(await buildSyntheticCb7());
      final cbc = await BookReader.openFromBytes(buildSyntheticCbc(buildSyntheticCbz()));

      expect(txt.format, BookFormat.txt);
      expect(html.format, BookFormat.html);
      expect(txtz.format, BookFormat.txtz);
      expect(htmlz.format, BookFormat.htmlz);
      expect(docx.format, BookFormat.docx);
      expect(odt.format, BookFormat.odt);
      expect(azw4.format, BookFormat.azw4);
      expect(cb7.format, BookFormat.cb7);
      expect(cbc.format, BookFormat.cbc);
      expect(txt.files.html.single.content, contains('TXT body.'));
      expect(html.files.html.single.content, contains('HTML body.'));
      expect(txtz.metadata.title, 'Browser TXTZ');
      expect(htmlz.metadata.title, 'Browser HTMLZ');
      expect(docx.files.html.single.content, contains('DOCX body on the browser.'));
      expect(odt.files.html.single.content, contains('ODT body on the browser.'));
      expect((azw4 as PdfBook).pageCount, 1);
      expect((cb7 as ComicBook).pageCount, 1);
      expect((cbc as ComicBook).pageCount, 2);
    });
  });

  group('worker wire codec on the browser', () {
    test('public worker facade binds to the browser client', () {
      addTearDown(WorkerBookReader.dispose);

      expect(WorkerBookReader.isConfigured, isFalse);
      WorkerBookReader.configure(Uri.parse('e_livre_worker.js'));
      expect(WorkerBookReader.isConfigured, isTrue);
      WorkerBookReader.dispose();
      expect(WorkerBookReader.isConfigured, isFalse);
    });

    test('round-trips a parsed book through the wire', () async {
      final book = await BookReader.openFromBytes(buildSyntheticEpub()) as EpubBook;
      final (json, blobs) = encodeBookWire(book);
      final channel = decodeJson(encodeJson(json));
      final decoded = decodeBookWire(channel, blobs) as EpubBook;

      expect(decoded.metadata.title, book.metadata.title);
      expect(decoded.files.html.single.content, book.files.html.single.content);
      expect(decoded.navigation.navPoints.single.label, 'Chapter One');
      expect(decoded.cover.content, book.cover.content);
      expect(decoded.spinePaths, book.spinePaths);
    });
  });

  group('path-backed APIs on the browser', () {
    test('openFromPath throws UnsupportedError', () {
      expect(BookReader.openFromPath('books/sample.epub'), throwsUnsupportedError);
    });

    test('readMetadataFromPath throws UnsupportedError', () {
      expect(BookReader.readMetadataFromPath('books/sample.epub'), throwsUnsupportedError);
    });
  });
}
