import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../mobi/mobi_fixture_builder.dart' show buildPdb;

void main() {
  group('RTF', () {
    final bytes = File('test/resources/books/format_expansion/garden.rtf').readAsBytesSync();

    test('detects, reads metadata, and keeps readable formatting', () {
      expect(detectFormat(bytes), DetectedFormat.rtf);
      final metadata = Unseal.readMetadataSync(bytes);
      expect(metadata.format, BookFormat.rtf);
      expect(metadata.title, 'Jardim Secreto');
      expect(metadata.authors, <String>['Ana Moraes']);

      final book = Unseal.parse(bytes) as DocumentBook;
      final html = book.files.html.single.content;
      expect(book.format, BookFormat.rtf);
      expect(book.readingOrder.single.name, 'document.html');
      expect(html, contains('Olá, leitor.'));
      expect(html, contains('<strong>Forte</strong>'));
      expect(html, contains('<em>suave</em>'));
      expect(html, contains('çnicode'));
      expect(html, contains('Fim.'));
      expect(html, isNot(contains('89504E47')));
    });

    test('honors group scope, escaped braces, and Unicode fallback', () {
      final input = utf8.encode(r'{\rtf1 outside {\b bold} normal \{x\} \u945?done}');
      final html = parseRtfBook(Uint8List.fromList(input)).files.html.single.content;
      expect(html, contains('outside <strong>bold</strong> normal {x} αdone'));
      expect(html, isNot(contains('α?done')));
    });

    test('skips binary and unknown ignorable destinations', () {
      final input = Uint8List.fromList([
        ...r'{\rtf1 before {\*\unknown SECRET}{\pict\bin4 '.codeUnits,
        0x7B,
        0x7D,
        0x5C,
        0x41,
        ...r'} after}'.codeUnits,
      ]);
      final html = parseRtfBook(input).files.html.single.content;
      expect(html, contains('before  after'));
      expect(html, isNot(contains('SECRET')));
    });

    test('decodes UTF-8 codepage bytes and escaped bytes', () {
      final raw = Uint8List.fromList([
        ...r'{\rtf1\ansi\ansicpg65001 '.codeUnits,
        0xC3,
        0xA1,
        0x20,
        ...r"\'c3\'a9}".codeUnits,
      ]);
      expect(parseRtfBook(raw).files.html.single.content, contains('á é'));
    });

    test('rejects bytes in an unsupported codepage without losing Unicode escapes', () {
      final encoded = Uint8List.fromList(r"{\rtf1\ansi\ansicpg932 \'82}".codeUnits);
      expect(() => parseRtfBook(encoded), throwsA(isA<FormatNotSupportedException>()));
      final unicode = Uint8List.fromList(r'{\rtf1\ansi\ansicpg932 \u26085?}'.codeUnits);
      expect(parseRtfBook(unicode).files.html.single.content, contains('日'));
    });

    test('reads a real Calibre RTF document', () {
      final file = File('test/resources/books/format_expansion/calibre-license.rtf');
      final bytes = file.readAsBytesSync();
      expect(
        sha256.convert(bytes).toString(),
        'a348e35edada9240ed21b1249e79be20ddac0184714773c7d0b02b7156fc642c',
      );
      final book = Unseal.parse(bytes) as DocumentBook;
      final text = book.files.html.single.plainText;
      expect(text, startsWith('GNU GENERAL PUBLIC LICENSE'));
      expect(text, contains('Copyright © 2007 Free Software Foundation'));
      expect(text.length, greaterThan(30000));
    });

    test('rejects malformed groups and oversized Unicode fallback', () {
      for (final text in <String>[
        r'{\rtf1 {oops}',
        r'{\rtf1 broken}}',
        r'{\rtf1\uc999\u65?}',
        r'{\rtf1\bin999 x}',
        r'{\rtf1\bin999999999999999999999 x}',
        r'{\rtf1\abcdefghijklmnopqrstuvwxyzabcdefg x}',
      ]) {
        expect(
          () => parseRtfBook(Uint8List.fromList(text.codeUnits)),
          throwsA(isA<InvalidBookException>()),
        );
      }
    });

    test('bounds nested RTF groups', () {
      final input = '{\\rtf1${'{' * 129}text${'}' * 130}';
      expect(
        () => parseRtfBook(Uint8List.fromList(input.codeUnits)),
        throwsA(isA<InvalidBookException>()),
      );
    });
  });

  group('standalone Markdown', () {
    final bytes = File('test/resources/books/format_expansion/garden.md').readAsBytesSync();

    test('parses front matter, headings, lists, and relative references', () {
      final book = parseMarkdownBook(bytes, sourceName: 'garden.md');
      expect(book.format, BookFormat.markdown);
      expect(book.metadata.title, 'Jardim Secreto');
      expect(book.metadata.authors, <String>['Ana Moraes']);
      expect(book.metadata.languages, <String>['pt-BR']);
      expect(book.metadata.subjects, <String>['botânica', 'ficção']);
      expect(book.navigation.navPoints.map((final point) => point.label), <String>['Abertura']);
      expect(book.navigation.navPoints.single.subNavPoints.single.label, 'Detalhes');
      expect(book.navigation.navPoints.first.content, 'document.html#abertura');
      final html = book.files.html.single.content;
      expect(html, contains('<strong>história</strong>'));
      expect(html, contains('<li>Primeiro ponto</li>'));
      expect(html, contains('src="images/leaf.png"'));
      expect(html, contains('href="chapter.md"'));
    });

    test('routes .md files through the facade with consistent metadata', () async {
      final file = File('test/resources/books/format_expansion/garden.md');
      final book = await Unseal.readFile(file.path);
      final metadata = await Unseal.readMetadataFile(file.path);
      expect(book.format, BookFormat.markdown);
      expect(metadata.format, BookFormat.markdown);
      expect(metadata.title, book.metadata.title);
    });

    test('requires explicit format context for byte-only Markdown', () {
      expect(Unseal.parse(bytes).format, BookFormat.txt);
      expect(parseMarkdownBook(bytes).format, BookFormat.markdown);
    });

    test('rejects malformed front matter with a typed error', () {
      final bytes = Uint8List.fromList(utf8.encode('---\ntitle: Missing\n# Body'));
      expect(() => parseMarkdownBook(bytes), throwsA(isA<InvalidBookException>()));
    });

    test('metadata ignores heading-looking text inside code fences', () {
      final bytes = Uint8List.fromList(utf8.encode('```md\n# Fake\n```\n\n# Actual\n'));
      expect(readMarkdownMetadata(bytes).title, 'Actual');
      expect(parseMarkdownBook(bytes).metadata.title, 'Actual');
    });
  });

  test('single-byte decoding does not prepend the input length', () {
    expect(decodeXmlTextAs(<int>[0xE1], XmlEncoding.cp1252), 'á');
    expect(decodeXmlTextAs(<int>[0x41], XmlEncoding.ascii), 'A');
  });

  group('PalmDOC', () {
    final bytes = File('test/resources/books/format_expansion/garden.pdb').readAsBytesSync();

    test('detects and opens a compressed TEXt/REAd database', () {
      expect(detectFormat(bytes), DetectedFormat.palmdoc);
      final book = Unseal.parse(bytes) as DocumentBook;
      expect(book.format, BookFormat.palmdoc);
      expect(book.metadata.title, 'Palm Garden');
      expect(book.files.html.single.content, contains('Hello World'));
      expect(book.files.html.single.content, contains('Second paragraph'));
      expect(Unseal.readMetadataSync(bytes).title, 'Palm Garden');
    });

    test('rejects an invalid compressed record with a typed error', () {
      final broken = Uint8List.fromList(bytes);
      broken[broken.length - 1] = 0x80;
      expect(() => parsePalmdocBook(broken), throwsA(isA<InvalidBookException>()));
    });

    test('reads uncompressed text and overlapping back references', () {
      Uint8List source(final int compression, final int length, final Uint8List record) {
        final header = ByteData(16)
          ..setUint16(0, compression)
          ..setUint32(4, length)
          ..setUint16(8, 1)
          ..setUint16(10, 4096);
        return buildPdb('Palm Test', <Uint8List>[header.buffer.asUint8List(), record])
          ..setRange(60, 68, 'TEXtREAd'.codeUnits);
      }

      final raw = source(1, 9, Uint8List.fromList(utf8.encode('abcabcabc')));
      final packed = source(2, 9, Uint8List.fromList(<int>[0x61, 0x62, 0x63, 0x80, 0x1B]));
      for (final bytes in <Uint8List>[raw, packed]) {
        final book = parsePalmdocBook(bytes);
        expect(book.files.html.single.content, contains('<p>abcabcabc</p>'));
        expect(readPalmdocMetadata(bytes).title, book.metadata.title);
      }
    });
  });

  test('Kepubify KEPUB opens as EPUB with metadata and Kobo spans intact', () {
    final original = Unseal.parse(
      File('test/resources/books/epub/hefty-water.epub').readAsBytesSync(),
    );
    final kepubBytes = File(
      'test/resources/books/format_expansion/hefty-water.kepub.epub',
    ).readAsBytesSync();
    expect(
      sha256.convert(kepubBytes).toString(),
      'd24e52856e64a1b45deba9f3a0b35104dad7b44ae88af6bf6e2c116ab29894df',
    );
    final kepub = Unseal.parse(kepubBytes);
    expect(kepub.format, BookFormat.epub);
    expect(kepub.metadata.title, original.metadata.title);
    expect(kepub.readingOrder.length, greaterThanOrEqualTo(original.readingOrder.length));
    expect(kepub.files.html.any((final file) => file.content.contains('koboSpan')), isTrue);
  });

  test('independently produced Standard Ebooks KEPUB retains reading structure', () {
    final bytes = File(
      'test/resources/books/format_expansion/standardebooks-red-badge.kepub.epub',
    ).readAsBytesSync();
    expect(
      sha256.convert(bytes).toString(),
      '7075073bba72242ade634cbd9f50546664ac3d39613efc7d91403da5545219f8',
    );
    final book = Unseal.parse(bytes);
    expect(book.format, BookFormat.epub);
    expect(book.metadata.title, contains('Red Badge of Courage'));
    expect(book.readingOrder.length, greaterThan(20));
    expect(book.navigation.navPoints, isNotEmpty);
    expect(book.files.html.any((file) => file.content.contains('koboSpan')), isTrue);
    expect(book.files.images, isNotEmpty);
  });
}
