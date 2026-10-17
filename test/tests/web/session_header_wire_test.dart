// Session header wire: the header book a session serves must survive
// encode -> JSON channel -> decode with every load-bearing structure
// intact while carrying no content.
//
// The `sessionOpen` op replies with exactly this codec; a dropped
// field here means silent data loss in browsers only, so the
// round-trip is asserted against both the session header and the
// eager parse of the same fixture.
//
// runWorkerOp is not involved here; the codec is exercised exactly
// the way the op uses it.
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/unseal.dart';

Uint8List _bytes(final String name) =>
    Uint8List.fromList(File('test/resources/$name').readAsBytesSync());

/// The session header of [fixture] plus its wire round-trip, engine
/// already closed — the header owns its structures once built.
Future<(EpubBook, EpubBook)> _epubHeaderAndDecoded(final String fixture) async {
  final engine = await SessionEngine.openBytes(_bytes(fixture));
  final header = engine.book as EpubBook;
  engine.close();

  return (header, _roundTrip(header) as EpubBook);
}

/// The session header of a comic [fixture] plus its wire round-trip.
Future<(ComicBook, ComicBook)> _comicHeaderAndDecoded(final String fixture) async {
  final engine = await SessionEngine.openBytes(_bytes(fixture));
  final header = engine.book as ComicBook;
  engine.close();

  return (header, _roundTrip(header) as ComicBook);
}

/// Encodes [header] and decodes it back across the JSON channel, the
/// way a `sessionOpen` reply crosses to the main thread (the blobs
/// themselves ride the structured clone and arrive unchanged).
Book _roundTrip(final Book header) {
  final (json, blobs) = encodeSessionHeaderWire(header);
  final channel = decodeJson(encodeJson(json));

  return decodeSessionHeaderWire(channel, blobs);
}

void _expectSameNavigation(final Navigation wire, final Navigation inline) {
  expect(wire.title, inline.title);
  expect(wire.navPoints.length, inline.navPoints.length);
  for (var i = 0; i < inline.navPoints.length; i++) {
    _expectSameNavPoint(wire.navPoints[i], inline.navPoints[i], i);
  }
}

void _expectSameNavPoint(final NavPoint wire, final NavPoint inline, final int index) {
  expect(wire.label, inline.label, reason: 'nav point $index label');
  expect(wire.content, inline.content, reason: 'nav point $index content');
  expect(wire.id, inline.id, reason: 'nav point $index id');
  expect(wire.classAttribute, inline.classAttribute, reason: 'nav point $index class');
  expect(wire.playOrder, inline.playOrder, reason: 'nav point $index playOrder');
  expect(wire.subNavPoints.length, inline.subNavPoints.length, reason: 'nav point $index subs');
  for (var i = 0; i < inline.subNavPoints.length; i++) {
    _expectSameNavPoint(wire.subNavPoints[i], inline.subNavPoints[i], i);
  }
}

