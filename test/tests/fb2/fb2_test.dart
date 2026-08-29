import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:e_livre/features/fb2/utils/parse_fb2_book.dart';
import 'package:test/test.dart';

const String aliceTitle = "Alice's Adventures in Wonderland";

void main() {
  group('alice.fb2 (calibre generated)', () {
    final book = parseFb2Book(_read('test/resources/fb2/alice.fb2'));

    test('parses metadata', () {
      expect(book.title, aliceTitle);
      expect(book.creators, ['Lewis Carroll']);
      expect(book.metadata.languages, contains('en'));
    });

    test('extracts a cover image', () {
      expect(book.cover.isEmpty, isFalse);
      expect(sniffImageType(book.cover.content), isNotNull);
    });

    test('converts the body to xhtml', () {
      expect(book.files.html, isNotEmpty);
      final html = book.files.html.first.content;
      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('Alice'));
      // Embedded images reference the extracted binary files.
      expect(html, contains('<img src="img_'));
    });

    test('extracts binary images', () {
      expect(book.files.images.length, greaterThan(10));
      for (final image in book.files.images) {
        expect(sniffImageType(image.content), isNotNull,
            reason: image.name);
      }
    });

    test('reads metadata without a full parse', () {
      final metadata = readFb2Metadata(_read('test/resources/fb2/alice.fb2'));
      expect(metadata.title, aliceTitle);
      expect(metadata.authors, ['Lewis Carroll']);
      expect(metadata.cover, isNotNull);
    });
  });

  group('synthetic document', () {
    final book = parseFb2Book(Uint8List.fromList(utf8.encode(_syntheticFb2)));

    test('maps title-info and publish-info metadata', () {
      final metadata = book.metadata;
      expect(metadata.title, 'Test Book');
      expect(metadata.authors, ['João Silva Neto']);
      expect(metadata.languages, ['pt-BR']);
      expect(metadata.publisher, 'Editora Teste');
      expect(metadata.isbn, '9783161484100');
      expect(metadata.subjects, containsAll(['sf', 'fiction', 'test tag']));
      expect(metadata.publishedAt, DateTime(2020, 5));
      expect(metadata.description, contains('Um livro de teste'));
    });

    test('resolves the coverpage binary', () {
      expect(book.cover.name, 'cover.png');
      expect(sniffImageType(book.cover.content), ImageType.png);
    });

    test('builds navigation from section titles', () {
      expect(book.navigation.navPoints, hasLength(2));
      expect(book.navigation.navPoints.first.label, 'Capítulo Um');
      expect(book.navigation.navPoints.first.content, startsWith('index.html#'));
      expect(book.navigation.navPoints.first.subNavPoints, hasLength(1));
      expect(
        book.navigation.navPoints.first.subNavPoints.first.label,
        'Seção aninhada',
      );
    });

    test('converts emphasis, poems and inline styles', () {
      final html = book.files.html.first.content;
      expect(html, contains('<em>itálico</em>'));
      expect(html, contains('<strong>negrito</strong>'));
      expect(html, contains('class="stanza"'));
      expect(html, contains('<img src="cover.png"'));
    });

    test('rewrites note links to the notes body file', () {
      final index = book.files.html
          .firstWhere((final file) => file.name == 'index.html')
          .content;
      expect(index, contains('href="notes.html#n1"'));
      final notes = book.files.html
          .firstWhere((final file) => file.name == 'notes.html')
          .content;
      expect(notes, contains('id="n1"'));
    });
  });
}

Uint8List _read(final String path) =>
    Uint8List.fromList(File(path).readAsBytesSync());

// 1x1 transparent PNG binary as base64.
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

const String _syntheticFb2 = '''
<?xml version="1.0" encoding="utf-8"?>
<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"
  xmlns:l="http://www.w3.org/1999/xlink">
  <description>
    <title-info>
      <genre>sf</genre>
      <genre>fiction</genre>
      <author>
        <first-name>João</first-name>
        <middle-name>Silva</middle-name>
        <last-name>Neto</last-name>
      </author>
      <book-title>Test Book</book-title>
      <annotation><p>Um livro de teste.</p></annotation>
      <date>2020-05-01</date>
      <lang>pt-BR</lang>
      <keywords>test tag</keywords>
      <coverpage><image l:href="#cover.png"/></coverpage>
    </title-info>
    <publish-info>
      <publisher>Editora Teste</publisher>
      <year>2020</year>
      <isbn>978-3-16-148410-0</isbn>
    </publish-info>
  </description>
  <body>
    <section id="cap1">
      <title><p>Capítulo Um</p></title>
      <p>Texto com <emphasis>itálico</emphasis> e <strong>negrito</strong>.</p>
      <p>Uma nota<footnote/><a l:href="#n1">1</a>.</p>
      <poem>
        <stanza>
          <v>linha um</v>
          <v>linha dois</v>
        </stanza>
      </poem>
      <image l:href="#cover.png"/>
      <section id="sec11">
        <title><p>Seção aninhada</p></title>
        <p>Conteúdo aninhado.</p>
      </section>
    </section>
    <section id="cap2">
      <title><p>Capítulo Dois</p></title>
      <p>Mais conteúdo.</p>
    </section>
  </body>
  <body name="notes">
    <section id="n1">
      <title><p>Notas</p></title>
      <p>Nota número um.</p>
    </section>
  </body>
  <binary id="cover.png" content-type="image/png">$_pngBase64</binary>
</FictionBook>
''';
