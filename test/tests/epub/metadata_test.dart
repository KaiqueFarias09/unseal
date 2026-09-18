import 'dart:io';

import 'package:archive/archive.dart';
import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/features/epub/package/parse_epub_package.dart';
import 'package:test/test.dart';

/// Minimal OPF wrapper exercising the metadata parser.
String _opf(final String version, final String metadata) {
  return '<package xmlns="http://www.idpf.org/2007/opf" version="$version" unique-identifier="uid">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">'
      '<dc:language>en</dc:language><dc:identifier id="uid">1234</dc:identifier>'
      '$metadata'
      '</metadata>'
      '<manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>'
      '<spine toc="ncx"><itemref idref="ncx"/></spine>'
      '</package>';
}

void main() {
  group('readEpubMetadata fast path', () {
    final files = Directory(
      'test/resources/epub',
    ).listSync().whereType<File>().where((final file) => file.path.endsWith('.epub')).toList();

    for (final file in files) {
      test('reads metadata of ${file.uri.pathSegments.last}', () {
        final archive = ZipDecoder().decodeBytes(File(file.path).readAsBytesSync());
        final metadata = readEpubMetadata(archive);

        expect(metadata.format, BookFormat.epub);
        expect(metadata.title, isNotEmpty);
        expect(metadata.languages, isNotEmpty);
      });
    }

    test('carries the cover bytes for the vertical-writing fixture', () {
      final archive = ZipDecoder().decodeBytes(
        File('test/resources/books/epub/vertical-writing-ja.epub').readAsBytesSync(),
      );
      final metadata = readEpubMetadata(archive);
      expect(metadata.cover, isNotNull);
      expect(metadata.cover!.bytes.length, greaterThan(1000));
    });
  });

  group('sort keys and book producer', () {
    test('reads Dublin Core metadata through an arbitrary namespace prefix', () {
      final package = parsePackage(
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">'
        '<metadata xmlns:dct="http://purl.org/dc/elements/1.1/">'
        '<dct:title>Prefix-independent title</dct:title>'
        '<dct:creator>Prefix-independent author</dct:creator>'
        '<dct:language>pt-BR</dct:language>'
        '<dct:identifier id="uid">prefix-id</dct:identifier>'
        '</metadata>'
        '<manifest><item id="chapter" href="chapter.xhtml" '
        'media-type="application/xhtml+xml"/></manifest>'
        '<spine><itemref idref="chapter"/></spine>'
        '</package>',
      );

      expect(package.metadata.title, 'Prefix-independent title');
      expect(package.metadata.creator, 'Prefix-independent author');
      expect(package.metadata.language, 'pt-BR');
      expect(package.metadata.uniqueIdentifierValue, 'prefix-id');
    });

    test('reports missing required manifest attributes as EPUB errors', () {
      final malformed = _opf(
        '3.0',
        '<dc:title>Missing href</dc:title>',
      ).replaceFirst(' href="toc.ncx"', '');

      expect(
        () => parsePackage(malformed),
        throwsA(
          isA<EpubException>().having(
            (final error) => error.message,
            'message',
            contains('manifest item is missing the href attribute'),
          ),
        ),
      );
    });

    test('reads opf:file-as attributes and the bkp contributor', () {
      final package = parsePackage(
        _opf(
          '2.0',
          '<dc:title opf:file-as="Title, A">A Title</dc:title>'
              '<dc:creator opf:file-as="Author, An">An Author</dc:creator>'
              '<dc:contributor opf:role="bkp">calibre (9.4.0)</dc:contributor>',
        ),
      );
      expect(package.metadata.titleSort, 'Title, A');
      expect(package.metadata.authorSort, 'Author, An');
      expect(package.metadata.bookProducer, 'calibre (9.4.0)');
    });

    test('reads the calibre:*_sort name metas', () {
      final package = parsePackage(
        _opf(
          '2.0',
          '<dc:title>A Title</dc:title><dc:creator>An Author</dc:creator>'
              '<meta name="calibre:title_sort" content="Title, A"/>'
              '<meta name="calibre:author_sort" content="Author, An"/>',
        ),
      );
      expect(package.metadata.titleSort, 'Title, A');
      expect(package.metadata.authorSort, 'Author, An');
      expect(package.metadata.bookProducer, isNull);
    });

    test('reads EPUB 3 file-as refines', () {
      final package = parsePackage(
        _opf(
          '3.0',
          '<dc:title id="t">A Title</dc:title>'
              '<meta refines="#t" property="file-as">Title, A</meta>'
              '<dc:creator id="c">An Author</dc:creator>'
              '<meta refines="#c" property="file-as">Author, An</meta>',
        ),
      );
      expect(package.metadata.titleSort, 'Title, A');
      expect(package.metadata.authorSort, 'Author, An');
    });

    test('reads refines written as prefixed opf:meta elements', () {
      final package = parsePackage(
        _opf(
          '3.0',
          '<dc:title id="maintitle">A Title</dc:title>'
              '<dc:creator id="c">An Author</dc:creator>'
              '<dc:contributor id="prod">calibre (7.10.0)</dc:contributor>'
              '<opf:meta refines="#maintitle" property="file-as">Title, A</opf:meta>'
              '<opf:meta refines="#c" property="file-as">Author, An</opf:meta>'
              '<opf:meta refines="#prod" property="role" scheme="marc:relators">bkp</opf:meta>',
        ),
      );
      expect(package.metadata.titleSort, 'Title, A');
      expect(package.metadata.authorSort, 'Author, An');
      expect(package.metadata.bookProducer, 'calibre (7.10.0)');
    });

    test('reads roles written with an arbitrary namespace prefix', () {
      final package = parsePackage(
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>A Title</dc:title><dc:creator>An Author</dc:creator>'
        '<dc:language>en</dc:language><dc:identifier id="uid">1234</dc:identifier>'
        '<dc:contributor xmlns:ns4="http://www.idpf.org/2007/opf" ns4:role="bkp">'
        'calibre (1.25.0)</dc:contributor>'
        '</metadata>'
        '<manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>'
        '<spine toc="ncx"><itemref idref="ncx"/></spine>'
        '</package>',
      );
      expect(package.metadata.bookProducer, 'calibre (1.25.0)');
    });

    test('treats Unknown as absent', () {
      final package = parsePackage(
        _opf(
          '2.0',
          '<dc:title opf:file-as="Unknown">A Title</dc:title>'
              '<dc:creator opf:file-as="Unknown">An Author</dc:creator>'
              '<meta name="calibre:title_sort" content="Title, A"/>',
        ),
      );
      expect(package.metadata.titleSort, 'Title, A');
      expect(package.metadata.authorSort, isNull);
    });

    test('stays null when the OPF carries none', () {
      final package = parsePackage(
        _opf('2.0', '<dc:title>A Title</dc:title><dc:creator>An Author</dc:creator>'),
      );
      expect(package.metadata.titleSort, isNull);
      expect(package.metadata.authorSort, isNull);
      expect(package.metadata.bookProducer, isNull);
    });

    test('carries the producer of a real calibre-generated book', () {
      final metadata = readEpubMetadata(
        ZipDecoder().decodeBytes(
          File('test/resources/epub/Alices Adventures in Wonderland.epub').readAsBytesSync(),
        ),
      );
      expect(metadata.bookProducer, 'calibre (3.21.0) [http://calibre-ebook.com]');
    });
  });

  group('cover precedence', () {
    test('every fixture resolves a cover or degrades gracefully', () {
      final files = Directory(
        'test/resources/epub',
      ).listSync().whereType<File>().where((final file) => file.path.endsWith('.epub'));

      for (final file in files) {
        final book = parseEpubBook(File(file.path).readAsBytesSync());
        if (!book.cover.isEmpty) {
          expect(
            sniffImageType(book.cover.content),
            isNotNull,
            reason: 'cover of ${file.path} is not a valid image',
          );
        }
      }
    });
  });
}