void main() async {
  const chemistry = 'books/epub/elements-of-chemistry.epub';

  group('EPUB session header round-trip', () {
    late final (EpubBook, EpubBook) headerPair;
    late final EpubBook full;
    setUpAll(() async {
      headerPair = await _epubHeaderAndDecoded(chemistry);
      full = Unseal.parse(_bytes(chemistry)) as EpubBook;
    });
    late final header = headerPair.$1;
    late final decoded = headerPair.$2;

    test('carries no content across the wire', () async {
      expect(decoded.files.html, isEmpty, reason: 'header must hold no content');
      expect(decoded.files.images, isEmpty);
      expect(decoded.files.css, isEmpty);
      expect(decoded.files.fonts, isEmpty);
      expect(decoded.files.others, isEmpty);
    });

    test('navigation, page list and landmarks survive', () async {
      _expectSameNavigation(decoded.navigation, header.navigation);
      _expectSameNavigation(decoded.navigation, full.navigation);
      if (header.pageList == null) {
        expect(decoded.pageList, isNull);
      } else {
        _expectSameNavigation(decoded.pageList!, header.pageList!);
      }
      expect(decoded.landmarks.length, header.landmarks.length);
      for (var i = 0; i < header.landmarks.length; i++) {
        expect(decoded.landmarks[i].label, header.landmarks[i].label, reason: 'landmark $i');
        expect(decoded.landmarks[i].href, header.landmarks[i].href, reason: 'landmark $i');
        expect(decoded.landmarks[i].types, header.landmarks[i].types, reason: 'landmark $i');
      }
    });

    test('metadata and cover survive', () async {
      expect(decoded.metadata.title, full.metadata.title);
      expect(decoded.metadata.authors, full.metadata.authors);
      expect(decoded.cover.content, header.cover.content);
    });

    test('package, spine and container inventory survive', () async {
      expect(decoded.spinePaths, full.spinePaths, reason: 'spine paths');
      expect(decoded.spineIdrefs, full.spineIdrefs, reason: 'spine idrefs');
      expect(decoded.nonLinearSpinePaths, full.nonLinearSpinePaths, reason: 'non-linear spine');
      expect(decoded.package.version, full.package.version);
      expect(decoded.package.spine.items, full.package.spine.items);
      expect(
        decoded.package.spine.pageProgressionDirection,
        full.package.spine.pageProgressionDirection,
      );
      expect(decoded.package.spine.nonLinearIdrefs, full.package.spine.nonLinearIdrefs);
      expect(decoded.package.manifest.items.length, full.package.manifest.items.length);
      expect(
        <String, int>{for (final entry in decoded.archiveEntries) entry.path: entry.size},
        <String, int>{for (final entry in full.archiveEntries) entry.path: entry.size},
        reason: 'inventory sizes',
      );
    });
  });

  group('FXL session header round-trip', () {
    const fixture = 'books/epub/fxl-mixed-fixed-override.epub';
    late final (EpubBook, EpubBook) pair;
    setUpAll(() async {
      pair = await _epubHeaderAndDecoded(fixture);
    });
    late final header = pair.$1;
    late final decoded = pair.$2;

    test('rendition settings survive', () async {
      final package = header.package;
      if (package is Epub3Package) {
        final decodedPackage = decoded.package as Epub3Package;
        for (final item in package.manifest.items) {
          expect(
            decodedPackage.renditionSettings.layoutFor(item.id),
            package.renditionSettings.layoutFor(item.id),
            reason: 'layout for ${item.id}',
          );
          expect(
            decodedPackage.renditionSettings.spreadFor(item.id),
            package.renditionSettings.spreadFor(item.id),
            reason: 'spread for ${item.id}',
          );
        }
      } else {
        fail('the FXL fixture should carry EPUB 3 rendition settings');
      }
    });

    test('content viewports survive', () async {
      expect(decoded.contentViewports.length, header.contentViewports.length);
      for (final entry in header.contentViewports.entries) {
        expect(decoded.contentViewports[entry.key]?.width, entry.value.width, reason: entry.key);
        expect(decoded.contentViewports[entry.key]?.height, entry.value.height, reason: entry.key);
      }
    });
  });

  group('non-linear session header round-trip', () {
    const fixture = 'books/epub/fxl-nonlinear.epub';
    late final (EpubBook, EpubBook) pair;
    late final EpubBook full;
    setUpAll(() async {
      pair = await _epubHeaderAndDecoded(fixture);
      full = Unseal.parse(_bytes(fixture)) as EpubBook;
    });
    late final header = pair.$1;
    late final decoded = pair.$2;

    test('non-linear idrefs and spine paths survive', () async {
      expect(decoded.package.spine.nonLinearIdrefs, full.package.spine.nonLinearIdrefs);
      expect(decoded.spinePaths, full.spinePaths);
      expect(decoded.nonLinearSpinePaths, full.nonLinearSpinePaths);
      expect(header.nonLinearSpinePaths, isNotEmpty, reason: 'fixture exercises the field');
    });
  });

  group('comic session header round-trip', () {
    const fixture = 'books/comic/halfpenny-surprise-1895.cbz';
    late final (ComicBook, ComicBook) comicPair;
    setUpAll(() async {
      comicPair = await _comicHeaderAndDecoded(fixture);
    });
    late final header = comicPair.$1;
    late final decoded = comicPair.$2;
    final full = Unseal.parse(_bytes(fixture)) as ComicBook;

    test('page placeholders survive without bytes', () async {
      expect(decoded.format, BookFormat.cbz);
      expect(decoded.pageCount, header.pageCount);
      expect(
        [for (final page in decoded.pages) page.path],
        [for (final page in header.pages) page.path],
      );
      expect(
        [for (final page in decoded.pages) page.name],
        [for (final page in full.pages) page.name],
      );
      expect(
        [for (final page in decoded.pages) page.type],
        [for (final page in full.pages) page.type],
      );
      for (final page in decoded.pages) {
        expect(page.content, isEmpty, reason: 'placeholder pages carry no bytes');
      }
    });

    test('page info, reading direction, metadata and cover survive', () async {
      expect(decoded.readingDirection, full.readingDirection);
      expect(decoded.pageInfo.length, header.pageInfo.length);
      for (var i = 0; i < header.pageInfo.length; i++) {
        expect(decoded.pageInfo[i].imageIndex, header.pageInfo[i].imageIndex, reason: 'page $i');
        expect(decoded.pageInfo[i].type, header.pageInfo[i].type, reason: 'page $i');
        expect(decoded.pageInfo[i].rawType, header.pageInfo[i].rawType, reason: 'page $i');
        expect(decoded.pageInfo[i].doublePage, header.pageInfo[i].doublePage, reason: 'page $i');
        expect(decoded.pageInfo[i].bookmark, header.pageInfo[i].bookmark, reason: 'page $i');
        expect(decoded.pageInfo[i].imageSize, header.pageInfo[i].imageSize, reason: 'page $i');
        expect(decoded.pageInfo[i].imageWidth, header.pageInfo[i].imageWidth, reason: 'page $i');
        expect(decoded.pageInfo[i].imageHeight, header.pageInfo[i].imageHeight, reason: 'page $i');
      }
      expect(decoded.metadata.title, full.metadata.title);
      expect(decoded.cover.content, full.cover.content);
    });
  });

  group('CBR session header round-trip', () {
    const fixture = 'books/comic/synthetic-stored-pages.cbr';
    late final (ComicBook, ComicBook) comicPair;
    setUpAll(() async {
      comicPair = await _comicHeaderAndDecoded(fixture);
    });
    late final header = comicPair.$1;
    late final decoded = comicPair.$2;
    final full = Unseal.parse(_bytes(fixture)) as ComicBook;

    test('the cbr book format survives intact', () async {
      expect(header.format, BookFormat.cbr);
      expect(decoded.format, BookFormat.cbr);
    });

    test('page placeholders survive without bytes', () async {
      expect(decoded.pageCount, full.pageCount);
      expect(
        [for (final page in decoded.pages) page.path],
        [for (final page in full.pages) page.path],
      );
      for (final page in decoded.pages) {
        expect(page.content, isEmpty, reason: 'placeholder pages carry no bytes');
      }
    });
  });

  group('PDF session header round-trip', () {
    const fixture = 'pdf/dickens-sample.pdf';
    late final PdfBook header;
    late final PdfBook decoded;
    late final PdfBook full;
    setUpAll(() async {
      final engine = await SessionEngine.openBytes(_bytes(fixture));
      header = engine.book as PdfBook;
      engine.close();
      decoded = _roundTrip(header) as PdfBook;
      full = Unseal.parse(_bytes(fixture)) as PdfBook;
    });

    test('the pdf book format survives intact', () async {
      expect(header.format, BookFormat.pdf);
      expect(decoded.format, BookFormat.pdf);
    });

    test('page geometry survives; content stays empty', () async {
      expect(decoded.pageCount, full.pageCount);
      expect(decoded.bytes, isEmpty, reason: 'the document bytes stay on the worker');
      expect(decoded.hasTextLayer, isFalse, reason: 'pageTexts stay empty');
      expect(decoded.cover.isEmpty, isTrue);
      for (var i = 0; i < full.pageCount; i++) {
        expect(decoded.pages[i].objectNumber, full.pages[i].objectNumber, reason: 'page $i');
        expect(decoded.pages[i].width, full.pages[i].width, reason: 'page $i width');
        expect(decoded.pages[i].height, full.pages[i].height, reason: 'page $i height');
        expect(decoded.pages[i].rotate, full.pages[i].rotate, reason: 'page $i rotate');
      }
    });

    test('reading-order placeholders survive as structure', () async {
      expect(
        [for (final item in decoded.readingOrder) item.name],
        [for (final item in header.readingOrder) item.name],
      );
      expect(decoded.files.html, hasLength(full.pageCount));
      for (final file in decoded.files.html) {
        expect(file.content, isEmpty, reason: 'placeholder pages carry no content');
        expect(file.type, 'html');
      }
    });

    test('metadata and navigation survive', () async {
      expect(decoded.metadata.title, full.metadata.title);
      _expectSameNavigation(decoded.navigation, header.navigation);
      _expectSameNavigation(decoded.navigation, full.navigation);
    });
  });

  test('rejects a book that cannot be a session header', () async {
    final bytes = _bytes('books/txt/synthetic.txt');

    expect(() => encodeSessionHeaderWire(Unseal.parse(bytes)), throwsArgumentError);
  });

  group('PDF page-lines wire round-trip', () {
    const fixture = 'pdf/dickens-sample.pdf';
    final bytes = _bytes(fixture);
    final full = Unseal.parse(bytes) as PdfBook;

    test('a page extracted text survives the JSON channel', () async {
      final page = full.pageTexts.single;
      final json = encodePdfPageLinesWire(
        page,
        pageWidth: full.pages.single.width,
        pageHeight: full.pages.single.height,
      );
      final channel = decodeJson(encodeJson(json));
      final decoded = decodePdfPageLinesWire(channel);

      expect(decoded.lines.length, page.lines.length);
      for (var i = 0; i < page.lines.length; i++) {
        expect(decoded.lines[i].text, page.lines[i].text, reason: 'line $i text');
        expect(decoded.lines[i].x, page.lines[i].x, reason: 'line $i x');
        expect(decoded.lines[i].y, page.lines[i].y, reason: 'line $i y');
        expect(decoded.lines[i].width, page.lines[i].width, reason: 'line $i width');
        expect(decoded.lines[i].height, page.lines[i].height, reason: 'line $i height');
        expect(decoded.lines[i].fontSize, page.lines[i].fontSize, reason: 'line $i fontSize');
        expect(decoded.lines[i].rotated, page.lines[i].rotated, reason: 'line $i rotated');
      }
      expect(decoded.images.length, page.images.length);
      for (var i = 0; i < page.images.length; i++) {
        expect(decoded.images[i].path, page.images[i].path, reason: 'image $i');
        expect(decoded.images[i].x, page.images[i].x, reason: 'image $i x');
      }
      expect(decoded.contentStreamCount, page.contentStreamCount);
      expect(decoded.skippedContentStreams, page.skippedContentStreams);
      expect(decoded.columnOrderApplied, page.columnOrderApplied);
      expect(
        decoded.lines.map((final line) => line.text).join('\n'),
        page.text,
        reason: 'the §3.4.4 canonical space crosses intact',
      );
    });
  });
}
