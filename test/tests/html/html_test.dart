import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/src/features/html/html.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:test/test.dart';

void main() {
  group('HTML', () {
    test('preserves content and maps HTML metadata and headings', () {
      const source = '''<!doctype html>
<html lang="pt-BR"><head>
  <meta name="author" content="Ana Silva; Beto Lima">
  <meta name="description" content="Uma descrição">
  <meta name="publisher" content="Editora X">
  <title>Livro HTML</title>
</head><body>
  <h1 id="inicio">Início</h1>
  <p>Conteúdo <strong>preservado</strong>.</p>
  <h2>Segundo</h2>
</body></html>''';

      final book = parseHtmlBook(utf8.encode(source), fileName: 'book.xhtml');

      expect(book, isA<DocumentBook>());
      expect(book.format, BookFormat.html);
      expect(book.files.html.single.path, 'book.xhtml');
      expect(book.files.html.single.content, contains('<strong>preservado</strong>'));
      expect(book.metadata.title, 'Livro HTML');
      expect(book.metadata.authors, ['Ana Silva', 'Beto Lima']);
      expect(book.metadata.languages, ['pt-BR']);
      expect(book.metadata.description, 'Uma descrição');
      expect(book.metadata.publisher, 'Editora X');
      expect(book.navigation.navPoints.single.label, 'Início');
      expect(book.navigation.navPoints.single.content, 'book.xhtml#inicio');
      expect(book.navigation.navPoints.single.subNavPoints.single.label, 'Segundo');
    });

    test('honors a declared Windows-1252 encoding without throwing', () {
      final bytes = <int>[
        ...ascii.encode('<html><head><meta charset="windows-1252"><title>'),
        0xC7,
        ...ascii.encode('mera</title></head><body>'),
        0x61,
        0xE7,
        0xE3,
        0x6F,
        ...ascii.encode('</body></html>'),
      ];

      final book = parseHtmlBook(bytes);

      expect(book.metadata.title, 'Çmera');
      expect(book.files.html.single.content, contains('ação'));
    });

    test('metadata-only parsing does not require a container', () {
      final metadata = readHtmlMetadata(
        utf8.encode('<html lang="en"><head><title>Only metadata</title></head></html>'),
        fileName: 'metadata.htm',
      );

      expect(metadata.format, BookFormat.html);
      expect(metadata.title, 'Only metadata');
    });
  });

  group('HTMLZ', () {
    test('selects top-level index, merges OPF metadata, and extracts resources', () {
      final book = parseHtmlzBook(_htmlzBytes());

      expect(book.format, BookFormat.htmlz);
      expect(book.files.html.single.path, 'index.xhtml');
      expect(book.files.html.single.content, contains('Índice selecionado'));
      expect(book.metadata.title, 'Título do OPF');
      expect(book.metadata.authors, ['Autor do OPF']);
      expect(book.metadata.languages, ['pt-BR']);
      expect(book.metadata.description, 'Descrição do OPF');
      expect(book.metadata.series, 'Coleção');
      expect(book.metadata.seriesIndex, 2.5);
      expect(book.cover?.path, 'cover.png');
      expect(book.metadata.cover, isNotNull);
      expect(book.metadata.cover!.width, 1);
      expect(book.files.css.single.path, 'styles/main.css');
      expect(book.files.images.single.path, 'cover.png');
      expect(book.files.fonts.single.path, 'fonts/book.woff2');
      expect(book.files.others.map((final file) => file.path), contains('nested/chapter.html'));
      expect(book.archiveEntries.map((final entry) => entry.path), contains('metadata.opf'));
      expect(book.readingOrder.single.name, 'index.xhtml');
    });

    test('metadata-only path uses the same Calibre selection and OPF merge', () {
      final metadata = readHtmlzMetadata(_htmlzBytes());

      expect(metadata.format, BookFormat.htmlz);
      expect(metadata.title, 'Título do OPF');
      expect(metadata.authors, ['Autor do OPF']);
      expect(metadata.cover, isNotNull);
    });

    test('falls back to the first top-level HTML and ignores nested index', () {
      final archive = Archive()
        ..addFile(ArchiveFile('zeta.htm', 18, utf8.encode('<title>Fallback</title>')))
        ..addFile(ArchiveFile('nested/index.html', 24, utf8.encode('<title>Nested</title>')));

      final book = parseHtmlzArchive(archive);

      expect(book.files.html.single.path, 'zeta.htm');
      expect(book.metadata.title, 'Fallback');
    });

    test('rejects empty and non-HTML archives with clear errors', () {
      final empty = Archive();
      final noHtml = Archive()..addFile(ArchiveFile('notes.txt', 5, 'notes'.codeUnits));

      expect(
        () => parseHtmlzArchive(empty),
        throwsA(
          isA<HtmlException>().having(
            (final error) => error.message,
            'message',
            contains('no top-level HTML'),
          ),
        ),
      );
      expect(
        () => parseHtmlzArchive(noHtml),
        throwsA(
          isA<HtmlException>().having(
            (final error) => error.message,
            'message',
            contains('no top-level HTML'),
          ),
        ),
      );
    });

    test('rejects an empty selected HTML entry', () {
      final archive = Archive()..addFile(ArchiveFile('index.html', 0, const <int>[]));

      expect(
        () => parseHtmlzArchive(archive),
        throwsA(
          isA<HtmlException>().having(
            (final error) => error.message,
            'message',
            contains('index.html'),
          ),
        ),
      );
    });
  });
}

Uint8List _htmlzBytes() {
  const html = '''<html lang="en"><head>
<meta name="author" content="HTML fallback">
<meta name="description" content="HTML description">
<title>HTML fallback</title></head><body>
<h1>Índice selecionado</h1><p>Texto.</p></body></html>''';
  const otherHtml = '<html><head><title>Other</title></head></html>';
  const opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" xmlns:opf="http://www.idpf.org/2007/opf" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Título do OPF</dc:title>
    <dc:creator opf:file-as="OPF, Autor">Autor do OPF</dc:creator>
    <dc:language>pt-BR</dc:language>
    <dc:description>Descrição do OPF</dc:description>
    <dc:subject>ficção</dc:subject>
    <meta name="cover" content="cover-image"/>
    <meta name="calibre:series" content="Coleção"/>
    <meta name="calibre:series_index" content="2.5"/>
  </metadata>
  <manifest>
    <item id="cover-image" href="cover.png" media-type="image/png"/>
  </manifest>
</package>''';
  final archive = Archive()
    ..addFile(ArchiveFile('readme.html', html.length, utf8.encode(otherHtml)))
    ..addFile(ArchiveFile('index.xhtml', html.length, utf8.encode(html)))
    ..addFile(ArchiveFile('nested/chapter.html', otherHtml.length, utf8.encode(otherHtml)))
    ..addFile(ArchiveFile('styles/main.css', 22, utf8.encode('body { color: red; }')))
    ..addFile(ArchiveFile('fonts/book.woff2', 4, [0, 1, 2, 3]))
    ..addFile(ArchiveFile('cover.png', _png().length, _png()))
    ..addFile(ArchiveFile('metadata.opf', opf.length, utf8.encode(opf)))
    ..addFile(ArchiveFile('notes.txt', 5, utf8.encode('notes')));
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

Uint8List _png() => base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
  'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);
