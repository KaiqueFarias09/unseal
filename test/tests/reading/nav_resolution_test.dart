import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/features/reading/nav_resolution.dart';
import 'package:test/test.dart';

import '../mobi/mobi_fixture_builder.dart';
import 'synthetic_books.dart';

void main() {
  final sample1Bytes = File('test/resources/epub/sample1.epub').readAsBytesSync();
  final structureBytes = File('test/resources/epub/structure-sample-01.epub').readAsBytesSync();
  final wcagBytes = File('test/resources/epub/WCAG-ch1.epub').readAsBytesSync();
  final aliceBytes = File(
    'test/resources/epub/Alices Adventures in Wonderland.epub',
  ).readAsBytesSync();
  final aliceMobiBytes = File('test/resources/mobi/alice-old.mobi').readAsBytesSync();

  group('navTargetOf against EPUB fixtures', () {
    test('sample1: exact path match, missing anchor keeps the section', () {
      final book = parseEpubBook(sample1Bytes);
      final points = book.navigation.navPoints;

      final contents = book.navTargetOf(points[0]);
      expect(contents!.sectionIndex, 3);
      expect(contents.anchorId, 'contents_1');
      expect(contents.charOffset, isNull);

      final introduction = book.navTargetOf(points[1]);
      expect(introduction!.sectionIndex, 5);
      expect(introduction.anchorId, isNull);
      expect(introduction.charOffset, isNull);

      final chapter = book.navTargetOf(points[2]);
      expect(chapter!.sectionIndex, 6);
      expect(chapter.charOffset, isNull);
    });

    test('structure-sample-01: suffix match and anchor offset', () {
      final book = parseEpubBook(structureBytes);
      final points = book.navigation.navPoints;

      final halftitle = book.navTargetOf(points[1]);
      expect(halftitle, isNotNull);
      expect(halftitle!.sectionIndex, 2);
      expect(halftitle.anchorId, 'd6e189');
      expect(halftitle.charOffset, isNotNull);

      // The offset addresses the anchor's first text: the half title
      // heading.
      final file = _htmlOf(book, halftitle.sectionIndex);
      final text = documentTextOf(file);
      expect(text.substring(halftitle.charOffset!), startsWith('Half Titlepage Title'));

      final preface = book.navTargetOf(points[4]);
      expect(preface!.sectionIndex, 7);
      expect(preface.charOffset, isNotNull);
      expect(preface.charOffset, lessThan(documentTextOf(_htmlOf(book, 7)).length));
    });

    test('WCAG-ch1: EPUB3 nav hrefs resolve to the spine', () {
      final book = parseEpubBook(wcagBytes);
      final target = book.navTargetOf(book.navigation.navPoints.first);
      expect(target!.sectionIndex, 0);
      expect(target.anchorId, 'd18656e11');
      expect(target.charOffset, isNotNull);
    });

    test('Alice: every entry resolves, sections never go backwards', () {
      final book = parseEpubBook(aliceBytes);
      final targets = resolveNavigation(book);
      final flattened = <NavPoint>[];
      void visit(final List<NavPoint> points) {
        for (final point in points) {
          flattened.add(point);
          visit(point.subNavPoints);
        }
      }

      visit(book.navigation.navPoints);
      expect(targets.length, flattened.length);
      expect(targets.every((final target) => target != null), isTrue);

      var previous = -1;
      for (final target in targets.cast<NavTarget>()) {
        expect(target.sectionIndex, greaterThanOrEqualTo(previous));
        previous = target.sectionIndex;
      }
    });

    test('repeated resolution is stable across the per-book cache', () {
      final book = parseEpubBook(structureBytes);
      final point = book.navigation.navPoints[1];
      final cold = book.navTargetOf(point);
      final warm = book.navTargetOf(point);
      expect(warm!.sectionIndex, cold!.sectionIndex);
      expect(warm.charOffset, cold.charOffset);
      expect(warm.anchorId, cold.anchorId);
    });
  });

  group('navTargetOf against MOBI', () {
    test('synthetic MOBI 6 filepos target maps to the anchor section', () {
      final book = parseMobiBook(
        buildPdb('NavToc', [
          buildMobiRecord0(compressionType: 1, textRecordCount: 1),
          Uint8List.fromList(
            convert.utf8.encode(
              '<html><body>'
              '<a href="#filepos1">Chapter One</a> <a href="#filepos2">Chapter Two</a>'
              '<p>filler text</p>'
              '<a id="filepos1"></a><p>one one one</p>'
              '<a id="filepos2"></a><p>two two two</p>'
              '</body></html>',
            ),
          ),
        ]),
      );

      expect(book.readingOrder.length, 1);
      final targets = resolveNavigation(book);
      expect(targets.length, 2);
      for (final target in targets.cast<NavTarget>()) {
        expect(target.sectionIndex, 0);
        expect(target.charOffset, isNull);
        expect(target.anchorId, isNull);
      }
    });

    test('real MOBI 6 book: every entry lands in the single section', () {
      final book = parseMobiBook(aliceMobiBytes);
      expect(book.readingOrder.length, 1);
      final targets = resolveNavigation(book);
      expect(targets, isNotEmpty);
      for (final target in targets.cast<NavTarget>()) {
        expect(target.sectionIndex, 0);
        expect(target.charOffset, isNull);
      }
    });
  });

  group('navTargetOf against synthetic books', () {
    test('percent-encoded href matches the decoded section name', () {
      final spaced = TextFile(
        name: 'a b.xhtml',
        type: 'html',
        path: 'a b.xhtml',
        content: '<html><body><p>before</p><a id="intro">intro text</a></body></html>',
      );
      final book = SyntheticBook(
        files: Files(
          images: const <BinaryFile>[],
          css: const <TextFile>[],
          html: <TextFile>[spaced],
          fonts: const <BinaryFile>[],
          others: const <BinaryFile>[],
        ),
        navigation: navigationOf([navPoint('a%20b.xhtml#intro')]),
      );

      final target = book.navTargetOf(book.navigation.navPoints.single);
      expect(target!.sectionIndex, 0);
      expect(target.charOffset, 'before'.length);
      expect(target.anchorId, 'intro');
    });

    test('bare fragment resolves inside section 0', () {
      final book = SyntheticBook(
        files: htmlFiles(['<html><body><p>abc</p><a name="old"></a><p>named</p></body></html>']),
        navigation: navigationOf([navPoint('#old')]),
      );

      final target = book.navTargetOf(book.navigation.navPoints.single);
      expect(target!.sectionIndex, 0);
      expect(target.charOffset, 3);
      expect(target.anchorId, 'old');
    });

    test('FB2-style file and fragment resolve the anchor offset', () {
      final book = SyntheticBook(
        files: htmlFiles(['<html><body><p>lead</p><h2 id="section_2">Section</h2></body></html>']),
        navigation: navigationOf([navPoint('section0.html#section_2')]),
      );

      final target = book.navTargetOf(book.navigation.navPoints.single);
      expect(target!.sectionIndex, 0);
      expect(target.charOffset, 'lead'.length);
      expect(target.anchorId, 'section_2');
    });

    test('unknown path yields no target', () {
      final book = SyntheticBook(
        files: htmlFiles(['<html><body><p>abc</p></body></html>']),
        navigation: navigationOf([navPoint('missing/section.xhtml')]),
      );

      expect(book.navTargetOf(book.navigation.navPoints.single), isNull);
    });

    test('anchor inside a script-styled document skips hidden text', () {
      final book = SyntheticBook(
        files: htmlFiles([
          '<html><body>'
              '<style>.x { color: red }</style>'
              '<p>visible</p>'
              '<script>var hidden = 1;</script>'
              '<h2 id="here">Heading</h2>'
              '</body></html>',
        ]),
        navigation: navigationOf([navPoint('#here')]),
      );

      final target = book.navTargetOf(book.navigation.navPoints.single);
      expect(target!.charOffset, 'visible'.length);
    });

    test('empty book yields no target', () {
      final book = SyntheticBook(
        files: htmlFiles(const <String>[]),
        navigation: navigationOf([navPoint('#frag')]),
      );

      expect(book.navTargetOf(book.navigation.navPoints.single), isNull);
    });
  });
}

/// The HTML file behind reading-order section [index].
TextFile _htmlOf(final EpubBook book, final int index) {
  final name = book.readingOrder[index].name;
  return book.files.html.firstWhere((final file) => file.path == name);
}
