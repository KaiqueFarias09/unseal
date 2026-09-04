// Wire round-trips: every parsed book must survive
// encode -> decode with its load-bearing fields intact.
//
// The codec is the transport behind the web worker; a dropped field
// here means silent data loss in browsers only.
import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/features/mobi/header/pdb_header.dart';
import 'package:e_livre/src/platform/web/book_wire.dart';
import 'package:test/test.dart';

Uint8List _bytes(final String name) =>
    Uint8List.fromList(File('test/resources/$name').readAsBytesSync());

/// Encodes [book] exactly the way the worker does, including the MOBI
/// record 0 slice taken from the source [bytes].
(Map<String, Object?>, List<Uint8List>) encode(final Book book, final Uint8List bytes) {
  Uint8List? record0;
  String? ident;
  if (book is MobiBook) {
    final pdb = PdbHeader.parse(bytes);
    record0 = pdb.record(0);
    ident = pdb.ident;
  }

  return encodeBookWire(book, mobiRecord0: record0, mobiIdent: ident);
}

void main() {
  group('EPUB wire round-trip', () {
    final bytes = _bytes('epub/Alices Adventures in Wonderland.epub');
    final book = BookReader.parseBook(bytes) as EpubBook;

    test('carries metadata, navigation and files', () {
      final (json, blobs) = encode(book, bytes);
      final decoded = decodeBookWire(json, blobs) as EpubBook;

      expect(decoded.metadata.title, book.metadata.title);
      expect(decoded.metadata.authors, book.metadata.authors);
      expect(decoded.metadata.languages, book.metadata.languages);
      expect(decoded.metadata.series, book.metadata.series);
      expect(decoded.metadata.identifiers, book.metadata.identifiers);
      expect(decoded.cover.content, book.cover.content);
      expect(decoded.navigation.title, book.navigation.title);
      expect(decoded.navigation.navPoints.length, book.navigation.navPoints.length);
      expect(decoded.files.html.length, book.files.html.length);
      expect(decoded.files.html.first.path, book.files.html.first.path);
      expect(decoded.files.html.first.content, book.files.html.first.content);
      expect(decoded.files.images.length, book.files.images.length);
      expect(decoded.files.css.length, book.files.css.length);
      expect(decoded.files.fonts.length, book.files.fonts.length);
      expect(decoded.archiveEntries.length, book.archiveEntries.length);
      expect(decoded.statistics.wordCount, book.statistics.wordCount);
    });

    test('carries the parsed OPF package (2.0 and 3.0)', () {
      for (final name in ['epub/Alices Adventures in Wonderland.epub', 'epub/WCAG-ch1.epub']) {
        final source = _bytes(name);
        final original = BookReader.parseBook(source) as EpubBook;
        final (json, blobs) = encode(original, source);
        final decoded = decodeBookWire(json, blobs) as EpubBook;

        expect(decoded.package.version, original.package.version, reason: name);
        expect(decoded.package.uniqueIdentifier, original.package.uniqueIdentifier, reason: name);
        expect(decoded.package.metadata.creator, original.package.metadata.creator, reason: name);
        expect(decoded.package.metadata.title, original.package.metadata.title, reason: name);
        expect(
          decoded.package.metadata.uniqueIdentifierValue,
          original.package.metadata.uniqueIdentifierValue,
          reason: name,
        );
        expect(decoded.package.manifest.items.length, original.package.manifest.items.length);
        expect(decoded.package.spine.items, original.package.spine.items);
        expect(decoded.spinePaths, original.spinePaths);
        expect(decoded.readingOrder.length, original.readingOrder.length);
        expect(
          decoded.package.runtimeType,
          original.package.runtimeType,
          reason: 'the EPUB flavor (2/3) must survive the wire ($name)',
        );
      }
    });

    test('keeps EPUB 3 metadata extras', () {
      final source = _bytes('epub/WCAG-ch1.epub');
      final original = BookReader.parseBook(source) as EpubBook;
      final package = original.package;
      if (package is! Epub3Package) return;

      final (json, blobs) = encode(original, source);
      final decoded = decodeBookWire(json, blobs) as EpubBook;
      final metadata = package.metadata as Epub3Metadata;
      final decodedMetadata = (decoded.package as Epub3Package).metadata as Epub3Metadata;

      expect(decodedMetadata.modified, metadata.modified);
      expect(decodedMetadata.schemaOrgs, metadata.schemaOrgs);
      expect(decodedMetadata.narrator, metadata.narrator);
    });
  });

  group('MOBI wire round-trip', () {
    test('rebuilds the header from the record 0 slice', () {
      final bytes = _bytes('mobi/alice-old.mobi');
      final book = BookReader.parseBook(bytes) as MobiBook;
      final (json, blobs) = encode(book, bytes);
      final decoded = decodeBookWire(json, blobs) as MobiBook;

      expect(decoded.header.mobiVersion, book.header.mobiVersion);
      expect(decoded.header.title, book.header.title);
      expect(decoded.header.codec, book.header.codec);
      expect(decoded.metadata.title, book.metadata.title);
      expect(decoded.files.html.single.content, book.files.html.single.content);
      expect(decoded.cover.content, book.cover.content);
      expect(decoded.chapters.length, book.chapters.length);
    });

    test('round-trips the KF8 flavor', () {
      final bytes = _bytes('mobi/alice-kf8.azw3');
      final original = BookReader.parseBook(bytes) as MobiBook;
      final (json, blobs) = encode(original, bytes);
      final decoded = decodeBookWire(json, blobs) as MobiBook;

      expect(decoded.format, BookFormat.azw3);
      expect(decoded.header.mobiVersion, 8);
      expect(decoded.files.html.length, original.files.html.length);
    });
  });

  group('FB2 wire round-trip', () {
    test('carries the stored metadata', () {
      final book = BookReader.parseBook(_bytes('fb2/alice.fb2')) as Fb2Book;
      final (json, blobs) = encode(book, _bytes('fb2/alice.fb2'));
      final decoded = decodeBookWire(json, blobs) as Fb2Book;

      expect(decoded.metadata.title, book.metadata.title);
      expect(decoded.metadata.authors, book.metadata.authors);
      expect(decoded.files.html.length, book.files.html.length);
      expect(decoded.navigation.navPoints.length, book.navigation.navPoints.length);
    });
  });

  group('Comic wire round-trip', () {
    test('carries pages and metadata', () {
      final source = _bytes('comic/sample.cbz');
      final book = BookReader.parseBook(source) as ComicBook;
      final (json, blobs) = encode(book, source);
      final decoded = decodeBookWire(json, blobs) as ComicBook;

      expect(decoded.pageCount, book.pageCount);
      expect(decoded.pages.first.content, book.pages.first.content);
      expect(decoded.cover.content, book.cover.content);
      expect(decoded.readingOrder.length, book.readingOrder.length);
    });
  });

  group('metadata wire round-trip', () {
    test('carries every scalar, list, map, date and cover', () {
      final metadata = BookReader.readMetadataSync(_bytes('epub/Sway.epub'));
      final (json, blobs) = encodeMetadataWire(metadata);
      final decoded = decodeMetadataWire(json, blobs);

      expect(decoded.format, metadata.format);
      expect(decoded.title, metadata.title);
      expect(decoded.titleSort, metadata.titleSort);
      expect(decoded.authorSort, metadata.authorSort);
      expect(decoded.authors, metadata.authors);
      expect(decoded.languages, metadata.languages);
      expect(decoded.subjects, metadata.subjects);
      expect(decoded.publisher, metadata.publisher);
      expect(decoded.publishedAt, metadata.publishedAt);
      expect(decoded.identifiers, metadata.identifiers);
      expect(decoded.series, metadata.series);
      expect(decoded.seriesIndex, metadata.seriesIndex);
      expect(decoded.cover?.bytes, metadata.cover?.bytes);
      expect(decoded.cover?.type, metadata.cover?.type);
      expect(decoded.cover?.width, metadata.cover?.width);
      expect(decoded.cover?.height, metadata.cover?.height);
    });

    test('survives the JSON channel', () {
      final metadata = BookReader.readMetadataSync(_bytes('epub/Sway.epub'));
      final (json, blobs) = encodeMetadataWire(metadata);
      final channel = decodeJson(encodeJson(json));
      final decoded = decodeMetadataWire(channel, blobs);

      expect(decoded.title, metadata.title);
      expect(decoded.publishedAt, metadata.publishedAt);
      expect(decoded.seriesIndex, metadata.seriesIndex);
    });
  });

  group('error wire', () {
    test('maps every known exception type back', () {
      expect(decodeErrorWire('EmptyBytesException', ''), isA<EmptyBytesException>());
      expect(
        decodeErrorWire('FormatNotSupportedException', 'x'),
        isA<FormatNotSupportedException>(),
      );
      expect(decodeErrorWire('DrmProtectedException', 'x'), isA<DrmProtectedException>());
      expect(decodeErrorWire('InvalidBookException', 'x'), isA<InvalidBookException>());
      expect(decodeErrorWire('EpubException', 'x'), isA<EpubException>());
      expect(decodeErrorWire('MobiException', 'x'), isA<MobiException>());
      expect(decodeErrorWire('Fb2Exception', 'x'), isA<Fb2Exception>());
      expect(decodeErrorWire('ComicException', 'x'), isA<ComicException>());
      expect(decodeErrorWire('RangeError', 'boom'), isA<ELivreException>());
    });
  });
}
