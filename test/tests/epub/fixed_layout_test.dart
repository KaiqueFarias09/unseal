import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/src/platform/web/wire/epub_package_wire.dart';
import 'package:unseal/unseal.dart';

EpubBook _book(final String name) =>
    parseEpubBook(File('test/resources/books/epub/$name').readAsBytesSync());

Uint8List _bytesOf(final String name) => File('test/resources/books/epub/$name').readAsBytesSync();

void main() {
  group('fixed-layout viewports', () {
    test('XHTML viewport metas are extracted for every spine page', () {
      final book = _book('fxl-xhtml-viewport.epub');

      expect(book.contentViewports, hasLength(3));
      expect(book.contentViewports.values.toSet(), {const EpubViewport(width: 1200, height: 1600)});
      // Keys share the exact files.html path space.
      expect(
        book.contentViewports.keys.toSet(),
        book.files.html
            .map((final file) => file.path)
            .toSet()
            .where((final path) => path.endsWith('.xhtml') && !path.endsWith('nav.xhtml')),
      );
    });

    test('standalone SVG pages report their declared size', () {
      final book = _book('fxl-svg.epub');

      expect(
        book.contentViewports['OEBPS/page1.svg'],
        const EpubViewport(width: 1200, height: 1600),
      );
      expect(
        book.contentViewports['OEBPS/page2.svg'],
        const EpubViewport(width: 1200, height: 1600),
      );
      // Explicit width/height beat the viewBox size.
      final svg = book.files.html
          .singleWhere((final file) => file.path == 'OEBPS/page1.svg')
          .content;
      expect(svg, contains('width="1200"'));
      expect(svg, contains('viewBox="0 0 1200 1600"'));
    });

    test('malformed, fractional, and oversized declarations yield no viewport', () {
      final book = _book('fxl-viewport-quirks.epub');

      expect(book.contentViewports, hasLength(1));
      expect(
        book.contentViewports['OEBPS/valid.xhtml'],
        const EpubViewport(width: 900, height: 1200),
      );
      expect(book.contentViewports.containsKey('OEBPS/no-viewport.xhtml'), isFalse);
      expect(book.contentViewports.containsKey('OEBPS/malformed.xhtml'), isFalse);
      expect(book.contentViewports.containsKey('OEBPS/oversized.xhtml'), isFalse);
    });

    test('only documents the spine references are scanned', () {
      final book = _book('fxl-xhtml-viewport.epub');

      // The nav document declares no viewport meta and sits outside the
      // spine; it must never appear.
      expect(book.contentViewports.keys.any((final path) => path.endsWith('nav.xhtml')), isFalse);
    });

    test('mixed books carry viewports only for fixed pages', () {
      final fixed = _book('fxl-mixed-fixed-override.epub');
      final reflow = _book('fxl-mixed-reflow-override.epub');

      expect(fixed.contentViewports.keys, everyElement(endsWith('.xhtml')));
      expect(fixed.contentViewports, hasLength(2));
      expect(
        fixed.contentViewports['OEBPS/fixed2.xhtml'],
        const EpubViewport(width: 1000, height: 1400),
      );
      expect(reflow.contentViewports, hasLength(2));
      expect(reflow.contentViewports.containsKey('OEBPS/page2.xhtml'), isFalse);
    });
  });

  group('spine linearity', () {
    test('linear="no" idrefs are captured on the spine model', () {
      final book = _book('fxl-nonlinear.epub');

      expect(book.package.spine.nonLinearIdrefs, {'p2', 'p3'});
      expect(book.nonLinearSpinePaths, {'OEBPS/page2.xhtml', 'OEBPS/page3.xhtml'});
      expect(book.spineItemIsLinear(0), isTrue);
      expect(book.spineItemIsLinear(1), isFalse);
      expect(book.spineItemIsLinear(2), isFalse);
    });

    test('a book without linear declarations marks every item linear', () {
      final book = _book('fxl-xhtml-viewport.epub');

      expect(book.package.spine.nonLinearIdrefs, isEmpty);
      expect(book.nonLinearSpinePaths, isEmpty);
      final linearity = <bool>[
        for (var index = 0; index < book.readingOrder.length; index++)
          book.spineItemIsLinear(index),
      ];
      expect(linearity, everyElement(isTrue));
    });
  });

  group('effective per-spine-index rendition helpers', () {
    test('global settings apply to items without overrides', () {
      final book = _book('fxl-xhtml-viewport.epub');

      for (var index = 0; index < book.readingOrder.length; index++) {
        expect(book.layoutForSpineIndex(index), EpubLayout.prePaginated);
        expect(book.orientationForSpineIndex(index), EpubOrientation.auto);
        expect(book.spreadForSpineIndex(index), EpubSpread.auto);
        expect(book.pageSpreadForSpineIndex(index), isNull);
        expect(book.viewportForSpineIndex(index), const EpubViewport(width: 1200, height: 1600));
      }
    });

    test('spine properties override the publication-wide settings', () {
      final spreads = _book('fxl-spread-hints.epub');
      final orientation = _book('fxl-orientation.epub');
      final mixed = _book('fxl-mixed-reflow-override.epub');
      final rtl = _book('fxl-rtl.epub');

      expect(spreads.pageSpreadForSpineIndex(0), EpubPageSpread.left);
      expect(spreads.pageSpreadForSpineIndex(1), EpubPageSpread.right);
      expect(spreads.pageSpreadForSpineIndex(2), EpubPageSpread.center);
      expect(spreads.pageSpreadForSpineIndex(3), isNull);
      expect(spreads.spreadForSpineIndex(4), EpubSpread.both);

      expect(orientation.orientationForSpineIndex(0), EpubOrientation.landscape);
      expect(orientation.orientationForSpineIndex(1), EpubOrientation.portrait);
      expect(orientation.orientationForSpineIndex(2), EpubOrientation.landscape);

      expect(mixed.layoutForSpineIndex(0), EpubLayout.prePaginated);
      expect(mixed.layoutForSpineIndex(1), EpubLayout.reflowable);
      expect(mixed.layoutForSpineIndex(2), EpubLayout.prePaginated);
      expect(mixed.viewportForSpineIndex(1), isNull);

      expect(rtl.pageSpreadForSpineIndex(0), EpubPageSpread.right);
      expect(rtl.effectivePageProgressionDirection, PageProgressionDirection.rtl);
    });

    test('EPUB 2 books fall back to reading-system defaults', () {
      final book = parseEpubBook(
        _epub2Bytes(
          '<item id="c1" href="c1.xhtml" media-type="text/html"/>'
              '<item id="c2" href="c2.xhtml" media-type="text/html"/>',
          '<itemref idref="c1"/><itemref idref="c2" linear="no"/>',
        ),
      );

      expect(book.package, isA<Epub2Package>());
      expect(book.layoutForSpineIndex(0), EpubLayout.reflowable);
      expect(book.orientationForSpineIndex(0), EpubOrientation.auto);
      expect(book.spreadForSpineIndex(0), EpubSpread.auto);
      expect(book.pageSpreadForSpineIndex(0), isNull);
      expect(book.viewportForSpineIndex(0), isNull);
      expect(book.spineItemIsLinear(0), isTrue);
      expect(book.spineItemIsLinear(1), isFalse);
    });

    test('out-of-range indexes throw a RangeError', () {
      final book = _book('fxl-xhtml-viewport.epub');
      final count = book.readingOrder.length;

      for (final helper in <void Function(int)>[
        book.layoutForSpineIndex,
        book.orientationForSpineIndex,
        book.spreadForSpineIndex,
        book.pageSpreadForSpineIndex,
        book.viewportForSpineIndex,
        book.spineItemIsLinear,
      ]) {
        expect(() => helper(-1), throwsRangeError);
        expect(() => helper(count), throwsRangeError);
      }
    });

    test('repeated spine references resolve independently', () {
      final book = _book('fxl-repeated-spine.epub');

      expect(book.spinePaths, hasLength(3));
      expect(book.spinePaths![0], book.spinePaths![2]);
      expect(book.spineIdrefs, ['shared', 'other', 'shared']);
      expect(book.readingOrder, hasLength(3));
      expect(book.contentViewports, hasLength(2));
      for (var index = 0; index < 3; index++) {
        expect(book.layoutForSpineIndex(index), EpubLayout.prePaginated);
        expect(book.viewportForSpineIndex(index), isNotNull);
      }
    });
  });

  group('standalone SVG content documents', () {
    test('join the reading order and the spine', () {
      final book = _book('fxl-svg.epub');

      expect(book.spinePaths, ['OEBPS/page1.svg', 'OEBPS/page2.svg', 'OEBPS/page3.xhtml']);
      expect(book.readingOrder.map((final item) => item.name), book.spinePaths);
      expect(book.files.html.map((final file) => file.type), contains('svg'));
      // SVG no longer buckets as an image.
      expect(book.files.images.where((final file) => file.type == 'svg'), isEmpty);
    });

    test('resolve CFIs like any other content document', () {
      final book = _book('fxl-svg.epub');

      final offset = _firstTextOffset(book, 0);
      final cfi = EpubCfi.parse(book.buildEpubCfi(contentIndex: 0, offsetInText: offset));
      final location = book.resolveCfi(cfi);

      expect(location, isNotNull);
      expect(location!.contentIndex, 0);
      expect(location.contentPath, 'OEBPS/page1.svg');
      expect(location.charOffset, offset);
    });

    test('search finds SVG text and progression counts the page', () {
      final book = _book('fxl-svg.epub');

      final results = book.search('Fixed Page 1');
      expect(results.matches, isNotEmpty);
      expect(results.matches.first.sectionIndex, 0);
      expect(book.readingOrder, hasLength(3));
    });

    test('inline SVG in XHTML does not change an existing book', () {
      // tristram-shandy.epub embeds SVG inline; its reading order is
      // XHTML-only and its viewports stay absent.
      final bytes = _bytesOf('tristram-shandy.epub');
      final book = parseEpubBook(bytes);

      expect(book.contentViewports, isEmpty);
      expect(book.spinePaths!.every((final path) => path.endsWith('.xhtml')), isTrue);
    });
  });

  group('fixed-layout ancillary data', () {
    test('media overlay linkage and metadata are exposed', () {
      final book = _book('fxl-overlays.epub');
      final metadata = book.package.metadata as Epub3Metadata;

      expect(metadata.mediaActiveClass, '-epub-media-overlay-active');
      for (final item in book.package.manifest.items) {
        if (item.mediaType == 'application/xhtml+xml' && item.id != 'nav') {
          expect(item.mediaOverlay, 'overlay1');
        }
      }

      final smil = utf8.decode(
        book.files.others.singleWhere((final file) => file.path.endsWith('overlay1.smil')).content,
      );
      final overlay = parseMediaOverlay(smil, smilPath: 'OEBPS/overlay1.smil');
      expect(overlay.segments, hasLength(2));
      expect(overlay.segments.first.fragment, 's1');
      expect(overlay.segments.first.clipBegin, Duration.zero);
      expect(overlay.segments[1].clipBegin, const Duration(seconds: 2));
    });

    test('the image-only fixed page carries no text', () {
      final book = _book('fxl-overlays.epub');
      final page = book.files.html.singleWhere((final file) => file.path == 'OEBPS/page2.xhtml');

      expect(page.content, contains('<img src="plate.png"'));
      expect(page.plainText.trim(), isEmpty);
    });

    test('scripted manifest properties survive parsing', () {
      final book = _book('fxl-scripted.epub');
      final scripted = book.package.manifest.items.singleWhere((final item) => item.id == 'p2');

      expect(scripted.properties, contains('scripted'));
      expect(
        book.files.html.singleWhere((final file) => file.path == 'OEBPS/page2.xhtml').content,
        contains('data-script-ran'),
      );
    });
  });

  group('fixed-layout wire round-trip', () {
    test('viewports, linearity, and spine idrefs survive the codec', () {
      final book = _book('fxl-nonlinear.epub');
      final (json, blobs) = encodeBookWire(book);
      final restored = decodeBookWire(json, blobs) as EpubBook;

      expect(restored.contentViewports, book.contentViewports);
      expect(restored.nonLinearSpinePaths, book.nonLinearSpinePaths);
      expect(restored.spineIdrefs, book.spineIdrefs);
      expect(restored.spinePaths, book.spinePaths);
      for (var index = 0; index < book.readingOrder.length; index++) {
        expect(restored.layoutForSpineIndex(index), book.layoutForSpineIndex(index));
        expect(restored.viewportForSpineIndex(index), book.viewportForSpineIndex(index));
        expect(restored.spineItemIsLinear(index), book.spineItemIsLinear(index));
        expect(restored.pageSpreadForSpineIndex(index), book.pageSpreadForSpineIndex(index));
      }
    });

    test('a book without fixed-layout data decodes to empty defaults', () {
      final book = _book('tristram-shandy.epub');
      final (json, blobs) = encodeBookWire(book);
      final restored = decodeBookWire(json, blobs) as EpubBook;

      expect(restored.contentViewports, isEmpty);
      expect(restored.nonLinearSpinePaths, isEmpty);
    });

    test('the package wire carries the spine linearity markers', () {
      final book = _book('fxl-nonlinear.epub');
      final encoded = encodeEpubPackageWireValue(book.package);
      final decoded = decodeEpubPackageWireValue(encoded);

      expect(decoded.spine.nonLinearIdrefs, book.package.spine.nonLinearIdrefs);
    });
  });
}

/// Builds a minimal EPUB 2 archive for the default-fallback tests.
Uint8List _epub2Bytes(final String manifest, final String spine) {
  final archive = Archive();
  void add(final String path, final String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  add(
    'META-INF/container.xml',
    '<?xml version="1.0"?><container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
        '<rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>'
        '</rootfiles></container>',
  );
  add(
    'content.opf',
    '<?xml version="1.0" encoding="utf-8"?>'
        '<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>EPUB 2 fixture</dc:title><dc:language>en</dc:language>'
        '<dc:identifier id="uid">urn:uuid:epub2</dc:identifier></metadata>'
        '<manifest>$manifest</manifest><spine>$spine</spine></package>',
  );
  add('c1.xhtml', '<html><head><title>c1</title></head><body><p>Chapter one.</p></body></html>');
  add('c2.xhtml', '<html><head><title>c2</title></head><body><p>Chapter two.</p></body></html>');

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// The first visible text offset of reading-order section [index].
int _firstTextOffset(final EpubBook book, final int index) {
  final file = book.files.html.singleWhere((final candidate) {
    return candidate.path == book.readingOrder[index].name;
  });
  final text = documentTextOf(file);

  return text.indexOf('Fixed Page');
}
